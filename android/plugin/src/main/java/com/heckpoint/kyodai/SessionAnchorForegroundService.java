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

/**
 * Minimal foreground service whose only job is holding perceptible priority
 * (adj ~200) for the MAIN process during a game session.
 *
 * The session logic (presence watch, locks, session-end annotation) lives in
 * GameSessionForegroundService, which runs in its own tiny ":session"
 * process so it survives an LMK kill of the Godot process. But
 * startForeground() only promotes the process that hosts the service, so
 * without this anchor the 250+ MB main process sits in the cached tier
 * (adj 700) and is LMK's first victim the moment an emulator ramps up.
 *
 * The notification is IMPORTANCE_MIN (silent, no status-bar icon); the
 * user-facing session clock lives on the :session service's notification.
 *
 * START_NOT_STICKY: once the main process is dead, this anchor protects
 * nothing, and a redelivery would park a Godot-less main process at
 * perceptible priority mid-game, competing with the emulator for memory.
 * GDScript re-arms the anchor with the next session.
 */
public class SessionAnchorForegroundService extends Service {
    private static final String TAG = "SessionAnchorService";
    private static final String CHANNEL_ID = "kyodai_session_anchor";
    private static final int NOTIFICATION_ID = 1004;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        if ("STOP_ANCHOR".equals(action)) {
            stopAnchor();
            return START_NOT_STICKY;
        }
        if ("START_ANCHOR".equals(action)) {
            startAnchor();
        }
        return START_NOT_STICKY;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Kyodai Session Protection",
                NotificationManager.IMPORTANCE_MIN
            );
            channel.setDescription("Keeps Kyodai responsive in the background while a game runs");
            channel.setSound(null, null);
            channel.enableVibration(false);
            channel.setShowBadge(false);

            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private void startAnchor() {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );

        Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Game session protection active")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build();

        try {
            startForeground(NOTIFICATION_ID, notification);
            Log.d(TAG, "Session anchor started (main process promoted)");
        } catch (Exception e) {
            Log.e(TAG, "Failed to start session anchor: " + e.getMessage());
        }
    }

    private void stopAnchor() {
        Log.d(TAG, "Session anchor stopping");
        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e(TAG, "Error stopping foreground: " + e.getMessage());
        }
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.cancel(NOTIFICATION_ID);
        }
        stopSelf();
    }
}
