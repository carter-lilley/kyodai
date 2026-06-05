package com.heckpoint.kyodai;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;
import androidx.core.app.NotificationCompat;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Extraction service that runs in a separate process to avoid sharing memory with Godot.
 * This prevents OOM kills during large game extractions on low-RAM devices.
 * 
 * Usage:
 * Intent intent = new Intent(context, ExtractorService.class);
 * intent.setAction("EXTRACT");
 * intent.putExtra("zip_path", "/path/to/game.zip");
 * intent.putExtra("extract_dir", "/path/to/dest");
 * context.startService(intent);
 * 
 * The service sends a broadcast when extraction completes or fails:
 * Action: "com.heckpoint.kyodai.EXTRACTION_COMPLETE"
 * Extras: "success" (boolean), "zip_path" (String), "extract_dir" (String), "error" (String)
 */
public class ExtractorService extends Service {
    private static final String TAG = "ExtractorService";
    private static final String CHANNEL_ID = "kyodai_extractor";
    private static final int NOTIFICATION_ID = 2001;
    private static final String ACTION_EXTRACTION_COMPLETE = "com.heckpoint.kyodai.EXTRACTION_COMPLETE";
    
    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "ExtractorService created in process " + android.os.Process.myPid());
        createNotificationChannel();
    }
    
    @Override
    public IBinder onBind(Intent intent) {
        return null; // Not a bound service
    }
    
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        
        String action = intent.getAction();
        if (action == null) action = "";
        
        switch (action) {
            case "EXTRACT":
                String zipPath = intent.getStringExtra("zip_path");
                String extractDir = intent.getStringExtra("extract_dir");
                String gameName = intent.getStringExtra("game_name");
                if (gameName == null) gameName = "Game";
                
                if (zipPath != null && extractDir != null) {
                    startExtraction(zipPath, extractDir, gameName);
                } else {
                    Log.e(TAG, "Missing zip_path or extract_dir");
                    stopSelf();
                }
                break;
                
            default:
                stopSelf();
                break;
        }
        
        return START_STICKY;
    }
    
    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Kyodai Game Extraction",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Shows game extraction progress");
            channel.setSound(null, null);
            channel.enableVibration(false);
            
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
    
    private void startExtraction(String zipPath, String extractDir, String gameName) {
        // Start as foreground service immediately
        Notification notification = buildNotification(gameName, 0);
        try {
            startForeground(NOTIFICATION_ID, notification);
            Log.d(TAG, "Started foreground extraction for: " + gameName);
        } catch (Exception e) {
            Log.e(TAG, "Failed to start foreground: " + e.getMessage());
        }
        
        // Run extraction on a background thread
        new Thread(() -> {
            boolean success = extractZipStreaming(zipPath, extractDir, gameName);
            
            // Write completion marker files for 100% reliable completion detection
            // The Godot side polls for these files, so we don't depend on broadcasts
            writeCompletionMarkers(extractDir, success);
            
            // Also send broadcast as a fallback/notification mechanism
            Log.d(TAG, "Sending extraction completion broadcast, success=" + success);
            Intent broadcast = new Intent(ACTION_EXTRACTION_COMPLETE);
            broadcast.putExtra("success", success);
            broadcast.putExtra("zip_path", zipPath);
            broadcast.putExtra("extract_dir", extractDir);
            if (!success) {
                broadcast.putExtra("error", "Extraction failed");
            }
            broadcast.setPackage(getPackageName());
            sendBroadcast(broadcast);
            
            // Stop service
            stopForeground(true);
            stopSelf();
        }).start();
    }
    
    private Notification buildNotification(String gameName, int progress) {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Extracting " + gameName)
            .setContentText("Preparing game files...")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(pendingIntent);
        
        if (progress > 0) {
            builder.setProgress(100, progress, false);
        } else {
            builder.setProgress(0, 0, true);
        }
        
        return builder.build();
    }
    
    private void updateNotification(String gameName, int extractedCount, long totalBytes) {
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            Notification notification = buildProgressNotification(gameName, extractedCount, totalBytes);
            manager.notify(NOTIFICATION_ID, notification);
        }
    }
    
    private Notification buildProgressNotification(String gameName, int extractedCount, long totalBytes) {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        String progressText = extractedCount + " files, " + (totalBytes / 1048576) + " MB";
        
        return new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Extracting " + gameName)
            .setContentText(progressText)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setProgress(0, 0, true)
            .setContentIntent(pendingIntent)
            .build();
    }
    
    /**
     * Extracts ZIP using streaming with memory pressure relief.
     * Runs in this service's own process with separate memory budget.
     */
    private boolean extractZipStreaming(String zipPath, String extractDir, String gameName) {
        Log.d(TAG, "Starting streaming extraction: " + zipPath + " -> " + extractDir);
        
        ZipInputStream zis = null;
        InputStream fis = null;
        byte[] buffer = new byte[131072]; // 128KB buffer for better throughput
        int extractedCount = 0;
        long totalBytes = 0;
        long lastLogTime = System.currentTimeMillis();
        
        try {
            File destDir = new File(extractDir);
            if (!destDir.exists()) {
                destDir.mkdirs();
            }
            
            fis = new FileInputStream(zipPath);
            zis = new ZipInputStream(fis);
            
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                String entryName = entry.getName();
                File outputFile = new File(destDir, entryName);
                
                // Security check
                String canonicalDest = destDir.getCanonicalPath();
                String canonicalOutput = outputFile.getCanonicalPath();
                if (!canonicalOutput.startsWith(canonicalDest)) {
                    Log.e(TAG, "ZIP entry tried to escape destination: " + entryName);
                    continue;
                }
                
                if (entry.isDirectory()) {
                    outputFile.mkdirs();
                    continue;
                }
                
                File parentDir = outputFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                
                // Extract with streaming
                FileOutputStream fos = null;
                try {
                    fos = new FileOutputStream(outputFile);
                    int count;
                    while ((count = zis.read(buffer)) != -1) {
                        fos.write(buffer, 0, count);
                    }
                    fos.flush();
                    
                    if (extractedCount % 100 == 0) {
                        try {
                            fos.getFD().sync();
                        } catch (Exception ignored) {}
                    }
                    
                    extractedCount++;
                    totalBytes += entry.getSize();
                } finally {
                    if (fos != null) {
                        try {
                            fos.close();
                        } catch (Exception ignored) {}
                    }
                }
                
                zis.closeEntry();
                
                // Log progress every 30 seconds
                long now = System.currentTimeMillis();
                if (now - lastLogTime > 30000) {
                    Log.d(TAG, "Extraction progress: " + extractedCount + " files, " + (totalBytes / 1048576) + " MB");
                    updateNotification(gameName, extractedCount, totalBytes);
                    lastLogTime = now;
                }
                
                // GC every 500 files to prevent memory buildup
                if (extractedCount % 500 == 0) {
                    System.gc();
                }
            }
            
            Log.d(TAG, "Extraction complete: " + extractedCount + " files, " + (totalBytes / 1048576) + " MB");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "Extraction failed: " + e.getMessage());
            e.printStackTrace();
            return false;
        } finally {
            if (zis != null) {
                try {
                    zis.close();
                } catch (Exception ignored) {}
            }
            if (fis != null) {
                try {
                    fis.close();
                } catch (Exception ignored) {}
            }
        }
    }
    
    private void writeCompletionMarkers(String extractDir, boolean success) {
        try {
            java.io.File dir = new java.io.File(extractDir);
            if (!dir.exists()) {
                dir.mkdirs();
            }
            
            // Write completion marker
            java.io.File completeMarker = new java.io.File(dir, ".extraction_complete");
            java.io.FileWriter writer = new java.io.FileWriter(completeMarker);
            writer.write("complete");
            writer.close();
            Log.d(TAG, "Wrote completion marker: " + completeMarker.getAbsolutePath());
            
            // Write success/failure marker
            java.io.File successMarker = new java.io.File(dir, ".extraction_success");
            writer = new java.io.FileWriter(successMarker);
            writer.write(success ? "true" : "false");
            writer.close();
            Log.d(TAG, "Wrote success marker: " + successMarker.getAbsolutePath() + " = " + success);
        } catch (Exception e) {
            Log.e(TAG, "Failed to write completion markers", e);
        }
    }
}
