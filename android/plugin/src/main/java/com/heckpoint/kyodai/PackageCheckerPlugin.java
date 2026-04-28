package com.heckpoint.kyodai;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
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

import java.io.File;
import java.util.HashSet;
import java.util.Set;

public class PackageCheckerPlugin extends GodotPlugin {
    
    private static final String TAG = "PackageChecker";
    private Activity activity;
    
    public PackageCheckerPlugin(Godot godot) {
        super(godot);
        Log.d(TAG, "PackageCheckerPlugin constructor called");
        this.activity = godot.getActivity();
        Log.d(TAG, "Activity obtained: " + (activity != null ? "YES" : "NO"));
    }
    
    @Override
    public String getPluginName() {
        return "PackageChecker";
    }
    
    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        return signals;
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
     * This filters out virtual displays and only counts physical screens.
     * 
     * @return true if 2 or more physical displays are connected
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
            
            // Get only physical displays (excludes virtual displays)
            android.view.Display[] displays = displayManager.getDisplays(android.hardware.display.DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
            int physicalDisplayCount = displays.length;
            
            // If no presentation displays, check all displays and filter
            if (physicalDisplayCount == 0) {
                displays = displayManager.getDisplays();
                physicalDisplayCount = 0;
                for (android.view.Display display : displays) {
                    // Skip the default display (usually display 0)
                    if (display.getDisplayId() != android.view.Display.DEFAULT_DISPLAY && display.isValid()) {
                        physicalDisplayCount++;
                    }
                }
            }
            
            Log.d(TAG, "Physical display count: " + physicalDisplayCount);
            Log.d(TAG, "==========================================");
            
            return physicalDisplayCount >= 1; // 1 presentation display + default = 2 total
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking for multiple displays: " + e.getMessage());
            return false;
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
    
    /**
     * Converts a file path to a DocumentsContract URI for accessing /Android/data/.
     * Format: content://com.android.externalstorage.documents/document/primary:Android/data/...
     */
    private Uri pathToDocumentUri(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        
        try {
            // Handle primary storage
            if (path.startsWith("/storage/emulated/0/")) {
                String relativePath = path.substring("/storage/emulated/0/".length());
                String docId = "primary:" + relativePath;
                return android.provider.DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse("content://com.android.externalstorage.documents/tree/primary"),
                    docId
                );
            }
            
            // Handle SD cards: /storage/XXXX-XXXX/...
            if (path.startsWith("/storage/")) {
                String[] parts = path.split("/");
                if (parts.length >= 3) {
                    String storageId = parts[2];
                    String relativePath = path.substring(("/storage/" + storageId + "/").length());
                    String docId = storageId + ":" + relativePath;
                    return android.provider.DocumentsContract.buildDocumentUriUsingTree(
                        Uri.parse("content://com.android.externalstorage.documents/tree/" + storageId),
                        docId
                    );
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error converting path to document URI: " + e.getMessage());
        }
        
        return null;
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
        File file = new File(path);
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
                Log.w(TAG, "DocumentsContract fileExists failed: " + e.getMessage());
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
        File file = new File(path);
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
            File file = new File(path);
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
            File file = new File(path);
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
                Uri docUri = pathToDocumentUri(path);
                if (docUri != null) {
                    java.io.OutputStream outputStream = activity.getContentResolver().openOutputStream(docUri, "w");
                    if (outputStream != null) {
                        outputStream.write(data);
                        outputStream.close();
                        return true;
                    }
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
        File dir = new File(path);
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
                Uri dirUri = pathToDocumentUri(path);
                if (dirUri != null) {
                    android.database.Cursor cursor = activity.getContentResolver().query(
                        android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(dirUri, 
                            android.provider.DocumentsContract.getDocumentId(dirUri)),
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
        File file = new File(path);
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
     * Creates a directory (and parents) using DocumentsContract for restricted paths.
     */
    @UsedByGodot
    public boolean androidCreateDir(String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        
        // Try direct access first
        File dir = new File(path);
        if (dir.exists() && dir.isDirectory()) {
            return true;
        }
        if (dir.mkdirs()) {
            return true;
        }
        
        // For restricted paths, DocumentsContract doesn't support directory creation well
        // Return false - caller should handle this differently
        return false;
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
        File file = new File(path);
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
}