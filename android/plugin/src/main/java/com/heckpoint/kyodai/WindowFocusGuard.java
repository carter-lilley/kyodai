package com.heckpoint.kyodai;

import android.app.Activity;
import android.content.Context;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;

/**
 * Hardens the window against the native IME (Gboard) attaching to Godot's
 * hidden GodotEditText and swallowing gamepad key events through the input
 * connection - a failure mode seen when Kyodai is the default HOME app
 * (observed on AYN Thor).
 */
public class WindowFocusGuard {
    private static final String TAG = "WindowFocusGuard";

    private final Activity activity;

    public WindowFocusGuard(Activity activity) {
        this.activity = activity;
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
}
