package com.heckpoint.kyodai;

import android.app.ActivityManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.Intent;
import android.net.wifi.WifiManager;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.core.app.NotificationCompat;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Foreground service that owns a game session while it runs in another app.
 *
 * Runs in its own process (":session", see AndroidManifest) so it survives a
 * Low Memory Killer sweep of the main Godot process: a ~5 MB Java-only
 * process holding perceptible priority (adj 200) is a rounding error next to
 * a memory-hungry emulator, where the 250+ MB launcher process is not.
 *
 * Responsibilities:
 *  - Hold perceptible priority + a session wake lock / WiFi lock.
 *  - Watch emulator presence via UsageStats (Java port of the conservative
 *    GDScript presence watch: keyguard/empty-query/own-package never count
 *    as misses, launch grace, N consecutive misses end the session).
 *  - On session end, annotate the pending-session record (user:// =
 *    getFilesDir()) with end_unix so the launcher - alive or cold-started -
 *    credits accurate playtime and runs the save upload.
 *  - When the launcher process is dead, bring it back to the foreground so
 *    the upload happens immediately instead of at the user's next visit.
 *
 * Finalization is single-writer: the launcher finalizes whenever it is alive
 * (normal resume path), so this service only annotates when the foreground is
 * neither the emulator nor Kyodai. "Kyodai is foreground" just stops the
 * service - the app's resume handler credits playtime from its own ticks.
 */
public class GameSessionForegroundService extends Service {
    private static final String TAG = "GameSessionService";
    private static final String CHANNEL_ID = "kyodai_game_session";
    private static final int NOTIFICATION_ID = 1003;
    // Safety timeout for the session wake lock; mirrors the GDScript-side cap
    // for recovered sessions. Released on STOP_SESSION in the normal path.
    private static final long MAX_WAKE_LOCK_MS = 12L * 60 * 60 * 1000;
    // Hard cap on service lifetime: without Usage Access the presence watch
    // can't self-terminate, and a redelivered intent must not keep a session
    // (and its locks) alive forever after the launcher abandoned it.
    private static final long MAX_SESSION_MS = MAX_WAKE_LOCK_MS;

    // Presence watch: same cadence/threshold as the old GDScript poll.
    private static final long PRESENCE_POLL_MS = 2000;
    private static final int PRESENCE_MISS_THRESHOLD = 3;
    // Misses only count once the emulator has been seen foregrounded, or
    // while this session is younger than the grace window. Time-based (not
    // seen-based) grace so a process that was killed and resurrected by
    // START_REDELIVER_INTENT long after the game ended still terminates.
    private static final long PRESENCE_GRACE_MS = 60_000;
    // Pending-session record: user://pending_game_session.json on the Godot
    // side; user:// is Context.getFilesDir() on Android.
    private static final String PENDING_SESSION_FILE = "pending_game_session.json";
    private static final String PENDING_SESSION_DIR = "pending_game_sessions";

    private final IBinder binder = new LocalBinder();
    private boolean isRunning = false;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;

    // Session identity (from START_SESSION extras)
    private String gameName = "Game";
    private long startTimeMs = 0;
    private String emulatorPackage = "";
    private long rommId = 0;
    private String pendingSessionFile = PENDING_SESSION_FILE;
    private boolean retainedMode = false;

    // Presence watch state
    private Handler handler;
    private Runnable presencePoll;
    private Runnable sessionCap;
    private boolean emulatorSeen = false;
    private int presenceMisses = 0;

    public class LocalBinder extends Binder {
        GameSessionForegroundService getService() {
            return GameSessionForegroundService.this;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "GameSessionForegroundService created");
        createNotificationChannel();
        handler = new Handler(Looper.getMainLooper());
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            // START_REDELIVER_INTENT should always redeliver; a null intent
            // here means an explicit restart with nothing to re-arm.
            stopSelf();
            return START_NOT_STICKY;
        }

        String action = intent.getAction();
        if (action == null) {
            action = "";
        }

        switch (action) {
            case "START_SESSION":
                String name = intent.getStringExtra("game_name");
                if (name != null) gameName = name;
                startTimeMs = intent.getLongExtra("start_time_ms", System.currentTimeMillis());
                String pkg = intent.getStringExtra("emulator_package");
                if (pkg != null) emulatorPackage = pkg;
                rommId = intent.getLongExtra("romm_id", 0);
                pendingSessionFile = pendingSessionFile(intent.getStringExtra("session_id"));
                retainedMode = intent.getBooleanExtra("retained_mode", false);
                if (retainedMode) {
                    releaseSessionLocks();
                } else if (isRunning) {
                    acquireSessionLocks();
                }
                startForegroundService(gameName, startTimeMs);
                break;

            case "STOP_SESSION":
                stopForegroundService();
                return START_NOT_STICKY;

            default:
                break;
        }

        // Resurrection: if LMK (or a vendor killer) takes this process
        // mid-game, Android restarts the service with the original
        // START_SESSION intent; notification, locks and the presence watch
        // re-arm. The watch's time-based grace still lets it terminate when
        // the game has long ended.
        return START_REDELIVER_INTENT;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Kyodai Game Sessions",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Shown while a game launched from Kyodai is running");
            channel.setSound(null, null);
            channel.enableVibration(false);

            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private void startForegroundService(String gameName, long startTimeMs) {
        if (isRunning) {
            Log.d(TAG, "Service already running");
            return;
        }

        Log.d(TAG, "Starting foreground service for game session: " + gameName);

        Notification notification = buildNotification(gameName, startTimeMs);

        try {
            startForeground(NOTIFICATION_ID, notification);
            isRunning = true;
            SleepSaver.sessionJobStarted(this);
            acquireSessionLocks();
            startPresenceWatch();
            // Lifetime cap: a service that can never detect session end (no
            // Usage Access) still terminates instead of holding locks forever.
            sessionCap = this::stopForegroundService;
            handler.postDelayed(sessionCap, MAX_SESSION_MS);
            Log.d(TAG, "Foreground service started successfully");
        } catch (Exception e) {
            Log.e(TAG, "Failed to start foreground service: " + e.getMessage());
        }
    }

    /**
     * Holds a partial wake lock (time-boxed) and a high-perf WiFi lock for the
     * session so the save upload that runs when the game exits completes even
     * if the screen is off or the device is dozing.
     */
    private void acquireSessionLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null && wakeLock == null) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kyodai:game_session");
                wakeLock.acquire(MAX_WAKE_LOCK_MS);
            }
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
            if (wm != null && wifiLock == null) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "kyodai:game_session");
                wifiLock.acquire();
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to acquire session locks: " + e.getMessage());
        }
    }

    private void releaseSessionLocks() {
        if (wakeLock != null) {
            try {
                if (wakeLock.isHeld()) wakeLock.release();
            } catch (Exception ignored) {}
            wakeLock = null;
        }
        if (wifiLock != null) {
            try {
                if (wifiLock.isHeld()) wifiLock.release();
            } catch (Exception ignored) {}
            wifiLock = null;
        }
    }

    // ------------------------------------------------------------------
    // Presence watch (Java port of the GDScript-side conservative rules)
    // ------------------------------------------------------------------

    private void startPresenceWatch() {
        if (emulatorPackage.isEmpty()) {
            Log.d(TAG, "No emulator package supplied; presence watch disabled");
            return;
        }
        if (!hasUsageStatsPermission()) {
            Log.w(TAG, "Usage Access not granted; presence watch disabled (session ends via launcher)");
            return;
        }
        Log.d(TAG, "Presence watch armed for package: " + emulatorPackage);
        presencePoll = new Runnable() {
            @Override
            public void run() {
                if (!isRunning) return;
                pollPresence();
                if (isRunning && presencePoll != null) {
                    handler.postDelayed(presencePoll, PRESENCE_POLL_MS);
                }
            }
        };
        handler.postDelayed(presencePoll, PRESENCE_POLL_MS);
    }

    private void stopPresenceWatch() {
        if (presencePoll != null) {
            handler.removeCallbacks(presencePoll);
            presencePoll = null;
        }
    }

    private void pollPresence() {
        // Screen off mid-game (pocket, TV sleep) is not a presence miss.
        if (isKeyguardLocked()) return;
        String fg = getForegroundPackage(PRESENCE_POLL_MS * PRESENCE_MISS_THRESHOLD);
        if (fg.isEmpty()) return; // No information - never a miss.
        if (fg.equals(emulatorPackage)) {
            emulatorSeen = true;
            presenceMisses = 0;
            return;
        }
        // Kyodai foreground: its resume path finalizes the session with more
        // accurate tick-based timing; nothing for us to annotate.
        if (fg.startsWith(getPackageName())) {
            if (retainedMode) {
                // Home is a retained transition, not session termination.
                return;
            }
            Log.d(TAG, "Launcher is foreground; ending session service");
            stopPresenceWatch();
            stopForegroundService();
            return;
        }
        boolean withinGrace = System.currentTimeMillis() - startTimeMs < PRESENCE_GRACE_MS;
        if (!emulatorSeen && withinGrace) {
            return; // Emulator hasn't reached the foreground yet (still starting).
        }
        presenceMisses++;
        Log.d(TAG, "Presence miss " + presenceMisses + "/" + PRESENCE_MISS_THRESHOLD + " fg=" + fg);
        if (presenceMisses >= PRESENCE_MISS_THRESHOLD) {
            if (retainedMode) {
                // Another app in the foreground is not proof of task death.
                return;
            }
            Log.d(TAG, "Emulator left the foreground (fg=" + fg + "); ending session");
            // The launcher finalizes itself when alive (its resume path uses
            // the end_unix annotation we leave). Only a dead launcher needs
            // to be brought forward to run the save upload now.
            endSession(!isMainProcessAlive());
        }
    }

    private void endSession(boolean bringToFront) {
        stopPresenceWatch();
        annotatePendingSessionEnd();
        if (bringToFront) {
            bringLauncherToFront();
        }
        stopForegroundService();
    }

    /**
     * Writes end_unix into the pending-session record the launcher dropped
     * before the handoff. Never creates the file: a missing record means the
     * launcher already finalized the session, and recreating it would double
     * the playtime credit on the next boot.
     */
    private String pendingSessionFile(String sessionId) {
        // Session IDs are generated by Kyodai, but keep the native boundary
        // restrictive so an intent can never turn this into a path traversal.
        if (sessionId != null && sessionId.matches("[A-Za-z0-9._-]+")
                && !sessionId.contains("..")) {
            return PENDING_SESSION_DIR + "/" + sessionId + ".json";
        }
        return PENDING_SESSION_FILE;
    }

    private void annotatePendingSessionEnd() {
        File f = new File(getFilesDir(), pendingSessionFile);
        if (!f.exists()) {
            Log.d(TAG, "No pending session record; launcher already finalized");
            return;
        }
        try {
            JSONObject obj;
            String text = readTextFile(f);
            obj = text.isEmpty() ? new JSONObject() : new JSONObject(text);
            obj.put("end_unix", System.currentTimeMillis() / 1000L);
            // Identity fields should already exist; backfill defensively.
            if (!obj.has("romm_id")) obj.put("romm_id", rommId);
            if (!obj.has("title")) obj.put("title", gameName);
            if (!obj.has("start_unix")) obj.put("start_unix", startTimeMs / 1000L);
            writeTextFile(f, obj.toString());
            Log.d(TAG, "Annotated pending session with end_unix");
        } catch (Exception e) {
            Log.w(TAG, "Failed to annotate pending session: " + e.getMessage());
        }
    }

    /**
     * Brings the launcher's activity forward so a killed launcher cold-starts
     * straight into session recovery (playtime + save upload). Background
     * activity starts are restricted on Android 10+; Kyodai is the device's
     * home app in the intended setup, which is exempt. Failure is non-fatal:
     * recovery then happens on the user's next launch.
     */
    private void bringLauncherToFront() {
        try {
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch == null) return;
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
            startActivity(launch);
            Log.d(TAG, "Brought launcher to front for session recovery");
        } catch (Exception e) {
            Log.w(TAG, "Could not bring launcher to front: " + e.getMessage());
        }
    }

    private boolean isMainProcessAlive() {
        try {
            ActivityManager am = (ActivityManager) getSystemService(ACTIVITY_SERVICE);
            if (am == null) return true; // Assume alive: don't yank the user around on a guess.
            for (ActivityManager.RunningAppProcessInfo p : am.getRunningAppProcesses()) {
                if (getPackageName().equals(p.processName)) {
                    return true;
                }
            }
        } catch (Exception e) {
            return true;
        }
        return false;
    }

    private boolean hasUsageStatsPermission() {
        try {
            android.app.AppOpsManager appOps =
                (android.app.AppOpsManager) getSystemService(Context.APP_OPS_SERVICE);
            int mode = appOps.unsafeCheckOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                getPackageName()
            );
            return mode == android.app.AppOpsManager.MODE_ALLOWED;
        } catch (Exception e) {
            Log.e(TAG, "Usage-stats permission check failed: " + e.getMessage());
            return false;
        }
    }

    private String getForegroundPackage(long lookbackMs) {
        try {
            UsageStatsManager usm =
                (UsageStatsManager) getSystemService(Context.USAGE_STATS_SERVICE);
            if (usm == null) return "";
            long now = System.currentTimeMillis();
            UsageEvents events = usm.queryEvents(now - lookbackMs, now);
            UsageEvents.Event ev = new UsageEvents.Event();
            String foreground = "";
            while (events.hasNextEvent()) {
                events.getNextEvent(ev);
                int type = ev.getEventType();
                if (type == UsageEvents.Event.MOVE_TO_FOREGROUND
                        || type == UsageEvents.Event.ACTIVITY_RESUMED) {
                    foreground = ev.getPackageName();
                }
            }
            return foreground != null ? foreground : "";
        } catch (Exception e) {
            Log.e(TAG, "Foreground-package query failed: " + e.getMessage());
            return "";
        }
    }

    private boolean isKeyguardLocked() {
        try {
            android.app.KeyguardManager km =
                (android.app.KeyguardManager) getSystemService(Context.KEYGUARD_SERVICE);
            return km != null && km.isKeyguardLocked();
        } catch (Exception e) {
            return false;
        }
    }

    private static String readTextFile(File f) throws Exception {
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[(int) f.length()];
            int read = 0;
            while (read < buf.length) {
                int n = in.read(buf, read, buf.length - read);
                if (n < 0) break;
                read += n;
            }
            return new String(buf, 0, read, StandardCharsets.UTF_8);
        }
    }

    private static void writeTextFile(File f, String text) throws Exception {
        try (FileOutputStream out = new FileOutputStream(f, false)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
    }

    private Notification buildNotification(String gameName, long startTimeMs) {
        // Create intent to open the app when notification is tapped
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Playing " + gameName)
            .setContentText("Kyodai is keeping your session alive")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            // Live elapsed-time clock rendered by SystemUI; no update traffic needed.
            .setWhen(startTimeMs)
            .setUsesChronometer(true)
            .setShowWhen(true);

        return builder.build();
    }

    private void stopForegroundService() {
        Log.d(TAG, "Stopping foreground service");
        if (isRunning) {
            isRunning = false;
            SleepSaver.sessionJobFinished(this);
        }
        stopPresenceWatch();
        if (sessionCap != null) {
            handler.removeCallbacks(sessionCap);
            sessionCap = null;
        }
        releaseSessionLocks();

        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e(TAG, "Error stopping foreground: " + e.getMessage());
        }

        // Explicitly cancel the notification as a safety net in case
        // stopForeground fails silently on newer Android versions.
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.cancel(NOTIFICATION_ID);
        }

        stopSelf();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        Log.d(TAG, "GameSessionForegroundService destroyed");
        if (isRunning) {
            isRunning = false;
            SleepSaver.sessionJobFinished(this);
        }
        stopPresenceWatch();
        if (handler != null && sessionCap != null) {
            handler.removeCallbacks(sessionCap);
            sessionCap = null;
        }
        releaseSessionLocks();
    }

    public boolean isServiceRunning() {
        return isRunning;
    }
}
