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
import java.net.URLDecoder;
import java.util.ArrayList;
import java.util.List;

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
     * Creates a directory hierarchy under a SAF DocumentFile tree root.
     * Returns the final directory DocumentFile, or null on failure.
     */
    private DocumentFile createSafDirectoryFromPath(DocumentFile root, String relativePath) {
        if (relativePath == null || relativePath.isEmpty()) {
            return root;
        }

        DocumentFile current = root;
        String[] parts = relativePath.split("/");
        for (String part : parts) {
            if (part.isEmpty()) continue;
            DocumentFile next = current.findFile(part);
            if (next == null || !next.isDirectory()) {
                if (next != null) {
                    next.delete();
                }
                next = current.createDirectory(part);
            }
            if (next == null) {
                Log.e(TAG, "ERROR: Failed to create SAF directory: " + part + " under " + current.getUri());
                return null;
            }
            current = next;
        }
        return current;
    }    /**
     * Reads a specific byte range from a file in SAF storage.
     * Much more efficient than copying the entire file for small reads.
     * Returns the byte array, or null if the file cannot be read.
     */
    @UsedByGodot
    public byte[] readSafFileRange(String safUri, long offset, int length) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "readSafFileRange() called");
        Log.d(TAG, "SAF URI: " + safUri);
        Log.d(TAG, "Offset: " + offset + ", Length: " + length);

        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return null;
        }

        try {
            DocumentFile sourceFile = navigateToSafFile(safUri);
            if (sourceFile == null) {
                Log.e(TAG, "ERROR: Could not find SAF file");
                return null;
            }

            Uri fileUri = sourceFile.getUri();
            Log.d(TAG, "File URI: " + fileUri.toString());
            java.io.InputStream inputStream = activity.getContentResolver().openInputStream(fileUri);

            if (inputStream == null) {
                Log.e(TAG, "ERROR: Could not open SAF input stream");
                return null;
            }

            // Skip to the desired offset
            long skipped = inputStream.skip(offset);
            if (skipped != offset) {
                Log.e(TAG, "ERROR: Could not skip to offset " + offset + ", only skipped " + skipped);
                inputStream.close();
                return null;
            }

            // Read exactly the requested number of bytes
            byte[] buffer = new byte[length];
            int totalRead = 0;
            while (totalRead < length) {
                int read = inputStream.read(buffer, totalRead, length - totalRead);
                if (read == -1) {
                    Log.e(TAG, "ERROR: EOF reached before reading " + length + " bytes");
                    inputStream.close();
                    return null;
                }
                totalRead += read;
            }

            inputStream.close();

            Log.d(TAG, "SUCCESS: Read " + totalRead + " bytes from offset " + offset);
            Log.d(TAG, "==========================================");
            return buffer;

        } catch (Exception e) {
            Log.e(TAG, "ERROR reading SAF file range: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return null;
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
     * Deletes a directory in SAF storage given a full SAF path.
     * The directory must be empty.
     * Returns true if successful, false otherwise.
     */
    @UsedByGodot
    public boolean deleteSafDirectory(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "deleteSafDirectory() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Parse the path to extract tree base and directory path
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format");
                return false;
            }
            
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                // Just the tree root, cannot delete
                Log.e(TAG, "ERROR: Cannot delete tree root");
                return false;
            }
            
            // Extract tree base URI
            String treeBase = fullPath.substring(0, nextSlash);
            String relativePath = fullPath.substring(nextSlash + 1);
            
            Log.d(TAG, "Tree base: " + treeBase);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate to the parent directory first
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            String[] pathParts = relativePath.split("/");
            String dirName = pathParts[pathParts.length - 1];
            
            // Navigate to parent directory
            for (int i = 0; i < pathParts.length - 1; i++) {
                String part = pathParts[i];
                if (part.isEmpty() || part.equals(".") || part.equals("..")) {
                    continue;
                }
                
                DocumentFile nextDir = currentDir.findFile(part);
                if (nextDir == null || !nextDir.isDirectory()) {
                    Log.e(TAG, "ERROR: Directory not found in path: " + part);
                    return false;
                }
                currentDir = nextDir;
            }
            
            // Find the directory to delete
            DocumentFile targetDir = currentDir.findFile(dirName);
            if (targetDir == null) {
                Log.d(TAG, "Directory not found (may already be deleted): " + dirName);
                return true;
            }
            
            if (!targetDir.isDirectory()) {
                Log.e(TAG, "ERROR: Target is not a directory: " + dirName);
                return false;
            }
            
            // Check if directory is empty
            DocumentFile[] children = targetDir.listFiles();
            if (children.length > 0) {
                Log.e(TAG, "ERROR: Directory is not empty, cannot delete: " + dirName);
                return false;
            }
            
            // Delete the directory
            boolean deleted = targetDir.delete();
            if (deleted) {
                Log.d(TAG, "SUCCESS: Deleted directory: " + dirName);
            } else {
                Log.e(TAG, "ERROR: Failed to delete directory: " + dirName);
            }
            
            Log.d(TAG, "==========================================");
            return deleted;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR deleting SAF directory: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
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
}