package com.heckpoint.kyodai;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Binder;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;
import androidx.core.app.NotificationCompat;

/**
 * Foreground service to keep Kyodai alive during large file downloads.
 * Prevents Android's Low Memory Killer from terminating the app while downloading.
 */
public class DownloadForegroundService extends Service {
    private static final String TAG = "DownloadService";
    private static final String CHANNEL_ID = "kyodai_downloads";
    private static final int NOTIFICATION_ID = 1001;
    
    private final IBinder binder = new LocalBinder();
    private boolean isRunning = false;
    
    public class LocalBinder extends Binder {
        DownloadForegroundService getService() {
            return DownloadForegroundService.this;
        }
    }
    
    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "DownloadForegroundService created");
        createNotificationChannel();
    }
    
    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }
    
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Log.d(TAG, "DownloadForegroundService started");
        
        if (intent == null) {
            // Service was restarted by system, stop it
            stopSelf();
            return START_NOT_STICKY;
        }
        
        String action = intent.getAction();
        if (action == null) {
            action = "";
        }
        
        switch (action) {
            case "START_DOWNLOAD":
                String gameName = intent.getStringExtra("game_name");
                if (gameName == null) gameName = "Game";
                startForegroundService(gameName);
                break;
                
            case "UPDATE_PROGRESS":
                String currentGame = intent.getStringExtra("game_name");
                int progress = intent.getIntExtra("progress", 0);
                if (currentGame == null) currentGame = "Game";
                updateNotification(currentGame, progress);
                break;
                
            case "STOP_DOWNLOAD":
                stopForegroundService();
                break;
                
            default:
                // Just start the service without foreground notification
                break;
        }
        
        return START_STICKY;
    }
    
    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Kyodai Downloads",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Shows download progress");
            channel.setSound(null, null);
            channel.enableVibration(false);
            
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
    
    private void startForegroundService(String gameName) {
        if (isRunning) {
            Log.d(TAG, "Service already running");
            return;
        }
        
        Log.d(TAG, "Starting foreground service for download: " + gameName);
        
        Notification notification = buildNotification(gameName, 0);
        
        try {
            startForeground(NOTIFICATION_ID, notification);
            isRunning = true;
            Log.d(TAG, "Foreground service started successfully");
        } catch (Exception e) {
            Log.e(TAG, "Failed to start foreground service: " + e.getMessage());
        }
    }
    
    private Notification buildNotification(String gameName, int progress) {
        // Create intent to open the app when notification is tapped
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Downloading " + gameName)
            .setContentText("Kyodai is downloading your game...")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(pendingIntent);
        
        if (progress > 0) {
            builder.setProgress(100, progress, false);
        } else {
            builder.setProgress(0, 0, true); // Indeterminate progress
        }
        
        return builder.build();
    }
    
    private void updateNotification(String gameName, int progress) {
        if (!isRunning) {
            return;
        }
        
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            Notification notification = buildNotification(gameName, progress);
            manager.notify(NOTIFICATION_ID, notification);
        }
    }
    
    private void stopForegroundService() {
        Log.d(TAG, "Stopping foreground service");
        isRunning = false;
        
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e(TAG, "Error stopping foreground: " + e.getMessage());
        }
        
        stopSelf();
    }
    
    @Override
    public void onDestroy() {
        super.onDestroy();
        Log.d(TAG, "DownloadForegroundService destroyed");
        isRunning = false;
    }
    
    public boolean isServiceRunning() {
        return isRunning;
    }
}
