package com.heckpoint.kyodai;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import androidx.core.content.FileProvider;
import org.godotengine.godot.Godot;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

public class PackageCheckerPlugin extends GodotPlugin {
    
    private static final String TAG = "PackageChecker";
    private static final String ACTION_EXTRACTION_COMPLETE = "com.heckpoint.kyodai.EXTRACTION_COMPLETE";
    private static final String SAF_PREFS = "kyodai_saf";
    private static final String SAF_TREE_URIS_KEY = "android_data_tree_uris";
    private static final int REQUEST_SAF_TREE = 0x5AF1;
    private static final String DOCS_AUTHORITY = "com.android.externalstorage.documents";
    private static final String ALT_ACCESS_DIR = "KyodaiUC";
    private Activity activity;
    private BroadcastReceiver extractionReceiver;
    private WindowFocusGuard windowFocusGuard;
    
    public PackageCheckerPlugin(Godot godot) {
        super(godot);
        Log.d(TAG, "PackageCheckerPlugin constructor called");
        this.activity = godot.getActivity();
        Log.d(TAG, "Activity obtained: " + (activity != null ? "YES" : "NO"));
        if (this.activity != null) {
            this.windowFocusGuard = new WindowFocusGuard(activity, () -> emitSignal("window_focus_stuck"));
        }
        registerExtractionReceiver();
    }
    
    @Override
    public String getPluginName() {
        return "PackageChecker";
    }
    
    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(new SignalInfo("extraction_complete", Boolean.class, String.class, String.class));
        signals.add(new SignalInfo("copy_progress", String.class, Long.class, Long.class));
        signals.add(new SignalInfo("copy_complete", String.class, Boolean.class, String.class, String.class));
        signals.add(new SignalInfo("chunk_flush_complete", String.class, Boolean.class, String.class));
        signals.add(new SignalInfo("saf_grant_result", Boolean.class));
        signals.add(new SignalInfo("window_focus_stuck"));
        return signals;
    }
    
    @Override
    public void onMainResume() {
        if (windowFocusGuard != null) {
            windowFocusGuard.onResumeOrNewIntent();
        }
    }
    
    @Override
    public void onMainPause() {
        if (windowFocusGuard != null) {
            windowFocusGuard.onPause();
        }
    }
    
    // No @Override: onNewIntent is missing from the Godot 4.2 compile-time
    // stub, but the 4.7 runtime dispatches to it via virtual dispatch.
    public void onNewIntent(Intent intent) {
        if (windowFocusGuard != null) {
            windowFocusGuard.onResumeOrNewIntent();
        }
    }
    
    /// Hides the native IME and re-hardens the window against soft-input takeover.
    @UsedByGodot
    public void forceHideKeyboard() {
        if (windowFocusGuard != null) {
            windowFocusGuard.hardenWindow();
        }
    }
    
    /// True while the activity window holds input focus.
    @UsedByGodot
    public boolean hasWindowFocus() {
        return windowFocusGuard != null && windowFocusGuard.hasWindowFocus();
    }
    
    private void registerExtractionReceiver() {
        if (activity == null) return;
        
        extractionReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (ACTION_EXTRACTION_COMPLETE.equals(intent.getAction())) {
                    boolean success = intent.getBooleanExtra("success", false);
                    String zipPath = intent.getStringExtra("zip_path");
                    String extractDir = intent.getStringExtra("extract_dir");
                    Log.d(TAG, "Extraction complete broadcast received: success=" + success + 
                        ", zip=" + zipPath + ", dir=" + extractDir);
                    emitSignal("extraction_complete", success, zipPath, extractDir);
                }
            }
        };
        
        IntentFilter filter = new IntentFilter(ACTION_EXTRACTION_COMPLETE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(extractionReceiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            activity.registerReceiver(extractionReceiver, filter);
        }
        Log.d(TAG, "Registered extraction completion receiver");
    }
    
    @UsedByGodot
    public boolean isPackageInstalled(String packageName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "isPackageInstalled() called with: " + packageName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        Log.d(TAG, "Activity is valid, getting PackageManager...");
        
        try {
            PackageManager pm = activity.getPackageManager();
            Log.d(TAG, "PackageManager obtained");
            
            // Try to get package info - use modern API for Android 13+ (API 33+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Log.d(TAG, "Using modern API (Android 13+)");
                pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0));
            } else {
                Log.d(TAG, "Using legacy API");
                pm.getPackageInfo(packageName, 0);
            }
            
            Log.d(TAG, "SUCCESS: Package '" + packageName + "' is INSTALLED");
            Log.d(TAG, "==========================================");
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            Log.d(TAG, "Package '" + packageName + "' is NOT installed");
            Log.d(TAG, "==========================================");
            return false;
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking package '" + packageName + "': " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    @UsedByGodot
    public String getInstalledLaunchableApps() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getInstalledLaunchableApps() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return "[]";
        }
        
        try {
            PackageManager pm = activity.getPackageManager();
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_LAUNCHER);
            List<ResolveInfo> apps = pm.queryIntentActivities(intent, 0);
            
            org.json.JSONArray result = new org.json.JSONArray();
            float density = activity.getResources().getDisplayMetrics().density;
            int iconSize = Math.round(48 * density);
            
            for (ResolveInfo info : apps) {
                String packageName = info.activityInfo.applicationInfo.packageName;
                String name = info.loadLabel(pm).toString();
                String iconBase64 = "";
                
                try {
                    Drawable icon = info.loadIcon(pm);
                    if (icon != null) {
                        Bitmap bitmap = drawableToBitmap(icon);
                        bitmap = Bitmap.createScaledBitmap(bitmap, iconSize, iconSize, true);
                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos);
                        byte[] bytes = baos.toByteArray();
                        iconBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP);
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Failed to load icon for " + packageName + ": " + e.getMessage());
                }
                
                org.json.JSONObject app = new org.json.JSONObject();
                app.put("name", name);
                app.put("package", packageName);
                app.put("icon", iconBase64);
                result.put(app);
            }
            
            Log.d(TAG, "Found " + result.length() + " launchable apps");
            Log.d(TAG, "==========================================");
            return result.toString();
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting installed apps: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return "[]";
        }
    }
    
    private Bitmap drawableToBitmap(Drawable drawable) {
        if (drawable instanceof BitmapDrawable) {
            return ((BitmapDrawable) drawable).getBitmap();
        }
        int width = Math.max(1, drawable.getIntrinsicWidth());
        int height = Math.max(1, drawable.getIntrinsicHeight());
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, canvas.getWidth(), canvas.getHeight());
        drawable.draw(canvas);
        return bitmap;
    }
    
    /**
     * Launch a Steam game via GameNative app.
     * 
     * @param appId The Steam App ID to launch
     * @return true if intent was launched successfully
     */
    @UsedByGodot
    public boolean launchGameNativeGame(int appId) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchGameNativeGame() called");
        Log.d(TAG, "App ID: " + appId);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Create intent for GameNative
            Intent intent = new Intent();
            intent.setComponent(new ComponentName("app.gamenative", "app.gamenative.MainActivity"));
            intent.setAction("app.gamenative.LAUNCH_GAME");
            intent.addCategory(Intent.CATEGORY_DEFAULT);
            intent.putExtra("app_id", appId);
            
            // Add flags for launching from another app
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            
            Log.d(TAG, "Launching GameNative with App ID: " + appId);
            Log.d(TAG, "Intent action: " + intent.getAction());
            Log.d(TAG, "Intent component: " + intent.getComponent());
            
            activity.startActivity(intent);
            
            Log.d(TAG, "SUCCESS: GameNative launch intent sent");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching GameNative game: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    /**
     * Vibrates the device for haptic feedback.
     * Requires the VIBRATE permission.
     * 
     * @param durationMs Duration of vibration in milliseconds
     * @return true if vibration was triggered successfully
     */
    @UsedByGodot
    public boolean vibrateDevice(int durationMs) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "vibrateDevice() called");
        Log.d(TAG, "Duration: " + durationMs + "ms");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            android.os.Vibrator vibrator = (android.os.Vibrator) activity.getSystemService(Context.VIBRATOR_SERVICE);
            
            if (vibrator == null) {
                Log.e(TAG, "ERROR: Vibrator service is null");
                return false;
            }
            
            if (!vibrator.hasVibrator()) {
                Log.w(TAG, "WARNING: Device does not have a vibrator");
                return false;
            }
            
            // Vibrate for the specified duration with lower intensity
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                // Use VibrationEffect for API 26+ with lower amplitude (80 instead of DEFAULT_AMPLITUDE)
                vibrator.vibrate(android.os.VibrationEffect.createOneShot(durationMs, 80));
            } else {
                // Deprecated method for older APIs
                vibrator.vibrate(durationMs);
            }
            
            Log.d(TAG, "SUCCESS: Vibration triggered");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR vibrating device: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    // ============================================================================
    // Dual Screen / Display Detection Methods
    // ============================================================================
    
    /**
     * Get the number of displays connected to the device.
     * This is useful for detecting dual screen devices like Ayn Thor.
     * 
     * @return The number of displays (1 for single screen, 2+ for dual/multi screen)
     */
    @UsedByGodot
    public int getDisplayCount() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getDisplayCount() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return 1;
        }
        
        try {
            // Use DisplayManager to get all displays
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return 1;
            }
            
            // Get all displays (including virtual displays)
            android.view.Display[] displays = displayManager.getDisplays();
            int displayCount = displays.length;
            
            Log.d(TAG, "Found " + displayCount + " displays:");
            for (int i = 0; i < displays.length; i++) {
                android.view.Display display = displays[i];
                Log.d(TAG, "  Display " + i + ": ID=" + display.getDisplayId() +
                      ", Name=" + display.getName() +
                      ", IsValid=" + display.isValid());
                
                // Get display metrics
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                Log.d(TAG, "    Resolution: " + metrics.widthPixels + "x" + metrics.heightPixels);
            }
            
            Log.d(TAG, "==========================================");
            return displayCount;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting display count: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return 1;
        }
    }
    
    /**
     * Check if the device has multiple physical displays.
     * Filters out virtual displays by checking:
     * 1. Display must be valid and not the default display
     * 2. Display must have a different resolution than the built-in screen
     * 3. Display name must not contain virtual/overlay keywords
     * 4. Display state must be ON (not OFF or DOZE)
     * 
     * @return true if a real secondary physical display is connected
     */
    @UsedByGodot
    public boolean hasMultipleDisplays() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "hasMultipleDisplays() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return false;
            }
            
            // Get default display resolution for comparison
            android.view.Display defaultDisplay = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY);
            if (defaultDisplay == null) {
                Log.e(TAG, "ERROR: Default display is null");
                return false;
            }
            
            android.util.DisplayMetrics defaultMetrics = new android.util.DisplayMetrics();
            defaultDisplay.getRealMetrics(defaultMetrics);
            Log.d(TAG, "Default display: " + defaultMetrics.widthPixels + "x" + defaultMetrics.heightPixels);
            
            // Get all displays and filter
            android.view.Display[] allDisplays = displayManager.getDisplays();
            Log.d(TAG, "Total displays found: " + allDisplays.length);
            
            for (int i = 0; i < allDisplays.length; i++) {
                android.view.Display display = allDisplays[i];
                int displayId = display.getDisplayId();
                String displayName = display.getName();
                int displayState = display.getState();
                
                // Skip default display
                if (displayId == android.view.Display.DEFAULT_DISPLAY) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (default display)");
                    continue;
                }
                
                // Skip invalid displays
                if (!display.isValid()) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (not valid)");
                    continue;
                }
                
                // Skip displays that are off
                if (displayState != android.view.Display.STATE_ON) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + "]: SKIPPED (state=" + displayState + ", not ON)");
                    continue;
                }
                
                // Get metrics
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                
                // Skip virtual displays with same resolution as default
                // (mirrored/virtual displays typically match the primary screen resolution)
                boolean sameResolution = (metrics.widthPixels == defaultMetrics.widthPixels && 
                                          metrics.heightPixels == defaultMetrics.heightPixels) ||
                                         (metrics.widthPixels == defaultMetrics.heightPixels && 
                                          metrics.heightPixels == defaultMetrics.widthPixels);
                
                if (sameResolution) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: SKIPPED (same resolution " + 
                          metrics.widthPixels + "x" + metrics.heightPixels + ")");
                    continue;
                }
                
                // Skip displays with virtual/overlay keywords in name
                String nameLower = displayName.toLowerCase();
                if (nameLower.contains("virtual") || nameLower.contains("overlay") || 
                    nameLower.contains("scrcpy") || nameLower.contains("screenrecorder")) {
                    Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: SKIPPED (virtual keyword)");
                    continue;
                }
                
                // This looks like a real secondary display
                Log.d(TAG, "  Display " + i + " [ID=" + displayId + ", Name=" + displayName + "]: VALID secondary display (" + 
                      metrics.widthPixels + "x" + metrics.heightPixels + ")");
                Log.d(TAG, "hasMultipleDisplays result: true");
                Log.d(TAG, "==========================================");
                return true;
            }
            
            Log.d(TAG, "No valid secondary displays found");
            Log.d(TAG, "hasMultipleDisplays result: false");
            Log.d(TAG, "==========================================");
            return false;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking for multiple displays: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Get debug information about all displays as a formatted string.
     * Returns a Dictionary with a "info" key containing the display details.
     * This avoids issues with ArrayList/Dictionary conversion between Java and Godot.
     * 
     * @return Dictionary with "info" string and "count" int
     */
    @UsedByGodot
    public Dictionary getDisplayDebugInfo() {
        Dictionary result = new Dictionary();
        StringBuilder info = new StringBuilder();
        
        if (activity == null) {
            result.put("info", "Activity is null");
            result.put("count", 0);
            return result;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                result.put("info", "DisplayManager is null");
                result.put("count", 0);
                return result;
            }
            
            android.view.Display[] allDisplays = displayManager.getDisplays();
            result.put("count", allDisplays.length);
            
            // Get default display metrics
            android.view.Display defaultDisplay = displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY);
            android.util.DisplayMetrics defaultMetrics = new android.util.DisplayMetrics();
            if (defaultDisplay != null) {
                defaultDisplay.getRealMetrics(defaultMetrics);
            }
            
            info.append("Total displays: ").append(allDisplays.length).append("\n");
            info.append("Default: ").append(defaultMetrics.widthPixels).append("x").append(defaultMetrics.heightPixels).append("\n");
            
            for (int i = 0; i < allDisplays.length; i++) {
                android.view.Display display = allDisplays[i];
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                display.getRealMetrics(metrics);
                
                boolean isDefault = display.getDisplayId() == android.view.Display.DEFAULT_DISPLAY;
                boolean sameResolution = (metrics.widthPixels == defaultMetrics.widthPixels && 
                                          metrics.heightPixels == defaultMetrics.heightPixels) ||
                                         (metrics.widthPixels == defaultMetrics.heightPixels && 
                                          metrics.heightPixels == defaultMetrics.widthPixels);
                
                info.append("Display ").append(i)
                    .append(": ID=").append(display.getDisplayId())
                    .append(", Name=").append(display.getName())
                    .append(", State=").append(display.getState())
                    .append(", ").append(metrics.widthPixels).append("x").append(metrics.heightPixels)
                    .append(", Default=").append(isDefault)
                    .append(", SameRes=").append(sameResolution)
                    .append("\n");
            }
            
            result.put("info", info.toString());
            return result;
            
        } catch (Exception e) {
            result.put("info", "Error: " + e.getMessage());
            result.put("count", 0);
            return result;
        }
    }
    
    /**
     * Get information about the second display (if available).
     * Returns a dictionary with display properties.
     * 
     * @return Dictionary with display info, or empty dict if no second display
     */
    @UsedByGodot
    public Dictionary getSecondDisplayInfo() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "getSecondDisplayInfo() called");
        
        Dictionary result = new Dictionary();
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return result;
        }
        
        try {
            android.hardware.display.DisplayManager displayManager = 
                (android.hardware.display.DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
            
            if (displayManager == null) {
                Log.e(TAG, "ERROR: DisplayManager is null");
                return result;
            }
            
            // Find the second display (non-default display)
            android.view.Display[] displays = displayManager.getDisplays();
            android.view.Display secondDisplay = null;
            
            for (android.view.Display display : displays) {
                if (display.getDisplayId() != android.view.Display.DEFAULT_DISPLAY && display.isValid()) {
                    secondDisplay = display;
                    break;
                }
            }
            
            if (secondDisplay == null) {
                Log.d(TAG, "No second display found");
                return result;
            }
            
            // Get display metrics
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
            secondDisplay.getRealMetrics(metrics);
            
            // Populate result dictionary
            result.put("id", secondDisplay.getDisplayId());
            result.put("name", secondDisplay.getName());
            result.put("width", metrics.widthPixels);
            result.put("height", metrics.heightPixels);
            result.put("density", metrics.density);
            result.put("xdpi", metrics.xdpi);
            result.put("ydpi", metrics.ydpi);
            
            Log.d(TAG, "Second display info:");
            Log.d(TAG, "  ID: " + secondDisplay.getDisplayId());
            Log.d(TAG, "  Name: " + secondDisplay.getName());
            Log.d(TAG, "  Resolution: " + metrics.widthPixels + "x" + metrics.heightPixels);
            
            Log.d(TAG, "==========================================");
            return result;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR getting second display info: " + e.getMessage());
            return result;
        }
    }
    
    /**
     * Checks if the app has MANAGE_EXTERNAL_STORAGE permission (All Files Access on Android 11+)
     * 
     * @return true if permission is granted, false otherwise
     */
    @UsedByGodot
    public boolean hasManageExternalStoragePermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "hasManageExternalStoragePermission() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            boolean hasPermission = android.os.Environment.isExternalStorageManager();
            Log.d(TAG, "MANAGE_EXTERNAL_STORAGE permission: " + hasPermission);
            Log.d(TAG, "==========================================");
            return hasPermission;
        } else {
            // On older versions, check for WRITE_EXTERNAL_STORAGE
            int permission = activity.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE);
            boolean hasPermission = permission == PackageManager.PERMISSION_GRANTED;
            Log.d(TAG, "WRITE_EXTERNAL_STORAGE permission: " + hasPermission);
            Log.d(TAG, "==========================================");
            return hasPermission;
        }
    }
    
    /**
     * Requests MANAGE_EXTERNAL_STORAGE permission by opening system settings.
     * The user must manually grant this permission.
     * 
     * @return true if settings intent was launched successfully
     */
    @UsedByGodot
    public boolean requestManageExternalStoragePermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "requestManageExternalStoragePermission() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Open system settings for All Files Access permission
                Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + activity.getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                activity.startActivity(intent);
                Log.d(TAG, "Launched system settings for MANAGE_EXTERNAL_STORAGE");
            } else {
                // On older versions, request WRITE_EXTERNAL_STORAGE normally
                activity.requestPermissions(
                    new String[]{android.Manifest.permission.WRITE_EXTERNAL_STORAGE},
                    1001
                );
                Log.d(TAG, "Requested WRITE_EXTERNAL_STORAGE permission");
            }
            
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR requesting permission: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Opens the app's details page in Android Settings so the user can enable
     * "Install unknown apps" permission. Uses ACTION_APPLICATION_DETAILS_SETTINGS
     * with the proper package: URI instead of the unreliable ACTION_VIEW.
     *
     * @return true if the settings intent was launched successfully
     */
    @UsedByGodot
    public boolean requestInstallUnknownAppsPermission() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "requestInstallUnknownAppsPermission() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            intent.setData(Uri.parse("package:" + activity.getPackageName()));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
            Log.d(TAG, "Launched application details settings for install unknown apps");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "ERROR opening install unknown apps settings: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    // ============================================================================
    // Content URI Resolution (No SAF - requires MANAGE_EXTERNAL_STORAGE)
    // ============================================================================
    
    /**
     * Resolves a content:// URI to a real filesystem path.
     * Parses external storage document URIs without using SAF or ContentResolver.
     * Requires MANAGE_EXTERNAL_STORAGE permission for the returned path to be usable.
     * 
     * Supports:
     * - Document URIs: content://.../document/primary:path/to/file
     * - Tree URIs: content://.../tree/primary:path/to/file
     * 
     * @param contentUri The content:// URI to resolve
     * @return The real filesystem path, or the original URI if it cannot be resolved
     */
    @UsedByGodot
    public String resolveContentUriToRealPath(String contentUri) {
        if (contentUri == null || contentUri.isEmpty()) {
            return "";
        }
        
        if (!contentUri.startsWith("content://")) {
            return contentUri;
        }
        
        try {
            // Handle external storage document URIs
            // Format: content://com.android.externalstorage.documents/document/primary:path/to/file
            if (contentUri.contains("com.android.externalstorage.documents")) {
                String docId = null;
                
                // Try /document/ format first
                int docPos = contentUri.lastIndexOf("/document/");
                if (docPos != -1) {
                    docId = contentUri.substring(docPos + 10); // Skip "/document/"
                } else {
                    // Try /tree/ format
                    int treePos = contentUri.lastIndexOf("/tree/");
                    if (treePos != -1) {
                        docId = contentUri.substring(treePos + 6); // Skip "/tree/"
                    }
                }
                
                if (docId != null && !docId.isEmpty()) {
                    // URL decode the docId
                    docId = java.net.URLDecoder.decode(docId, "UTF-8");
                    
                    // Parse format: "primary:path/to/file" or "XXXX-XXXX:path/to/file"
                    int colonPos = docId.indexOf(':');
                    if (colonPos != -1) {
                        String storage = docId.substring(0, colonPos);
                        String path = docId.substring(colonPos + 1);
                        
                        if ("primary".equalsIgnoreCase(storage)) {
                            return "/storage/emulated/0/" + path;
                        } else {
                            // For other storage volumes (SD cards, etc.)
                            return "/storage/" + storage + "/" + path;
                        }
                    }
                }
            }
            
            // Handle media documents
            if (contentUri.contains("com.android.providers.media.documents")) {
                // Try to query the MediaStore for the file path
                Uri uri = Uri.parse(contentUri);
                String[] projection = {android.provider.MediaStore.MediaColumns.DATA};
                try (android.database.Cursor cursor = activity.getContentResolver().query(uri, projection, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        int columnIndex = cursor.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATA);
                        String dataPath = cursor.getString(columnIndex);
                        if (dataPath != null && !dataPath.isEmpty()) {
                            return dataPath;
                        }
                    }
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error resolving content URI: " + contentUri + " - " + e.getMessage());
        }
        
        // Return original if we couldn't resolve it
        return contentUri;
    }

    /**
     * Imports a content:// URI into app storage by streaming its bytes through
     * the ContentResolver. Used for URIs that cannot be resolved to a real
     * filesystem path (e.g. Downloads provider "msf:" documents) and whose
     * temporary read permission would not survive an app restart.
     *
     * @param contentUri The content:// URI to import
     * @param destDir    Absolute destination directory (created if missing)
     * @return The absolute path of the imported file, or "" on failure
     */
    @UsedByGodot
    public String importContentUri(String contentUri, String destDir) {
        if (contentUri == null || !contentUri.startsWith("content://")) {
            return "";
        }
        if (activity == null || destDir == null || destDir.isEmpty()) {
            return "";
        }

        InputStream inputStream = null;
        OutputStream outputStream = null;
        try {
            Uri uri = Uri.parse(contentUri);

            // Query the display name so the imported file keeps its name/extension
            String displayName = null;
            try (android.database.Cursor cursor = activity.getContentResolver().query(
                    uri, new String[]{android.provider.OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    int idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                    if (idx != -1) {
                        displayName = cursor.getString(idx);
                    }
                }
            }
            if (displayName == null || displayName.isEmpty()) {
                displayName = "imported_file";
            }
            // Sanitize path separators out of the display name
            displayName = displayName.replace("/", "_").replace("\\", "_");

            File dir = new File(destDir);
            if (!dir.exists() && !dir.mkdirs()) {
                Log.e(TAG, "importContentUri: could not create dest dir: " + destDir);
                return "";
            }

            File destFile = new File(dir, displayName);
            inputStream = activity.getContentResolver().openInputStream(uri);
            if (inputStream == null) {
                Log.e(TAG, "importContentUri: could not open input stream for: " + contentUri);
                return "";
            }
            outputStream = new FileOutputStream(destFile);

            byte[] buffer = new byte[65536];
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
            }
            outputStream.flush();

            Log.d(TAG, "importContentUri: imported " + contentUri + " -> " + destFile.getAbsolutePath());
            return destFile.getAbsolutePath();

        } catch (Exception e) {
            Log.e(TAG, "importContentUri: error importing " + contentUri + " - " + e.getMessage());
            return "";
        } finally {
            try {
                if (outputStream != null) outputStream.close();
                if (inputStream != null) inputStream.close();
            } catch (Exception ignored) {
            }
        }
    }

    // ==================== FOREGROUND SERVICE FOR DOWNLOADS ====================
    
    /**
     * Reassembles chunked download files into a single file.
     * This runs natively to avoid Godot memory overhead during large file operations.
     * 
     * @param chunkPathsJson JSON array of chunk file paths in order
     * @param outputPath Final output file path
     * @return true if successful
     */
    @UsedByGodot
    public boolean reassembleChunks(String chunkPathsJson, String outputPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "reassembleChunks() called");
        Log.d(TAG, "Output path: " + outputPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        java.io.FileOutputStream outputStream = null;
        java.io.FileInputStream inputStream = null;
        
        try {
            // Parse chunk paths from JSON
            org.json.JSONArray chunkPaths = new org.json.JSONArray(chunkPathsJson);
            int chunkCount = chunkPaths.length();
            Log.d(TAG, "Reassembling " + chunkCount + " chunks");
            
            // Create output file
            java.io.File outputFile = new java.io.File(outputPath);
            java.io.File parentDir = outputFile.getParentFile();
            if (parentDir != null && !parentDir.exists()) {
                parentDir.mkdirs();
            }
            
            outputStream = new java.io.FileOutputStream(outputFile);
            
            // 16MB buffer for efficient copying
            byte[] buffer = new byte[16 * 1024 * 1024];
            long totalBytesWritten = 0;
            long lastProgressLog = 0;
            
            // Copy each chunk
            for (int i = 0; i < chunkCount; i++) {
                String chunkPath = chunkPaths.getString(i);
                java.io.File chunkFile = new java.io.File(chunkPath);
                
                if (!chunkFile.exists()) {
                    Log.e(TAG, "ERROR: Chunk file not found: " + chunkPath);
                    outputStream.close();
                    outputFile.delete();
                    return false;
                }
                
                inputStream = new java.io.FileInputStream(chunkFile);
                int bytesRead;
                long chunkBytesWritten = 0;
                
                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, bytesRead);
                    totalBytesWritten += bytesRead;
                    chunkBytesWritten += bytesRead;
                }
                
                inputStream.close();
                inputStream = null;
                
                // Log progress every 100MB
                if (totalBytesWritten - lastProgressLog > 100 * 1024 * 1024) {
                    Log.d(TAG, "Reassembly progress: " + (i + 1) + "/" + chunkCount + 
                          " chunks, " + (totalBytesWritten / (1024 * 1024)) + " MB written");
                    lastProgressLog = totalBytesWritten;
                }
            }
            
            outputStream.flush();
            outputStream.close();
            outputStream = null;
            
            Log.d(TAG, "SUCCESS: Reassembled " + chunkCount + " chunks, " + 
                  totalBytesWritten + " bytes total");
            Log.d(TAG, "Output file: " + outputFile.getAbsolutePath());
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR reassembling chunks: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            
            // Clean up on failure
            try {
                if (outputStream != null) outputStream.close();
                if (inputStream != null) inputStream.close();
                // Delete partial output file
                java.io.File outputFile = new java.io.File(outputPath);
                if (outputFile.exists()) {
                    outputFile.delete();
                }
            } catch (Exception cleanupError) {
                Log.e(TAG, "Error during cleanup: " + cleanupError.getMessage());
            }
            
            return false;
        }
    }
    
    /**
     * Copies a file asynchronously, emitting progress and completion signals.
     * Used for the final copy from the app-private temp dir to the destination,
     * including restricted /Android/data/ paths via DocumentsContract.
     * 
     * @param sourcePath Source file path (must be directly readable)
     * @param destPath Destination file path
     * @param itemName Display name for signals
     * @return true if the async copy was started
     */
    @UsedByGodot
    public boolean copyFileAsync(String sourcePath, String destPath, String itemName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "copyFileAsync() called");
        Log.d(TAG, "Source: " + sourcePath);
        Log.d(TAG, "Dest: " + destPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        new Thread(() -> {
            java.io.FileInputStream inputStream = null;
            java.io.OutputStream outputStream = null;
            
            try {
                java.io.File sourceFile = directFile(sourcePath);
                if (!sourceFile.exists()) {
                    throw new Exception("Source file not found: " + sourcePath);
                }
                
                long totalBytes = sourceFile.length();
                long copiedBytes = 0;
                long lastProgressBytes = 0;
                
                inputStream = new java.io.FileInputStream(sourceFile);
                
                // Create output stream: direct File first (AltAccess symlink for
                // restricted paths), DocumentsContract as fallback
                java.io.File outputFile = directFile(destPath);
                java.io.File parentDir = outputFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                if (parentDir != null && parentDir.canWrite()) {
                    outputStream = new java.io.FileOutputStream(outputFile);
                } else if (requiresDocumentsContract(destPath)) {
                    Uri docUri = pathToDocumentUri(destPath);
                    if (docUri == null) {
                        throw new Exception("Could not create document URI for: " + destPath);
                    }
                    outputStream = activity.getContentResolver().openOutputStream(docUri);
                    if (outputStream == null) {
                        throw new Exception("Could not open output stream for: " + destPath);
                    }
                } else {
                    outputStream = new java.io.FileOutputStream(outputFile);
                }
                
                // 16MB buffer for efficient copying
                byte[] buffer = new byte[16 * 1024 * 1024];
                int bytesRead;
                
                while ((bytesRead = inputStream.read(buffer)) != -1) {
                    outputStream.write(buffer, 0, bytesRead);
                    copiedBytes += bytesRead;
                    
                    // Emit progress every 50MB
                    if (copiedBytes - lastProgressBytes > 50 * 1024 * 1024) {
                        final long progressCopied = copiedBytes;
                        final long progressTotal = totalBytes;
                        activity.runOnUiThread(() -> emitSignal("copy_progress", itemName, progressCopied, progressTotal));
                        lastProgressBytes = copiedBytes;
                    }
                }
                
                outputStream.flush();
                outputStream.close();
                outputStream = null;
                inputStream.close();
                inputStream = null;
                
                Log.d(TAG, "SUCCESS: Copied " + copiedBytes + " bytes to " + destPath);
                Log.d(TAG, "==========================================");
                activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, true, destPath, ""));
                
            } catch (Exception e) {
                Log.e(TAG, "ERROR copying file: " + e.getMessage());
                Log.e(TAG, "Exception type: " + e.getClass().getName());
                
                try {
                    if (outputStream != null) outputStream.close();
                    if (inputStream != null) inputStream.close();
                    // Clean up partial destination file
                    if (!requiresDocumentsContract(destPath)) {
                        java.io.File outputFile = directFile(destPath);
                        if (outputFile.exists()) {
                            outputFile.delete();
                        }
                    }
                } catch (Exception cleanupError) {
                    Log.e(TAG, "Error during copy cleanup: " + cleanupError.getMessage());
                }
                
                final String errorMsg = e.getMessage();
                activity.runOnUiThread(() -> emitSignal("copy_complete", itemName, false, destPath, errorMsg));
            }
        }).start();
        
        return true;
    }
    
    // ========================================================================
    // Chunked flush mode: chunk temp files are written directly into the
    // final destination at their byte offsets as each chunk completes, so the
    // end-of-download full-file copy disappears. Works for direct paths
    // (RandomAccessFile), AltAccess-aliased paths, and SAF DocumentsContract
    // paths (ParcelFileDescriptor "rw" + positioned FileChannel writes).
    // ========================================================================

    /** Single-thread executor: sequential flushes avoid flash write thrash. */
    private java.util.concurrent.ExecutorService chunkFlushExecutor = null;

    /**
     * Probes whether a destination supports positioned writes. Shrinks stale
     * oversized leftovers (instant), but never eagerly extends: growing a
     * file zero-fills the gap on exFAT/FUSE, which can block for minutes on
     * multi-GB files. Positioned flush writes grow the file lazily instead.
     * Returns false if chunked flush mode cannot be used (caller falls back
     * to temp-dir assembly + final copy).
     */
    @UsedByGodot
    public boolean prepareChunkedDestination(String destPath, long totalSize) {
        if (activity == null || destPath == null || destPath.isEmpty()) {
            return false;
        }
        try {
            File file = directFile(destPath);
            File parent = file.getParentFile();
            if (parent != null && !parent.exists()) {
                parent.mkdirs();
            }
            if (parent != null && parent.canWrite()) {
                java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
                if (totalSize > 0 && raf.length() > totalSize) {
                    raf.setLength(totalSize);
                }
                // Fresh file: prove beyond-EOF positioned writes with a cheap
                // small-offset write (chunk 0 overwrites this byte anyway).
                if (raf.length() == 0) {
                    raf.seek(Math.min(Math.max(totalSize - 1, 0), 1024));
                    raf.write(0);
                }
                raf.close();
                return true;
            }
            if (requiresDocumentsContract(destPath)) {
                Uri uri = ensureDocumentExists(destPath);
                if (uri == null) {
                    return false;
                }
                android.os.ParcelFileDescriptor pfd =
                        activity.getContentResolver().openFileDescriptor(uri, "rw");
                if (pfd == null) {
                    return false;
                }
                java.nio.channels.FileChannel channel =
                        new FileOutputStream(pfd.getFileDescriptor()).getChannel();
                long size = channel.size();
                if (totalSize > 0 && size > totalSize) {
                    channel.truncate(totalSize);
                }
                if (size == 0) {
                    channel.position(Math.min(Math.max(totalSize - 1, 0), 1024));
                    channel.write(java.nio.ByteBuffer.allocate(1));
                }
                channel.close();
                pfd.close();
                return true;
            }
            // Last resort: plain direct access
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
            if (totalSize > 0 && raf.length() > totalSize) {
                raf.setLength(totalSize);
            }
            if (raf.length() == 0) {
                raf.seek(Math.min(Math.max(totalSize - 1, 0), 1024));
                raf.write(0);
            }
            raf.close();
            return true;
        } catch (Exception e) {
            Log.w(TAG, "prepareChunkedDestination failed for " + destPath + ": " + e.getMessage());
            return false;
        }
    }

    /** Creates the destination document via DocumentsContract if missing. */
    private Uri ensureDocumentExists(String path) {
        Uri uri = documentUriFor(path);
        if (uri == null) {
            return null;
        }
        try {
            android.os.ParcelFileDescriptor probe =
                    activity.getContentResolver().openFileDescriptor(uri, "r");
            if (probe != null) {
                probe.close();
                return uri;
            }
        } catch (Exception e) {
            Log.d(TAG, "ensureDocumentExists: doc missing, creating: " + e.getMessage());
        }
        String parentPath = path.substring(0, path.lastIndexOf('/'));
        String name = path.substring(path.lastIndexOf('/') + 1);
        Uri parentUri = documentUriFor(parentPath);
        if (parentUri == null) {
            return null;
        }
        try {
            return DocumentsContract.createDocument(
                    activity.getContentResolver(), parentUri, "application/octet-stream", name);
        } catch (Exception e) {
            Log.w(TAG, "ensureDocumentExists: createDocument failed: " + e.getMessage());
            return null;
        }
    }

    /**
     * Flushes a downloaded chunk temp file into the destination at the given
     * byte offset, asynchronously. Emits chunk_flush_complete(token, success, error).
     */
    @UsedByGodot
    public boolean flushChunkAsync(String chunkPath, String destPath, long offset, String token) {
        if (activity == null) {
            return false;
        }
        if (chunkFlushExecutor == null) {
            chunkFlushExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
        }
        chunkFlushExecutor.execute(() -> {
            boolean success = false;
            String error = "";
            try {
                success = writeChunkAt(chunkPath, destPath, offset);
                if (!success) {
                    error = "No writable destination for: " + destPath;
                }
            } catch (Exception e) {
                error = String.valueOf(e.getMessage());
                Log.e(TAG, "flushChunk failed: " + chunkPath + " -> " + destPath + " @" + offset + ": " + error);
            }
            final boolean s = success;
            final String err = error;
            activity.runOnUiThread(() -> emitSignal("chunk_flush_complete", token, s, err));
        });
        return true;
    }

    /** Streams a chunk file into the destination at a byte offset. */
    private boolean writeChunkAt(String chunkPath, String destPath, long offset) throws Exception {
        File chunkFile = new File(chunkPath);
        if (!chunkFile.exists()) {
            throw new Exception("Chunk file not found: " + chunkPath);
        }
        byte[] buffer = new byte[8 * 1024 * 1024];
        FileInputStream in = new FileInputStream(chunkFile);
        try {
            File file = directFile(destPath);
            File parent = file.getParentFile();
            if (parent != null && parent.canWrite()) {
                java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
                try {
                    raf.seek(offset);
                    int r;
                    while ((r = in.read(buffer)) != -1) {
                        raf.write(buffer, 0, r);
                    }
                } finally {
                    raf.close();
                }
                return true;
            }
            if (requiresDocumentsContract(destPath)) {
                Uri uri = documentUriFor(destPath);
                if (uri == null) {
                    return false;
                }
                android.os.ParcelFileDescriptor pfd =
                        activity.getContentResolver().openFileDescriptor(uri, "rw");
                if (pfd == null) {
                    return false;
                }
                java.nio.channels.FileChannel channel =
                        new FileOutputStream(pfd.getFileDescriptor()).getChannel();
                try {
                    channel.position(offset);
                    java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(buffer);
                    int r;
                    while ((r = in.read(buffer)) != -1) {
                        bb.clear();
                        bb.limit(r);
                        while (bb.hasRemaining()) {
                            channel.write(bb);
                        }
                    }
                } finally {
                    channel.close();
                    pfd.close();
                }
                return true;
            }
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw");
            try {
                raf.seek(offset);
                int r;
                while ((r = in.read(buffer)) != -1) {
                    raf.write(buffer, 0, r);
                }
            } finally {
                raf.close();
            }
            return true;
        } finally {
            in.close();
        }
    }

    /**
     * Returns the size of a file in bytes, using DocumentsContract for
     * restricted paths. Returns -1 if the file is missing or unreadable.
     */
    @UsedByGodot
    public long androidFileSize(String path) {
        if (path == null || path.isEmpty()) {
            return -1;
        }
        File file = directFile(path);
        if (file.exists()) {
            return file.length();
        }
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                            docUri,
                            new String[]{DocumentsContract.Document.COLUMN_SIZE},
                            null, null, null);
                    if (cursor != null) {
                        long size = -1;
                        if (cursor.moveToFirst() && !cursor.isNull(0)) {
                            size = cursor.getLong(0);
                        }
                        cursor.close();
                        return size;
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "androidFileSize failed for " + path + ": " + e.getMessage());
            }
        }
        return -1;
    }

    /**
     * Starts the foreground service to prevent Android from killing the app during downloads.
     * Shows a persistent notification while downloads are active.
     */
    @UsedByGodot
    public void startDownloadForegroundService(String gameName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "startDownloadForegroundService() called");
        Log.d(TAG, "Game: " + gameName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("START_DOWNLOAD");
            intent.putExtra("game_name", gameName);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "Foreground service started successfully");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR starting foreground service: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
        }
    }
    
    /**
     * Updates the foreground service notification with download progress.
     */
    @UsedByGodot
    public void updateDownloadForegroundService(String gameName, int progress) {
        if (activity == null) {
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("UPDATE_PROGRESS");
            intent.putExtra("game_name", gameName);
            intent.putExtra("progress", progress);
            
            activity.startService(intent);
        } catch (Exception e) {
            Log.e(TAG, "ERROR updating foreground service: " + e.getMessage());
        }
    }
    
    // ============================================================================
    // DocumentsContract File Access for /Android/data/ and /Android/obb/
    // ============================================================================
    
    /**
     * Checks if a path requires DocumentsContract to access.
     * On Android 11+, /Android/data/ and /Android/obb/ are restricted
     * even with MANAGE_EXTERNAL_STORAGE.
     */
    @UsedByGodot
    public boolean requiresDocumentsContract(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false; // Android 10 and below can access directly
        }
        
        // Check if path is in restricted directories
        return path.contains("/Android/data/") || path.contains("/Android/obb/");
    }

    // ========================================================================
    // AltAccess: direct File I/O for restricted paths via storage-root symlinks.
    // Mirrors argosy-launcher's AndroidDataAccessor. The FUSE daemon filters
    // /Android/data|obb by path prefix; a symlink from an unfiltered location
    // (e.g. <storage>/KyodaiUC/data -> /storage/emulated/0/Android/data) is
    // served without re-checking the target, giving full direct access with
    // only MANAGE_EXTERNAL_STORAGE. Falls through to SAF when unsupported.
    // ========================================================================

    private volatile Boolean altAccessSupported = null;

    /** Returns the restricted-path alias for direct I/O, or the original path. */
    private String transformPath(String path) {
        if (path == null || !isAltAccessSupported()) return path;
        for (String root : getAltStorageRoots()) {
            if (path.startsWith(root + "/Android/data/")) {
                return root + "/" + ALT_ACCESS_DIR + "/data/" + path.substring((root + "/Android/data/").length());
            }
            if (path.startsWith(root + "/Android/obb/")) {
                return root + "/" + ALT_ACCESS_DIR + "/obb/" + path.substring((root + "/Android/obb/").length());
            }
        }
        return path;
    }

    /** File to use for direct I/O: the symlink-aliased path when restricted. */
    private File directFile(String path) {
        return new File(transformPath(path));
    }

    @UsedByGodot
    public boolean isAltAccessSupported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false;
        boolean hasManageStorage = Environment.isExternalStorageManager();
        Log.d(TAG, "[AltAccess] isExternalStorageManager=" + hasManageStorage);
        if (hasManageStorage) {
            Boolean cached = altAccessSupported;
            if (cached != null) return cached;
        }
        synchronized (this) {
            if (hasManageStorage) {
                Boolean cached = altAccessSupported;
                if (cached != null) return cached;
            }
            boolean anySupported = false;
            for (String root : getAltStorageRoots()) {
                if (setupAndVerifyAltAccess(root, hasManageStorage)) {
                    anySupported = true;
                }
            }
            Log.i(TAG, "[AltAccess] supported=" + anySupported);
            if (hasManageStorage) {
                altAccessSupported = anySupported;
            }
            return anySupported;
        }
    }

    private List<String> getAltStorageRoots() {
        List<String> roots = new java.util.ArrayList<>();
        roots.add(Environment.getExternalStorageDirectory().getAbsolutePath());
        try {
            File[] vols = new File("/storage").listFiles();
            if (vols != null) {
                for (File vol : vols) {
                    if (vol.isDirectory() && !vol.getName().equals("emulated") && !vol.getName().equals("self")) {
                        String path = vol.getAbsolutePath();
                        if (!roots.contains(path) && new File(vol, "Android/data").exists()) {
                            roots.add(path);
                        }
                    }
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "[AltAccess] Failed to enumerate storage volumes: " + e.getMessage());
        }
        return roots;
    }

    private boolean setupAndVerifyAltAccess(String storageRoot, boolean hasManageStorage) {
        try {
            File altDir = new File(storageRoot, ALT_ACCESS_DIR);
            File dataLink = new File(altDir, "data");
            if (hasManageStorage && !dataLink.exists()) {
                setupAltAccess(storageRoot, altDir, dataLink);
            }
            boolean ok = altDir.exists() && dataLink.canRead();
            Log.d(TAG, "[AltAccess] verify " + storageRoot + ": altDir.exists=" + altDir.exists()
                    + " dataLink.exists=" + dataLink.exists() + " dataLink.canRead=" + dataLink.canRead());
            return ok;
        } catch (Exception e) {
            Log.w(TAG, "[AltAccess] Path check failed for " + storageRoot + ": " + e.getMessage());
            return false;
        }
    }

    private void setupAltAccess(String storageRoot, File altDir, File dataLink) {
        try {
            if (!altDir.exists()) altDir.mkdirs();
            if (!dataLink.exists()) {
                android.system.Os.symlink(storageRoot + "/Android/data", dataLink.getAbsolutePath());
            }
            File obbLink = new File(altDir, "obb");
            if (!obbLink.exists()) {
                android.system.Os.symlink(storageRoot + "/Android/obb", obbLink.getAbsolutePath());
            }
            Log.i(TAG, "[AltAccess] Symlinks created for " + storageRoot);
        } catch (Exception e) {
            Log.w(TAG, "[AltAccess] Setup failed for " + storageRoot + ": " + e.getMessage());
        }
    }
    
    // ========================================================================
    // SAF tree grant for /Android/data/ and /Android/obb/
    // Mirrors argosy-launcher's ManagedStorageAccessor: a persisted document-tree
    // grant (user picks the "Android" or "Android/data" folder once) is preferred;
    // without it we fall back to bare document URIs with the manage=true query
    // parameter, which ExternalStorageProvider honors for MANAGE_EXTERNAL_STORAGE
    // holders.
    // ========================================================================

    /**
     * Launches the system folder picker so the user can grant access to an
     * emulator's app-data folder. When targetPath is under Android/data/<pkg>
     * (or obb), the picker is pointed at that package subfolder — subfolders
     * are not on DocumentsUI's blocklist even though the data/obb roots are.
     * Result arrives via the saf_grant_result signal.
     */
    @UsedByGodot
    public void requestAndroidDataAccess(String targetPath) {
        if (activity == null) {
            emitSignal("saf_grant_result", false);
            return;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        String docId = targetPath != null ? packageDocIdFor(targetPath) : null;
        if (docId == null) {
            docId = "primary:Android/data";
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Uri initial = DocumentsContract.buildDocumentUri(DOCS_AUTHORITY, docId);
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial);
        }
        try {
            activity.startActivityForResult(intent, REQUEST_SAF_TREE);
        } catch (Exception e) {
            Log.e(TAG, "requestAndroidDataAccess failed: " + e.getMessage());
            emitSignal("saf_grant_result", false);
        }
    }

    @Override
    public void onMainActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_SAF_TREE) return;
        boolean granted = false;
        if (resultCode == Activity.RESULT_OK && data != null && data.getData() != null) {
            Uri treeUri = data.getData();
            try {
                activity.getContentResolver().takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                Set<String> uris = new HashSet<>(getStoredTreeUriStrings());
                uris.add(treeUri.toString());
                activity.getSharedPreferences(SAF_PREFS, Context.MODE_PRIVATE)
                        .edit().putStringSet(SAF_TREE_URIS_KEY, uris).apply();
                granted = true;
                Log.d(TAG, "SAF tree grant persisted: " + treeUri);
            } catch (Exception e) {
                Log.e(TAG, "Failed to persist SAF grant: " + e.getMessage());
            }
        }
        emitSignal("saf_grant_result", granted);
    }

    /** Returns true if any persisted read+write document-tree grant exists. */
    @UsedByGodot
    public boolean hasSafGrant() {
        if (activity == null) return false;
        for (UriPermission p : activity.getContentResolver().getPersistedUriPermissions()) {
            if (p.isReadPermission() && p.isWritePermission()
                    && p.getUri().toString().startsWith("content://" + DOCS_AUTHORITY + "/tree/")) {
                return true;
            }
        }
        return false;
    }

    /** Returns true if a persisted tree grant covers the given path. */
    @UsedByGodot
    public boolean hasSafGrantFor(String path) {
        return treeUriForPath(path) != null;
    }

    private Set<String> getStoredTreeUriStrings() {
        if (activity == null) return new HashSet<>();
        return activity.getSharedPreferences(SAF_PREFS, Context.MODE_PRIVATE)
                .getStringSet(SAF_TREE_URIS_KEY, new HashSet<String>());
    }

    /**
     * Extracts the Android/data|obb package subfolder docId for a path.
     * e.g. /storage/emulated/0/Android/data/com.foo/files/x -> "primary:Android/data/com.foo"
     */
    private String packageDocIdFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String[] segs = vp[1].split("/");
        if (segs.length >= 3 && segs[0].equals("Android")
                && (segs[1].equals("data") || segs[1].equals("obb"))) {
            return vp[0] + ":" + segs[0] + "/" + segs[1] + "/" + segs[2];
        }
        return null;
    }

    /** Finds a persisted read+write tree grant whose tree covers the given path. */
    private Uri treeUriForPath(String path) {
        if (activity == null) return null;
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String targetDocId = vp[0] + ":" + vp[1];
        for (UriPermission p : activity.getContentResolver().getPersistedUriPermissions()) {
            if (!p.isReadPermission() || !p.isWritePermission()) continue;
            Uri uri = p.getUri();
            if (!uri.toString().startsWith("content://" + DOCS_AUTHORITY + "/tree/")) continue;
            try {
                String treeDocId = DocumentsContract.getTreeDocumentId(uri);
                if (targetDocId.equals(treeDocId) || targetDocId.startsWith(treeDocId + "/")) {
                    return uri;
                }
            } catch (Exception ignored) {}
        }
        return null;
    }

    /**
     * Splits an absolute path into {volumeId, relativePath}.
     * /storage/emulated/0/... -> volume "primary"; /storage/XXXX-XXXX/... -> that id.
     */
    private String[] splitVolumePath(String path) {
        if (path == null) return null;
        if (path.startsWith("/storage/emulated/0/")) {
            return new String[]{"primary", path.substring("/storage/emulated/0/".length())};
        }
        if (path.startsWith("/sdcard/")) {
            return new String[]{"primary", path.substring("/sdcard/".length())};
        }
        if (path.startsWith("/storage/")) {
            String[] parts = path.split("/");
            if (parts.length >= 4) {
                String volumeId = parts[2];
                return new String[]{volumeId, path.substring(("/storage/" + volumeId + "/").length())};
            }
        }
        return null;
    }

    /** Appends manage=true for /Android/data|obb paths (honored by ExternalStorageProvider for MES holders). */
    private Uri applyManagedParameter(Uri uri, String relativePath) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return uri;
        boolean needsManaged = relativePath.startsWith("Android/data")
                || relativePath.startsWith("Android/obb")
                || relativePath.equals("Android");
        return needsManaged ? uri.buildUpon().appendQueryParameter("manage", "true").build() : uri;
    }

    /**
     * Builds a document URI for an absolute path. Order: covering persisted
     * tree grant, legacy tree/<volume>-scoped URI (served by some providers
     * for MANAGE_EXTERNAL_STORAGE holders), bare URI + manage=true.
     */
    private Uri documentUriFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String docId = vp[0] + ":" + vp[1];
        Uri treeUri = treeUriForPath(path);
        if (treeUri != null) {
            try {
                return DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            } catch (Exception e) {
                Log.w(TAG, "buildDocumentUriUsingTree failed: " + e.getMessage());
            }
        }
        // Legacy tree-scoped form (no grant required on lenient providers)
        try {
            return DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse("content://" + DOCS_AUTHORITY + "/tree/" + vp[0]), docId);
        } catch (Exception e) {
            Log.w(TAG, "legacy tree-scoped URI failed: " + e.getMessage());
        }
        return applyManagedParameter(DocumentsContract.buildDocumentUri(DOCS_AUTHORITY, docId), vp[1]);
    }

    /** Builds a children-listing URI for an absolute directory path. */
    private Uri childrenUriFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String docId = vp[0] + ":" + vp[1];
        Uri treeUri = treeUriForPath(path);
        if (treeUri != null) {
            try {
                Uri dirDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
                return DocumentsContract.buildChildDocumentsUriUsingTree(dirDocUri, docId);
            } catch (Exception e) {
                Log.w(TAG, "buildChildDocumentsUriUsingTree failed: " + e.getMessage());
            }
        }
        // Legacy tree-scoped form
        try {
            Uri legacyTree = Uri.parse("content://" + DOCS_AUTHORITY + "/tree/" + vp[0]);
            return DocumentsContract.buildChildDocumentsUriUsingTree(legacyTree, docId);
        } catch (Exception e) {
            Log.w(TAG, "legacy children URI failed: " + e.getMessage());
        }
        return applyManagedParameter(
                DocumentsContract.buildChildDocumentsUri(DOCS_AUTHORITY, docId), vp[1]);
    }

    /** Opens a read stream: direct File first, then DocumentsContract. */
    private InputStream openInputFor(String path) throws Exception {
        File file = directFile(path);
        if (file.exists() && file.canRead()) {
            return new FileInputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                return activity.getContentResolver().openInputStream(uri);
            }
        }
        return null;
    }

    /** Opens a write stream (truncating): direct File first, then DocumentsContract with create-if-missing. */
    private OutputStream openOutputFor(String path) throws Exception {
        File file = directFile(path);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        if (parent != null && parent.canWrite()) {
            return new FileOutputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    OutputStream out = activity.getContentResolver().openOutputStream(uri, "wt");
                    if (out != null) return out;
                } catch (Exception e) {
                    Log.d(TAG, "openOutputFor: existing doc open failed, creating: " + e.getMessage());
                }
                // File doesn't exist yet: create it under its parent document
                String parentPath = path.substring(0, path.lastIndexOf('/'));
                String name = path.substring(path.lastIndexOf('/') + 1);
                Uri parentUri = documentUriFor(parentPath);
                if (parentUri != null) {
                    Uri created = DocumentsContract.createDocument(
                            activity.getContentResolver(), parentUri, "application/octet-stream", name);
                    if (created != null) {
                        return activity.getContentResolver().openOutputStream(created, "wt");
                    }
                }
            }
        }
        return null;
    }

    /**
     * Converts a file path to a DocumentsContract URI for accessing /Android/data/.
     * Format: content://com.android.externalstorage.documents/document/primary:Android/data/...
     */
    private Uri pathToDocumentUri(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        return documentUriFor(path);
    }
    
    /**
     * Checks if a file exists, using DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidFileExists(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = directFile(path);
        if (file.exists()) {
            return true;
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri, 
                        new String[]{android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID},
                        null, null, null
                    );
                    if (cursor != null) {
                        boolean exists = cursor.moveToFirst();
                        cursor.close();
                        return exists;
                    }
                }
                } catch (Exception e) {
                    String msg = String.valueOf(e.getMessage());
                    if (msg.contains("FileNotFoundException") || msg.contains("Missing file")
                            || msg.contains("No such file")) {
                        // Expected during marker polling — file simply doesn't exist yet
                        return false;
                    }
                    Log.w(TAG, "DocumentsContract fileExists failed: " + msg);
                }
        }
        
        return false;
    }
    
    /**
     * Checks if a directory exists, using DocumentsContract for restricted paths.
     * Verifies the document is actually a directory (MIME_TYPE_DIR), not just any document.
     */
    @UsedByGodot
    public boolean androidDirExists(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = directFile(path);
        if (file.exists() && file.isDirectory()) {
            return true;
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri, 
                        new String[]{
                            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                        },
                        null, null, null
                    );
                    if (cursor != null) {
                        boolean isDir = false;
                        if (cursor.moveToFirst()) {
                            int mimeTypeIndex = cursor.getColumnIndex(
                                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                            );
                            if (mimeTypeIndex >= 0) {
                                String mimeType = cursor.getString(mimeTypeIndex);
                                isDir = android.provider.DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                            }
                        }
                        cursor.close();
                        return isDir;
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract dirExists failed: " + e.getMessage());
            }
        }
        
        return false;
    }
    
    /**
     * Reads a file and returns its contents as a base64-encoded string.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public String androidReadFile(String path) {
        if (path == null || path.isEmpty()) {
            return "";
        }
        
        try {
            java.io.InputStream inputStream = null;
            
            // Try direct access first
            File file = directFile(path);
            if (file.exists() && file.canRead()) {
                inputStream = new java.io.FileInputStream(file);
            } else if (requiresDocumentsContract(path)) {
                // Use DocumentsContract
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    inputStream = activity.getContentResolver().openInputStream(docUri);
                }
            }
            
            if (inputStream == null) {
                return "";
            }
            
            // Read all bytes
            java.io.ByteArrayOutputStream byteStream = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int bytesRead;
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                byteStream.write(buffer, 0, bytesRead);
            }
            inputStream.close();
            
            // Encode as base64
            String base64 = android.util.Base64.encodeToString(byteStream.toByteArray(), android.util.Base64.NO_WRAP);
            return base64;
            
        } catch (Exception e) {
            Log.e(TAG, "Error reading file: " + path + " - " + e.getMessage());
            return "";
        }
    }
    
    /**
     * Writes base64-encoded data to a file.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidWriteFile(String path, String base64Data) {
        if (path == null || path.isEmpty() || base64Data == null) {
            return false;
        }
        
        try {
            byte[] data = android.util.Base64.decode(base64Data, android.util.Base64.NO_WRAP);
            
            // Try direct access first
            File file = directFile(path);
            File parentDir = file.getParentFile();
            if (parentDir != null && !parentDir.exists()) {
                parentDir.mkdirs();
            }
            
            if (parentDir != null && parentDir.canWrite()) {
                java.io.FileOutputStream outputStream = new java.io.FileOutputStream(file);
                outputStream.write(data);
                outputStream.close();
                return true;
            }
            
            // Fall back to DocumentsContract for restricted paths
            if (requiresDocumentsContract(path)) {
                java.io.OutputStream outputStream = openOutputFor(path);
                if (outputStream != null) {
                    outputStream.write(data);
                    outputStream.close();
                    return true;
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error writing file: " + path + " - " + e.getMessage());
        }
        
        return false;
    }
    
    /**
     * Lists files in a directory.
     * Returns a JSON array of filenames.
     * Uses DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public String androidListDir(String path) {
        if (path == null || path.isEmpty()) {
            return "[]";
        }
        
        java.util.List<String> files = new java.util.ArrayList<>();
        
        // Try direct access first
        File dir = directFile(path);
        if (dir.exists() && dir.isDirectory() && dir.canRead()) {
            String[] children = dir.list();
            if (children != null) {
                for (String child : children) {
                    files.add(child);
                }
            }
            return new org.json.JSONArray(files).toString();
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri childrenUri = childrenUriFor(path);
                if (childrenUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        childrenUri,
                        new String[]{
                            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                        },
                        null, null, null
                    );

                    if (cursor != null) {
                        while (cursor.moveToNext()) {
                            String name = cursor.getString(0);
                            files.add(name);
                        }
                        cursor.close();
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract listDir failed: " + e.getMessage());
            }
        }
        
        return new org.json.JSONArray(files).toString();
    }
    
    /**
     * Gets the last modified time of a file.
     * Returns 0 if file doesn't exist or can't be accessed.
     */
    @UsedByGodot
    public long androidGetModifiedTime(String path) {
        if (path == null || path.isEmpty()) {
            return 0;
        }
        
        // Try direct access first
        File file = directFile(path);
        if (file.exists()) {
            return file.lastModified();
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        docUri,
                        new String[]{android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED},
                        null, null, null
                    );
                    if (cursor != null && cursor.moveToFirst()) {
                        long modified = cursor.getLong(0);
                        cursor.close();
                        return modified;
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract getModifiedTime failed: " + e.getMessage());
            }
        }
        
        return 0;
    }
    
    /**
     * Creates a directory (and parents), using direct File first and
     * DocumentsContract segment-by-segment creation for restricted paths.
     */
    @UsedByGodot
    public boolean androidCreateDir(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }

        // Try direct access first
        File dir = directFile(path);
        if (dir.exists() && dir.isDirectory()) {
            return true;
        }
        if (dir.mkdirs()) {
            return true;
        }

        // DocumentsContract fallback: create under the covering SAF tree grant,
        // walking only segments BELOW the granted tree root (segments at or
        // above it are outside the grant's coverage and already exist).
        if (requiresDocumentsContract(path)) {
            return createDirViaSaf(path);
        }
        return false;
    }

    private boolean createDirViaSaf(String path) {
        Uri treeUri = treeUriForPath(path);
        if (treeUri == null) return false;
        String[] vp = splitVolumePath(path);
        if (vp == null) return false;
        String targetDocId = vp[0] + ":" + vp[1];
        String treeDocId;
        try {
            treeDocId = DocumentsContract.getTreeDocumentId(treeUri);
        } catch (Exception e) {
            return false;
        }
        if (!targetDocId.equals(treeDocId) && !targetDocId.startsWith(treeDocId + "/")) return false;

        String remainder = targetDocId.equals(treeDocId) ? "" : targetDocId.substring(treeDocId.length() + 1);
        String currentDocId = treeDocId;
        for (String segment : remainder.split("/")) {
            if (segment.isEmpty()) continue;
            String nextDocId = currentDocId + "/" + segment;
            if (!safDocExists(treeUri, nextDocId)) {
                try {
                    Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDocId);
                    DocumentsContract.createDocument(
                            activity.getContentResolver(), parentUri,
                            DocumentsContract.Document.MIME_TYPE_DIR, segment);
                } catch (Exception e) {
                    Log.w(TAG, "createDirViaSaf failed for " + nextDocId + ": " + e.getMessage());
                }
                if (!safDocExists(treeUri, nextDocId)) {
                    Log.w(TAG, "createDirViaSaf: could not create " + nextDocId);
                    return false;
                }
            }
            currentDocId = nextDocId;
        }
        return true;
    }

    private boolean safDocExists(Uri treeUri, String docId) {
        try {
            Uri docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            android.database.Cursor cursor = activity.getContentResolver().query(
                    docUri,
                    new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID},
                    null, null, null);
            if (cursor != null) {
                boolean exists = cursor.moveToFirst();
                cursor.close();
                return exists;
            }
        } catch (Exception ignored) {}
        return false;
    }

    /**
     * Recursively deletes a file or directory. DocumentsContract's deleteDocument
     * removes directory subtrees on ExternalStorageProvider.
     */
    @UsedByGodot
    public boolean androidDeleteRecursive(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }

        // Try direct access first
        File file = directFile(path);
        if (file.exists()) {
            return deleteRecursively(file);
        }

        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    return DocumentsContract.deleteDocument(activity.getContentResolver(), uri);
                } catch (Exception e) {
                    Log.w(TAG, "androidDeleteRecursive failed: " + e.getMessage());
                }
            }
            return false;
        }
        // Nothing existed to delete
        return true;
    }

    private boolean deleteRecursively(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        return f.delete();
    }

    /**
     * Streams a file copy, using DocumentsContract streams for whichever side is
     * restricted. Works for large files (no base64 / in-memory buffering).
     */
    @UsedByGodot
    public boolean androidCopyFile(String sourcePath, String destPath) {
        if (sourcePath == null || sourcePath.isEmpty() || destPath == null || destPath.isEmpty()) {
            return false;
        }
        try {
            InputStream in = openInputFor(sourcePath);
            if (in == null) {
                Log.w(TAG, "androidCopyFile: cannot open source: " + sourcePath);
                return false;
            }
            OutputStream out = openOutputFor(destPath);
            if (out == null) {
                in.close();
                Log.w(TAG, "androidCopyFile: cannot open dest: " + destPath);
                return false;
            }
            byte[] buffer = new byte[1024 * 1024];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            out.flush();
            out.close();
            in.close();
            return true;
        } catch (Exception e) {
            Log.e(TAG, "androidCopyFile failed: " + e.getMessage());
            return false;
        }
    }

    /**
     * Renames/moves a file or directory. Uses direct rename, then
     * DocumentsContract.renameDocument for same-parent renames, then
     * copy+delete for cross-directory moves involving restricted paths.
     */
    @UsedByGodot
    public boolean androidRename(String sourcePath, String destPath) {
        if (sourcePath == null || sourcePath.isEmpty() || destPath == null || destPath.isEmpty()) {
            return false;
        }

        File src = directFile(sourcePath);
        if (src.exists()) {
            File dst = directFile(destPath);
            File dstParent = dst.getParentFile();
            if (dstParent != null && !dstParent.exists()) {
                dstParent.mkdirs();
            }
            if (src.renameTo(dst)) {
                return true;
            }
        }

        if (requiresDocumentsContract(sourcePath) || requiresDocumentsContract(destPath)) {
            // Same-parent rename via renameDocument
            String srcParent = sourcePath.substring(0, sourcePath.lastIndexOf('/'));
            String dstParentPath = destPath.substring(0, destPath.lastIndexOf('/'));
            if (srcParent.equals(dstParentPath)) {
                Uri uri = documentUriFor(sourcePath);
                String newName = destPath.substring(destPath.lastIndexOf('/') + 1);
                if (uri != null) {
                    try {
                        Uri renamed = DocumentsContract.renameDocument(
                                activity.getContentResolver(), uri, newName);
                        if (renamed != null) return true;
                    } catch (Exception e) {
                        Log.w(TAG, "androidRename renameDocument failed: " + e.getMessage());
                    }
                }
            }
            // Cross-directory move: copy + delete
            if (androidCopyFile(sourcePath, destPath)) {
                return androidDeleteRecursive(sourcePath);
            }
            return false;
        }
        return false;
    }

    /**
     * Gets a file's size in bytes. Returns -1 if unknown/inaccessible.
     */
    @UsedByGodot
    public long androidGetFileSize(String path) {
        if (path == null || path.isEmpty()) {
            return -1;
        }
        File file = directFile(path);
        if (file.exists()) {
            return file.length();
        }
        if (requiresDocumentsContract(path)) {
            Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                            uri,
                            new String[]{DocumentsContract.Document.COLUMN_SIZE},
                            null, null, null);
                    if (cursor != null) {
                        long size = cursor.moveToFirst() ? cursor.getLong(0) : -1;
                        cursor.close();
                        return size;
                    }
                } catch (Exception e) {
                    Log.w(TAG, "androidGetFileSize failed: " + e.getMessage());
                }
            }
        }
        return -1;
    }

    /**
     * Deletes a file using DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidDeleteFile(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File file = directFile(path);
        if (file.exists() && file.isFile()) {
            return file.delete();
        }
        
        // Fall back to DocumentsContract for restricted paths
        if (requiresDocumentsContract(path)) {
            try {
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    return android.provider.DocumentsContract.deleteDocument(
                        activity.getContentResolver(), docUri
                    );
                }
            } catch (Exception e) {
                Log.w(TAG, "DocumentsContract delete failed: " + e.getMessage());
            }
        }
        
        return false;
    }
    
    /**
     * Makes a file executable (chmod +x).
     * Required for running native binaries extracted from APK assets.
     */
    @UsedByGodot
    public boolean chmodExecutable(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        try {
            File file = directFile(path);
            if (!file.exists()) {
                Log.w(TAG, "chmodExecutable: file does not exist: " + path);
                return false;
            }
            
            boolean success = file.setExecutable(true, false);
            if (success) {
                Log.d(TAG, "chmodExecutable: made executable: " + path);
            } else {
                Log.w(TAG, "chmodExecutable: failed to make executable: " + path);
            }
            return success;
        } catch (Exception e) {
            Log.e(TAG, "chmodExecutable error: " + e.getMessage());
            return false;
        }
    }
    
    /**
     * Returns the app's native library directory (nativeLibraryDir).
     * Binaries shipped as jniLibs are extracted here by the package manager
     * and — unlike files in the private data dir — may be executed under
     * SELinux policy for targetSdk 29+.
     */
    @UsedByGodot
    public String getNativeLibraryDir() {
        if (activity == null) {
            Log.w(TAG, "getNativeLibraryDir: activity is null");
            return "";
        }
        return activity.getApplicationInfo().nativeLibraryDir;
    }

    /**
     * Launches an Android intent with the specified parameters.
     * Uses FileProvider for content:// URIs when needed.
     */
    @UsedByGodot
    public boolean launchAndroidIntent(String action, String packageName, String className,
                                        String romPath, String corePath, String romDelivery,
                                        String extrasJson, String mimeType, boolean clearTask,
                                        boolean grantUriPermission, boolean useDocumentUri,
                                        boolean useFileUri) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAndroidIntent() called");
        Log.d(TAG, "Action: " + action);
        Log.d(TAG, "Package: " + packageName);
        Log.d(TAG, "Class: " + className);
        Log.d(TAG, "ROM path: " + romPath);
        Log.d(TAG, "Core path: " + corePath);
        Log.d(TAG, "ROM delivery: " + romDelivery);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent();
            
            // Set action
            if (action != null && !action.isEmpty()) {
                intent.setAction(action);
            }
            
            // Set component (package/class)
            if (packageName != null && !packageName.isEmpty()) {
                if (className != null && !className.isEmpty()) {
                    intent.setComponent(new ComponentName(packageName, className));
                } else {
                    intent.setPackage(packageName);
                }
            }
            
            // Handle ROM data based on delivery method
            if (romPath != null && !romPath.isEmpty()) {
                if ("intent_data".equals(romDelivery)) {
                    // ROM as intent data
                    Uri romUri;
                    File romFile = new File(romPath);
                    
                    if (useFileUri) {
                        // Use file:// URI (only for specific cases)
                        romUri = Uri.fromFile(romFile);
                    } else {
                        // Use FileProvider content:// URI
                        romUri = FileProvider.getUriForFile(activity, 
                            activity.getPackageName() + ".kyodai.fileprovider", romFile);
                    }
                    
                    intent.setDataAndType(romUri, mimeType);
                    
                    if (grantUriPermission) {
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    }
                } else if ("extra".equals(romDelivery)) {
                    // ROM as extra parameter
                    Uri romUri;
                    File romFile = new File(romPath);
                    
                    if (useFileUri) {
                        romUri = Uri.fromFile(romFile);
                    } else {
                        romUri = FileProvider.getUriForFile(activity,
                            activity.getPackageName() + ".kyodai.fileprovider", romFile);
                    }
                    
                    intent.putExtra("ROM", romUri.toString());
                    
                    if (grantUriPermission) {
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    }
                }
            }
            
            // Add core path as extra if provided
            if (corePath != null && !corePath.isEmpty()) {
                intent.putExtra("LIBRETRO", corePath);
            }
            
            // Parse and add extras from JSON
            if (extrasJson != null && !extrasJson.isEmpty() && !"[]".equals(extrasJson)) {
                try {
                    org.json.JSONArray extrasArray = new org.json.JSONArray(extrasJson);
                    for (int i = 0; i < extrasArray.length(); i++) {
                        org.json.JSONObject extra = extrasArray.getJSONObject(i);
                        String key = extra.getString("key");
                        String value = extra.getString("value");
                        String type = extra.getString("type");
                        
                        // Replace {rom} placeholder with actual ROM path
                        if (value != null && value.contains("{rom}")) {
                            value = value.replace("{rom}", romPath != null ? romPath : "");
                            Log.d(TAG, "Replaced {rom} placeholder in extra " + key + ": " + value);
                        }
                        
                        if ("file_path".equals(type)) {
                            // Pass raw file path - with MANAGE_EXTERNAL_STORAGE, target apps can read directly
                            intent.putExtra(key, value);
                            Log.d(TAG, "Added file path extra: " + key + "=" + value);
                        } else if ("int".equals(type)) {
                            intent.putExtra(key, Integer.parseInt(value));
                        } else if ("bool".equals(type) || "boolean".equals(type)) {
                            intent.putExtra(key, Boolean.parseBoolean(value));
                        } else if ("string_array".equals(type)) {
                            // Parse JSON array string into String[]
                            try {
                                org.json.JSONArray jsonArray = new org.json.JSONArray(value);
                                String[] stringArray = new String[jsonArray.length()];
                                for (int j = 0; j < jsonArray.length(); j++) {
                                    stringArray[j] = jsonArray.getString(j);
                                }
                                intent.putExtra(key, stringArray);
                                Log.d(TAG, "Added string array extra: " + key + "=" + value);
                            } catch (Exception e) {
                                Log.w(TAG, "Failed to parse string array extra " + key + ": " + e.getMessage());
                                intent.putExtra(key, value);
                            }
                        } else {
                            // Default to string
                            intent.putExtra(key, value);
                        }
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Failed to parse extras JSON: " + e.getMessage());
                }
            }
            
            // Add flags
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            
            if (clearTask) {
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);
            }
            
            // Launch the intent
            activity.startActivity(intent);
            
            Log.d(TAG, "SUCCESS: Intent launched");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching intent: " + e.getMessage());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    @UsedByGodot
    public boolean launchAppByPackageName(String packageName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAppByPackageName() called");
        Log.d(TAG, "Package: " + packageName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            PackageManager pm = activity.getPackageManager();
            Intent intent = pm.getLaunchIntentForPackage(packageName);
            if (intent == null) {
                Log.e(TAG, "No launch intent for package: " + packageName);
                return false;
            }
            
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
            
            Log.d(TAG, "SUCCESS: App launched");
            Log.d(TAG, "==========================================");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching app: " + e.getMessage());
            Log.e(TAG, "Stack trace: ");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            Log.d(TAG, "==========================================");
            return false;
        }
    }
    
    /**
     * Stops the foreground service when downloads are complete.
     */
    @UsedByGodot
    public void stopDownloadForegroundService() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "stopDownloadForegroundService() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, DownloadForegroundService.class);
            intent.setAction("STOP_DOWNLOAD");
            activity.startService(intent);
            
            Log.d(TAG, "Foreground service stop requested");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR stopping foreground service: " + e.getMessage());
        }
    }
    
    // ==================== FOREGROUND SERVICE FOR METADATA SYNC ====================
    
    /**
     * Starts the foreground service to prevent Android from killing the app during metadata sync.
     * Shows a persistent notification with sync progress.
     * 
     * @param platformName Name of the platform currently being synced
     * @param current Current game count
     * @param total Total game count across all platforms
     */
    @UsedByGodot
    public void startSyncForegroundService(String platformName, int current, int total) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "startSyncForegroundService() called");
        Log.d(TAG, "Platform: " + platformName + ", Progress: " + current + "/" + total);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("START_SYNC");
            intent.putExtra("platform_name", platformName);
            intent.putExtra("current", current);
            intent.putExtra("total", total);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "Sync foreground service started successfully");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR starting sync foreground service: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
        }
    }
    
    /**
     * Updates the sync foreground service notification with current progress.
     * 
     * @param platformName Name of the platform currently being synced
     * @param current Current game count
     * @param total Total game count across all platforms
     */
    @UsedByGodot
    public void updateSyncForegroundService(String platformName, int current, int total) {
        if (activity == null) {
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("UPDATE_PROGRESS");
            intent.putExtra("platform_name", platformName);
            intent.putExtra("current", current);
            intent.putExtra("total", total);
            
            activity.startService(intent);
        } catch (Exception e) {
            Log.e(TAG, "ERROR updating sync foreground service: " + e.getMessage());
        }
    }
    
    /**
     * Stops the sync foreground service when sync is complete or cancelled.
     */
    @UsedByGodot
    public void stopSyncForegroundService() {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "stopSyncForegroundService() called");
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Intent intent = new Intent(activity, SyncForegroundService.class);
            intent.setAction("STOP_SYNC");
            activity.startService(intent);
            
            Log.d(TAG, "Sync foreground service stop requested");
            Log.d(TAG, "==========================================");
        } catch (Exception e) {
            Log.e(TAG, "ERROR stopping sync foreground service: " + e.getMessage());
        }
    }
    
    /**
     * Installs an APK file using PackageInstaller with FileProvider content URI.
     * Required for Android N+ where file:// URIs are forbidden.
     */
    @UsedByGodot
    public boolean installApk(String apkPath) {
        if (apkPath == null || apkPath.isEmpty()) {
            Log.e(TAG, "installApk: Empty path");
            return false;
        }
        
        if (activity == null) {
            Log.e(TAG, "installApk: Activity is null");
            return false;
        }
        
        try {
            File apkFile = new File(apkPath);
            if (!apkFile.exists()) {
                Log.e(TAG, "installApk: File does not exist: " + apkPath);
                return false;
            }
            
            // Create content:// URI via FileProvider
            Uri apkUri = FileProvider.getUriForFile(activity,
                activity.getPackageName() + ".kyodai.fileprovider", apkFile);
            
            Log.d(TAG, "installApk: Using URI: " + apkUri);
            
            // Create install intent
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            
            // Grant permission to package installer
            activity.grantUriPermission("com.android.packageinstaller", apkUri, 
                Intent.FLAG_GRANT_READ_URI_PERMISSION);
            
            activity.startActivity(intent);
            
            Log.d(TAG, "installApk: Install intent launched successfully");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "installApk: Failed to install APK: " + e.getMessage());
            e.printStackTrace();
            return false;
        }
    }
    
    /**
     * Extracts a ZIP file using streaming to minimize memory usage.
     * Uses Java's ZipInputStream with an 8KB buffer instead of loading entire files into memory.
     * This prevents OOM kills during extraction of large game files on Android.
     * 
     * @param zipPath Absolute path to the ZIP file
     * @param extractDir Absolute path to the extraction directory
     * @return true if extraction succeeded, false otherwise
     */
    @UsedByGodot
    public boolean extractZipStreaming(String zipPath, String extractDir) {
        Log.d(TAG, "extractZipStreaming: Starting extraction of " + zipPath + " to " + extractDir);
        
        ZipInputStream zis = null;
        InputStream fis = null;
        byte[] buffer = new byte[8192]; // 8KB buffer
        int extractedCount = 0;
        long totalBytes = 0;
        
        try {
            // Create extraction directory if it doesn't exist
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
                
                // Security check: ensure the output file is within the destination directory
                String canonicalDest = destDir.getCanonicalPath();
                String canonicalOutput = outputFile.getCanonicalPath();
                if (!canonicalOutput.startsWith(canonicalDest)) {
                    Log.e(TAG, "extractZipStreaming: ZIP entry tried to escape destination: " + entryName);
                    continue;
                }
                
                if (entry.isDirectory()) {
                    outputFile.mkdirs();
                    continue;
                }
                
                // Create parent directories
                File parentDir = outputFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                
                // Extract file using streaming with 8KB buffer
                FileOutputStream fos = null;
                try {
                    fos = new FileOutputStream(outputFile);
                    int count;
                    while ((count = zis.read(buffer)) != -1) {
                        fos.write(buffer, 0, count);
                    }
                    fos.flush();
                    
                    // Relieve memory pressure:
                    // Force sync to disk every 50 files to prevent kernel buffer bloat
                    if (extractedCount % 50 == 0) {
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
                
                // Relieve memory pressure between files
                try {
                    Thread.sleep(1); // 1ms sleep to let system reclaim memory
                    if (extractedCount % 100 == 0) {
                        System.gc(); // Request garbage collection
                    }
                } catch (Exception ignored) {}
                
                // Log progress every 100 files or 100MB
                if (extractedCount % 100 == 0 || totalBytes > 104857600) {
                    Log.d(TAG, "extractZipStreaming: Progress - " + extractedCount + " files, " + 
                        (totalBytes / 1048576) + " MB extracted");
                }
            }
            
            Log.d(TAG, "extractZipStreaming: Extraction complete. " + extractedCount + " files, " + 
                (totalBytes / 1048576) + " MB total.");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "extractZipStreaming: Extraction failed: " + e.getMessage());
            e.printStackTrace();
            return false;
        } finally {
            // Clean up streams
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
    
    /**
     * Starts the ExtractorService in a separate process for memory-intensive extractions.
     * The service runs in its own process (":extractor") and sends a broadcast when done.
     * 
     * @param zipPath Absolute path to ZIP file
     * @param extractDir Absolute path to extraction directory
     * @param gameName Display name for the notification
     * @return true if service was started successfully
     */
    @UsedByGodot
    public boolean startExtractorService(String zipPath, String extractDir, String gameName) {
        Log.d(TAG, "startExtractorService: zip=" + zipPath + ", dir=" + extractDir);
        
        if (activity == null) {
            Log.e(TAG, "Activity is null, cannot start extractor service");
            return false;
        }
        
        try {
            Intent intent = new Intent(activity, ExtractorService.class);
            intent.setAction("EXTRACT");
            intent.putExtra("zip_path", zipPath);
            intent.putExtra("extract_dir", extractDir);
            intent.putExtra("game_name", gameName);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent);
            } else {
                activity.startService(intent);
            }
            
            Log.d(TAG, "ExtractorService started successfully");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to start ExtractorService: " + e.getMessage());
            e.printStackTrace();
            return false;
        }
    }
}
