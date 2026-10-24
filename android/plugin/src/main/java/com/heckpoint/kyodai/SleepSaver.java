package com.heckpoint.kyodai;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.core.content.ContextCompat;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Battery savers that act while the display is off:
 *
 *  - Wi-Fi saver: 30 s after the screen turns off, disable Wi-Fi via root
 *    ({@code svc wifi disable}) and re-enable it when the screen wakes.
 *    Skipped while a download/sync/extraction foreground service is active —
 *    killing Wi-Fi mid-download would break the job those services protect.
 *  - Governor saver: at the same 30 s mark, drop every cpufreq policy to
 *    "powersave" (or "schedutil" when powersave is unavailable) and restore
 *    the previous governor on wake. Vendor performance modes can otherwise
 *    keep clocks boosted through sleep.
 *
 * Both require a vendor root daemon (see {@link RootShell}); on devices
 * without one the savers silently no-op and the Godot side hides the toggles.
 *
 * What Kyodai disabled is persisted in SharedPreferences so a process death
 * while asleep can't leave radios/governors stranded: {@link #init(Context)}
 * (called from the plugin constructor, i.e. every app launch, which implies
 * the screen is on) restores anything the saver had turned off.
 */
public final class SleepSaver {

    private static final String TAG = "KyodaiSleepSaver";
    private static final String PREFS = "kyodai_sleep_saver";
    private static final String KEY_WIFI_ENABLED = "wifi_saver_enabled";
    private static final String KEY_GOVERNOR_ENABLED = "governor_saver_enabled";
    private static final String KEY_WIFI_DISABLED = "wifi_disabled_by_saver";
    private static final String KEY_GOVERNOR_SAVED = "governor_saved"; // "path=governor;path=governor"

    private static final long DELAY_MS = 30_000L;
    private static final String CPUFREQ_ROOT = "/sys/devices/system/cpu/cpufreq";

    private static final Object LOCK = new Object();
    private static final AtomicInteger activeJobs = new AtomicInteger(0);
    private static final ExecutorService worker = Executors.newSingleThreadExecutor();

    private static Context appContext;
    private static Handler mainHandler;
    private static BroadcastReceiver screenReceiver;
    private static Runnable pendingSleep;

    private SleepSaver() {}

    // ------------------------------------------------------------------
    // Active-job tracking (download / sync / extractor foreground services)
    // ------------------------------------------------------------------

    public static void jobStarted() {
        activeJobs.incrementAndGet();
    }

    public static void jobFinished() {
        activeJobs.updateAndGet(v -> Math.max(0, v - 1));
    }

    public static boolean hasActiveJobs() {
        return activeJobs.get() > 0;
    }

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    public static boolean isSupported() {
        return RootShell.isAvailable();
    }

    public static boolean isDisplayInteractive(Context context) {
        if (context == null) return true;
        PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        return pm == null || pm.isInteractive();
    }

    /** Called once from the plugin constructor; safe to call again. */
    public static void init(Context context) {
        if (context == null) return;
        synchronized (LOCK) {
            appContext = context.getApplicationContext();
            if (mainHandler == null) {
                mainHandler = new Handler(Looper.getMainLooper());
            }
            updateReceiverLocked();
        }
        // Every app launch implies the screen is on: restore anything a
        // previous process left disabled (e.g. we were killed while asleep).
        worker.execute(SleepSaver::restoreAll);
    }

    public static void setWifiSaverEnabled(Context context, boolean enabled) {
        synchronized (LOCK) {
            if (context != null) appContext = context.getApplicationContext();
            if (appContext == null) return;
            prefs().edit().putBoolean(KEY_WIFI_ENABLED, enabled).apply();
            updateReceiverLocked();
        }
        if (!enabled) {
            // Turning the feature off while asleep must not strand Wi-Fi off.
            worker.execute(SleepSaver::restoreWifi);
        }
    }

    public static void setGovernorSaverEnabled(Context context, boolean enabled) {
        synchronized (LOCK) {
            if (context != null) appContext = context.getApplicationContext();
            if (appContext == null) return;
            prefs().edit().putBoolean(KEY_GOVERNOR_ENABLED, enabled).apply();
            updateReceiverLocked();
        }
        if (!enabled) {
            worker.execute(SleepSaver::restoreGovernors);
        }
    }

    // ------------------------------------------------------------------
    // Receiver management
    // ------------------------------------------------------------------

    private static void updateReceiverLocked() {
        boolean wanted = prefs().getBoolean(KEY_WIFI_ENABLED, false)
                || prefs().getBoolean(KEY_GOVERNOR_ENABLED, false);
        if (wanted && screenReceiver == null) {
            screenReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    if (intent == null || intent.getAction() == null) return;
                    switch (intent.getAction()) {
                        case Intent.ACTION_SCREEN_OFF:
                            onScreenOff();
                            break;
                        case Intent.ACTION_SCREEN_ON:
                            onScreenOn();
                            break;
                    }
                }
            };
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_SCREEN_OFF);
            filter.addAction(Intent.ACTION_SCREEN_ON);
            ContextCompat.registerReceiver(appContext, screenReceiver, filter,
                    ContextCompat.RECEIVER_NOT_EXPORTED);
            Log.d(TAG, "Screen receiver armed");
        } else if (!wanted && screenReceiver != null) {
            try {
                appContext.unregisterReceiver(screenReceiver);
            } catch (Exception e) {
                Log.w(TAG, "unregisterReceiver failed: " + e.getMessage());
            }
            screenReceiver = null;
            cancelPendingLocked();
            Log.d(TAG, "Screen receiver disarmed");
        }
    }

    private static void onScreenOff() {
        synchronized (LOCK) {
            cancelPendingLocked();
            pendingSleep = () -> worker.execute(SleepSaver::applySleepState);
            mainHandler.postDelayed(pendingSleep, DELAY_MS);
        }
        Log.d(TAG, "Screen off; sleep savers scheduled in " + DELAY_MS + "ms");
    }

    private static void onScreenOn() {
        synchronized (LOCK) {
            cancelPendingLocked();
        }
        worker.execute(SleepSaver::restoreAll);
    }

    private static void cancelPendingLocked() {
        if (pendingSleep != null) {
            mainHandler.removeCallbacks(pendingSleep);
            pendingSleep = null;
        }
    }

    // ------------------------------------------------------------------
    // Sleep / wake transitions (worker thread)
    // ------------------------------------------------------------------

    private static void applySleepState() {
        Context ctx = appContext;
        if (ctx == null) return;
        if (isDisplayInteractive(ctx)) {
            // Screen came back on without a SCREEN_ON broadcast (rare) — bail.
            return;
        }
        SharedPreferences p = prefs();

        if (p.getBoolean(KEY_WIFI_ENABLED, false)) {
            if (hasActiveJobs()) {
                Log.d(TAG, "Skipping Wi-Fi saver: background job active");
            } else if (isWifiOn(ctx)) {
                RootShell.Result r = RootShell.run(ctx, "svc wifi disable");
                if (r != null && r.succeeded()) {
                    p.edit().putBoolean(KEY_WIFI_DISABLED, true).apply();
                    Log.d(TAG, "Wi-Fi disabled for sleep");
                } else {
                    Log.w(TAG, "svc wifi disable failed (root route unavailable?)");
                }
            }
        }

        if (p.getBoolean(KEY_GOVERNOR_ENABLED, false)) {
            dropGovernors(ctx);
        }
    }

    private static void restoreAll() {
        restoreWifi();
        restoreGovernors();
    }

    private static void restoreWifi() {
        Context ctx = appContext;
        if (ctx == null) return;
        SharedPreferences p = prefs();
        if (!p.getBoolean(KEY_WIFI_DISABLED, false)) return;
        // Clear first: a failed restore must not retry forever on every launch.
        p.edit().putBoolean(KEY_WIFI_DISABLED, false).apply();
        RootShell.Result r = RootShell.run(ctx, "svc wifi enable");
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Wi-Fi restored after sleep");
        } else {
            Log.w(TAG, "svc wifi enable failed");
        }
    }

    // ------------------------------------------------------------------
    // CPU governor
    // ------------------------------------------------------------------

    private static void dropGovernors(Context ctx) {
        // Query current + available governors for every cpufreq policy.
        RootShell.Result query = RootShell.run(ctx,
                "for p in " + CPUFREQ_ROOT + "/policy*; do "
                        + "g=$(cat \"$p/scaling_governor\" 2>/dev/null); "
                        + "a=$(cat \"$p/scaling_available_governors\" 2>/dev/null); "
                        + "[ -n \"$g\" ] && echo \"POLICY|$p|$g|$a\"; "
                        + "done");
        if (query == null || query.output == null) {
            Log.w(TAG, "Governor query failed (no root route?)");
            return;
        }

        List<String> writes = new ArrayList<>();
        StringBuilder saved = new StringBuilder();
        for (String line : query.output.split("\n")) {
            String[] parts = line.trim().split("\\|");
            if (parts.length < 3 || !"POLICY".equals(parts[0])) continue;
            String path = parts[1];
            String current = parts[2];
            String available = parts.length > 3 ? parts[3] : "";

            String target = null;
            if ((" " + available + " ").contains(" powersave ")) {
                target = "powersave";
            } else if ((" " + available + " ").contains(" schedutil ")
                    && !"schedutil".equals(current)) {
                target = "schedutil";
            }
            if (target == null || target.equals(current)) continue;

            if (saved.length() > 0) saved.append(";");
            saved.append(path).append("=").append(current);
            writes.add("echo " + RootShell.quote(target) + " > "
                    + RootShell.quote(path + "/scaling_governor"));
        }

        if (writes.isEmpty()) {
            Log.d(TAG, "No governor change needed");
            return;
        }

        SharedPreferences p = prefs();
        // Only overwrite the saved map when no sleep drop is currently active,
        // so a stale saved map can't clobber the true pre-sleep governors.
        String previous = p.getString(KEY_GOVERNOR_SAVED, "");
        if (previous == null || previous.isEmpty()) {
            p.edit().putString(KEY_GOVERNOR_SAVED, saved.toString()).apply();
        }

        StringBuilder script = new StringBuilder();
        for (String w : writes) {
            script.append(w).append('\n');
        }
        RootShell.Result r = RootShell.run(ctx, script.toString());
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Governors dropped for sleep: " + saved);
        } else {
            Log.w(TAG, "Governor write failed");
        }
    }

    private static void restoreGovernors() {
        Context ctx = appContext;
        if (ctx == null) return;
        SharedPreferences p = prefs();
        String saved = p.getString(KEY_GOVERNOR_SAVED, "");
        if (saved == null || saved.isEmpty()) return;
        // Clear first: a failed restore must not retry forever on every launch.
        p.edit().putString(KEY_GOVERNOR_SAVED, "").apply();

        StringBuilder script = new StringBuilder();
        boolean any = false;
        for (String entry : saved.split(";")) {
            int eq = entry.indexOf('=');
            if (eq <= 0) continue;
            String path = entry.substring(0, eq);
            String governor = entry.substring(eq + 1);
            if (governor.isEmpty()) continue;
            script.append("echo ").append(RootShell.quote(governor)).append(" > ")
                    .append(RootShell.quote(path + "/scaling_governor")).append('\n');
            any = true;
        }
        if (!any) return;
        RootShell.Result r = RootShell.run(ctx, script.toString());
        if (r != null && r.succeeded()) {
            Log.d(TAG, "Governors restored after sleep: " + saved);
        } else {
            Log.w(TAG, "Governor restore failed");
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static SharedPreferences prefs() {
        return appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static boolean isWifiOn(Context ctx) {
        try {
            WifiManager wm = (WifiManager) ctx.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            return wm != null && wm.isWifiEnabled();
        } catch (Exception e) {
            Log.w(TAG, "isWifiOn failed: " + e.getMessage());
            return false;
        }
    }
}
