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
 * Foreground service to keep Kyodai alive during metadata sync from RomM server.
 * Prevents Android's Low Memory Killer from terminating the app while syncing games.
 * Displays sync progress including platform name and game count.
 */
public class SyncForegroundService extends Service {
    private static final String TAG = "SyncForegroundService";
    private static final String CHANNEL_ID = "kyodai_sync";
    private static final int NOTIFICATION_ID = 1002;
    
    private final IBinder binder = new LocalBinder();
    private boolean isRunning = false;
    private String currentPlatform = "";
    private int currentGame = 0;
    private int totalGames = 0;
    
    public class LocalBinder extends Binder {
        SyncForegroundService getService() {
            return SyncForegroundService.this;
        }
    }
    
    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "SyncForegroundService created");
        createNotificationChannel();
    }
    
    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }
    
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
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
            case "START_SYNC":
                Log.d(TAG, "SyncForegroundService started");
                String platformName = intent.getStringExtra("platform_name");
                if (platformName == null) platformName = "Game Library";
                int current = intent.getIntExtra("current", 0);
                int total = intent.getIntExtra("total", 0);
                startForegroundService(platformName, current, total);
                break;
                
            case "UPDATE_PROGRESS":
                String updatePlatform = intent.getStringExtra("platform_name");
                if (updatePlatform == null) updatePlatform = currentPlatform;
                int updateCurrent = intent.getIntExtra("current", currentGame);
                int updateTotal = intent.getIntExtra("total", totalGames);
                updateNotification(updatePlatform, updateCurrent, updateTotal);
                break;
                
            case "STOP_SYNC":
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
                "Kyodai Sync",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Shows sync progress from RomM server");
            channel.setSound(null, null);
            channel.enableVibration(false);
            
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
    
    private void startForegroundService(String platformName, int current, int total) {
        if (isRunning) {
            Log.d(TAG, "Service already running, updating notification");
            updateNotification(platformName, current, total);
            return;
        }
        
        Log.d(TAG, "Starting foreground service for sync: " + platformName);
        
        this.currentPlatform = platformName;
        this.currentGame = current;
        this.totalGames = total;
        
        Notification notification = buildNotification(platformName, current, total);
        
        try {
            startForeground(NOTIFICATION_ID, notification);
            isRunning = true;
            SleepSaver.jobStarted();
            Log.d(TAG, "Sync foreground service started successfully");
        } catch (Exception e) {
            Log.e(TAG, "Failed to start sync foreground service: " + e.getMessage());
        }
    }
    
    private Notification buildNotification(String platformName, int current, int total) {
        // Create intent to open the app when notification is tapped
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        String contentText = buildProgressText(current, total);
        
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Syncing " + platformName)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setContentIntent(pendingIntent);
        
        if (total > 0) {
            int percent = (int) ((current / (float) total) * 100);
            builder.setProgress(100, percent, false);
        } else {
            builder.setProgress(0, 0, true); // Indeterminate progress
        }
        
        return builder.build();
    }
    
    private String buildProgressText(int current, int total) {
        if (total > 0) {
            int percent = (int) ((current / (float) total) * 100);
            return String.format("%,d / %,d games (%d%%)", current, total, percent);
        }
        return "Preparing sync...";
    }
    
    private void updateNotification(String platformName, int current, int total) {
        if (!isRunning) {
            return;
        }
        
        this.currentPlatform = platformName;
        this.currentGame = current;
        this.totalGames = total;
        
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            Notification notification = buildNotification(platformName, current, total);
            manager.notify(NOTIFICATION_ID, notification);
        }
    }
    
    private void stopForegroundService() {
        Log.d(TAG, "Stopping sync foreground service");
        if (isRunning) {
            isRunning = false;
            SleepSaver.jobFinished();
        }
        
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e(TAG, "Error stopping sync foreground: " + e.getMessage());
        }
        
        stopSelf();
    }
    
    @Override
    public void onDestroy() {
        super.onDestroy();
        Log.d(TAG, "SyncForegroundService destroyed");
        if (isRunning) {
            isRunning = false;
            SleepSaver.jobFinished();
        }
    }
    
    public boolean isServiceRunning() {
        return isRunning;
    }
}
