package com.heckpoint.kyodai;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;

/**
 * Guards against two Android failure modes seen when Kyodai becomes the
 * default HOME app while it is already running (observed on AYN Thor):
 *
 * 1. The native IME (Gboard) attaches to Godot's hidden GodotEditText and
 *    swallows gamepad key events through the input connection.
 * 2. The activity resumes but no window ever gains input focus
 *    (InputDispatcher loses track of the display), dropping every key event.
 *
 * Recovery for (2) nudges the system display pipeline by toggling the
 * preferred display mode, which replays display-changed callbacks into
 * InputDispatcher. If focus still never arrives, a window_focus_stuck
 * signal is emitted once so the app can advise a reboot.
 */
public class WindowFocusGuard {
    private static final String TAG = "WindowFocusGuard";
    private static final long WATCHDOG_DELAY_MS = 1500;
    private static final long WATCHDOG_RETRY_MS = 2500;
    private static final long WATCHDOG_SLOW_RETRY_MS = 8000;
    private static final long DISPLAY_MODE_REVERT_MS = 1000;
    private static final int FAST_RECOVERY_ATTEMPTS = 3;

    private final Activity activity;
    private final Runnable onFocusStuck;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private int recoveryAttempts = 0;
    private boolean stuckSignalSent = false;
    private boolean displayModeToggled = false;

    private final Runnable watchdog = new Runnable() {
        @Override
        public void run() {
            if (activity == null || activity.isFinishing() || activity.isDestroyed()) {
                return;
            }
            if (activity.hasWindowFocus()) {
                if (recoveryAttempts > 0 || stuckSignalSent) {
                    Log.i(TAG, "Window focus recovered");
                }
                recoveryAttempts = 0;
                stuckSignalSent = false;
                return;
            }
            Log.w(TAG, "Window has no input focus after resume; recovery attempt " + recoveryAttempts);
            hardenWindow();
            toggleDisplayMode();
            if (recoveryAttempts < FAST_RECOVERY_ATTEMPTS) {
                recoveryAttempts++;
                handler.postDelayed(this, WATCHDOG_RETRY_MS);
            } else {
                if (!stuckSignalSent) {
                    stuckSignalSent = true;
                    Log.e(TAG, "Window focus stuck; notifying app");
                    onFocusStuck.run();
                }
                handler.postDelayed(this, WATCHDOG_SLOW_RETRY_MS);
            }
        }
    };

    public WindowFocusGuard(Activity activity, Runnable onFocusStuck) {
        this.activity = activity;
        this.onFocusStuck = onFocusStuck;
    }

    /** Call from activity resume / new intent delivery. */
    public void onResumeOrNewIntent() {
        hardenWindow();
        handler.removeCallbacks(watchdog);
        recoveryAttempts = 0;
        handler.postDelayed(watchdog, WATCHDOG_DELAY_MS);
    }

    /** Call from activity pause; overlays (permission/SAF dialogs) take focus legitimately. */
    public void onPause() {
        handler.removeCallbacks(watchdog);
    }

    public boolean hasWindowFocus() {
        return activity != null && activity.hasWindowFocus();
    }

    /**
     * Hardens the window against the native IME: always-hidden soft input,
     * hides any visible IME, and disables soft-input-on-focus for Godot's
     * hidden EditText so it can never summon the OS keyboard again.
     */
    public void hardenWindow() {
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) {
            return;
        }
        try {
            Window window = activity.getWindow();
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);

            View decor = window.getDecorView();
            InputMethodManager imm =
                    (InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.hideSoftInputFromWindow(decor.getWindowToken(), 0);
            }

            View editText = findGodotEditText(decor);
            if (editText instanceof EditText) {
                ((EditText) editText).setShowSoftInputOnFocus(false);
            }

            if (!decor.hasFocus()) {
                decor.requestFocus();
            }
        } catch (Exception e) {
            Log.e(TAG, "hardenWindow failed: " + e.getMessage());
        }
    }

    private View findGodotEditText(View root) {
        if (root.getClass().getName().equals("org.godotengine.godot.input.GodotEditText")) {
            return root;
        }
        if (root instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) root;
            for (int i = 0; i < group.getChildCount(); i++) {
                View found = findGodotEditText(group.getChildAt(i));
                if (found != null) {
                    return found;
                }
            }
        }
        return null;
    }

    /**
     * Briefly switches the window's preferred display mode to an alternate
     * mode at the same resolution, then reverts to the system default. The
     * resulting display-mode change replays display callbacks into the input
     * pipeline, which re-registers the display with InputDispatcher.
     */
    private void toggleDisplayMode() {
        if (displayModeToggled) {
            return;
        }
        try {
            Display display = activity.getWindowManager().getDefaultDisplay();
            if (display == null) {
                return;
            }
            Display.Mode current = display.getMode();
            for (Display.Mode mode : display.getSupportedModes()) {
                if (mode.getModeId() != current.getModeId()
                        && mode.getPhysicalWidth() == current.getPhysicalWidth()
                        && mode.getPhysicalHeight() == current.getPhysicalHeight()) {
                    displayModeToggled = true;
                    WindowManager.LayoutParams lp = activity.getWindow().getAttributes();
                    lp.preferredDisplayModeId = mode.getModeId();
                    activity.getWindow().setAttributes(lp);
                    Log.i(TAG, "Toggled preferred display mode to " + mode.getModeId());
                    handler.postDelayed(() -> {
                        WindowManager.LayoutParams revert = activity.getWindow().getAttributes();
                        revert.preferredDisplayModeId = 0;
                        activity.getWindow().setAttributes(revert);
                        displayModeToggled = false;
                    }, DISPLAY_MODE_REVERT_MS);
                    return;
                }
            }
            Log.w(TAG, "No alternate display mode available to toggle");
        } catch (Exception e) {
            Log.e(TAG, "toggleDisplayMode failed: " + e.getMessage());
        }
    }
}
