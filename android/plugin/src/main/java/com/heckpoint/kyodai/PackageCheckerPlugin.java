package com.heckpoint.kyodai;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.UriPermission;
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
import android.provider.DocumentsContract;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import androidx.core.content.FileProvider;
import androidx.documentfile.provider.DocumentFile;
import org.godotengine.godot.Godot;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.File;
import java.util.HashSet;
import java.util.Set;
import java.io.FileInputStream;
import java.io.OutputStream;
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
        signals.add(new SignalInfo("saf_copy_progress", String.class, Integer.class));
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
    
    @UsedByGodot
    public boolean checkSafPermission(String treeUriString) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "checkSafPermission() called");
        Log.d(TAG, "Tree URI: " + treeUriString);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Uri treeUri = Uri.parse(treeUriString);
            
            // Check if we have persisted permission for this URI
            boolean hasPermission = false;
            java.util.List<UriPermission> persistedPerms = activity.getContentResolver().getPersistedUriPermissions();
            for (UriPermission perm : persistedPerms) {
                if (perm.getUri().equals(treeUri)) {
                    hasPermission = true;
                    Log.d(TAG, "Found persisted permission for URI");
                    break;
                }
            }
            
            if (!hasPermission) {
                Log.e(TAG, "ERROR: No persisted permission found for URI");
                return false;
            }
            
            // Run DocumentFile check on main thread
            Log.d(TAG, "Running DocumentFile check on main thread...");
            final boolean[] canAccess = {false};
            final java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(1);
            
            new android.os.Handler(android.os.Looper.getMainLooper()).post(new Runnable() {
                @Override
                public void run() {
                    try {
                        Log.d(TAG, "DocumentFile check running on main thread");
                        DocumentFile pickedDir = DocumentFile.fromTreeUri(activity, treeUri);
                        if (pickedDir == null) {
                            Log.e(TAG, "ERROR: DocumentFile.fromTreeUri returned null");
                            canAccess[0] = false;
                        } else if (!pickedDir.exists()) {
                            Log.e(TAG, "ERROR: Tree directory does not exist");
                            canAccess[0] = false;
                        } else if (!pickedDir.canWrite()) {
                            Log.e(TAG, "ERROR: No write permission for directory");
                            canAccess[0] = false;
                        } else {
                            Log.d(TAG, "DocumentFile access verified on main thread");
                            canAccess[0] = true;
                        }
                    } catch (Exception e) {
                        Log.e(TAG, "ERROR in DocumentFile check: " + e.getMessage());
                        canAccess[0] = false;
                    }
                    latch.countDown();
                }
            });
            
            // Wait for main thread check (with timeout)
            try {
                boolean completed = latch.await(5, java.util.concurrent.TimeUnit.SECONDS);
                if (!completed) {
                    Log.e(TAG, "ERROR: DocumentFile check timed out");
                    return false;
                }
            } catch (InterruptedException e) {
                Log.e(TAG, "ERROR: Interrupted while waiting for DocumentFile check");
                return false;
            }
            
            if (!canAccess[0]) {
                return false;
            }
            
            Log.d(TAG, "SUCCESS: All permissions verified");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking SAF permission: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    @UsedByGodot
    public void persistSafPermission(String treeUriString) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "persistSafPermission() called");
        Log.d(TAG, "Tree URI: " + treeUriString);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return;
        }
        
        try {
            Uri treeUri = Uri.parse(treeUriString);
            
            // Take persistable permission immediately when user selects directory
            int takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
            activity.getContentResolver().takePersistableUriPermission(treeUri, takeFlags);
            
            Log.d(TAG, "SUCCESS: SAF permission persisted for: " + treeUriString);
            Log.d(TAG, "==========================================");
        } catch (SecurityException e) {
            Log.e(TAG, "ERROR: Could not persist permission: " + e.getMessage());
        } catch (Exception e) {
            Log.e(TAG, "ERROR persisting SAF permission: " + e.getMessage());
        }
    }
    
    @UsedByGodot
    public boolean safFileExists(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "safFileExists() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Parse the path to extract tree base and file path
            // Format: content://authority/tree/treeId/subdir1/subdir2/filename
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format");
                return false;
            }
            
            // Find end of tree ID (first / after /tree/)
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                // No subdirectories or file, just the tree root
                Log.d(TAG, "Path is tree root, checking if tree is accessible");
                Uri treeUri = Uri.parse(fullPath);
                DocumentFile treeDir = DocumentFile.fromTreeUri(activity, treeUri);
                boolean exists = treeDir != null && treeDir.exists();
                Log.d(TAG, "Tree root exists: " + exists);
                return exists;
            }
            
            // Extract tree base URI (up to and including tree ID)
            String treeBase = fullPath.substring(0, nextSlash);
            Log.d(TAG, "Tree base: " + treeBase);
            
            // Extract relative path from tree
            String relativePath = fullPath.substring(nextSlash + 1);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate through DocumentFile
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            // Split relative path into components
            String[] pathParts = relativePath.split("/");
            
            // Navigate through directories
            for (int i = 0; i < pathParts.length - 1; i++) {
                String dirName = pathParts[i];
                if (dirName.isEmpty()) continue;
                
                Log.d(TAG, "Looking for directory: " + dirName);
                DocumentFile subDir = currentDir.findFile(dirName);
                if (subDir == null || !subDir.isDirectory()) {
                    Log.d(TAG, "Directory not found: " + dirName);
                    return false;
                }
                currentDir = subDir;
            }
            
            // Check final file
            String fileName = pathParts[pathParts.length - 1];
            Log.d(TAG, "Looking for file: " + fileName);
            DocumentFile file = currentDir.findFile(fileName);
            boolean exists = file != null && file.exists();
            Log.d(TAG, "File exists: " + exists);
            Log.d(TAG, "==========================================");
            return exists;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking file existence: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * UNIFIED INTENT LAUNCHER - Simplified Schema
     * 
     * Supports streamlined configuration with sensible defaults:
     * - grantUriPermission defaults to TRUE (SAF-compatible)
     * - clearTask defaults to TRUE (prevents back-stack issues)
     * - mimeType defaults to "application/octet-stream"
     * 
     * rom_delivery values:
     * - "intent_data": ROM passed via intent.setDataAndType() as content:// URI
     * - "extra": ROM passed via extras array (define key/type in extras)
     * - "none": No ROM delivery (just launch the app)
     * 
     * @param action Intent action (e.g., "android.intent.action.VIEW")
     * @param packageName Target app package name
     * @param className Target activity class name (can be null for package-only launch)
     * @param romPath Absolute file path to the ROM
     * @param corePath Core path for RetroArch
     * @param romDelivery How to deliver the ROM: "intent_data", "extra", or "none"
     * @param extrasJson JSON array string of extras
     * @param mimeType MIME type for intent data (default: "application/octet-stream")
     * @param clearTask Whether to use FLAG_ACTIVITY_CLEAR_TASK (default: true)
     * @param grantUriPermission Whether to grant URI permissions (default: true)
     * @param useDocumentUri Whether to convert tree URIs to document URIs
     * @param useFileUri Whether to pass file:// URI instead of content:// URI (for apps with MANAGE_EXTERNAL_STORAGE)
     */
    @UsedByGodot
    public boolean launchAndroidIntent(String action, String packageName, String className, String romPath,
                                        String corePath, String romDelivery, String extrasJson, String mimeType,
                                        boolean clearTask, boolean grantUriPermission, boolean useDocumentUri, boolean useFileUri) {
        // Apply sensible defaults
        if (mimeType == null || mimeType.isEmpty()) {
            mimeType = "application/octet-stream";
        }
        // Note: clearTask and grantUriPermission are primitive booleans, 
        // so they'll use whatever value is passed. The caller (launch_manager.gd) 
        // should apply the defaults.
        
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAndroidIntent() [UNIFIED] called");
        Log.d(TAG, "Action: " + action);
        Log.d(TAG, "Package: " + packageName);
        Log.d(TAG, "Class: " + className);
        Log.d(TAG, "ROM Path: " + romPath);
        Log.d(TAG, "Core Path: " + corePath);
        Log.d(TAG, "ROM Delivery: " + romDelivery);
        Log.d(TAG, "Extras JSON: " + extrasJson);
        Log.d(TAG, "MIME Type: " + mimeType);
        Log.d(TAG, "Clear Task: " + clearTask);
        Log.d(TAG, "Grant URI Permission: " + grantUriPermission);
        Log.d(TAG, "Use Document URI: " + useDocumentUri);
        Log.d(TAG, "Use File URI: " + useFileUri);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent();
            
            // Set component if className provided, otherwise just set package
            // Package name is optional - if not provided, the system will find an appropriate handler
            if (packageName != null && !packageName.isEmpty()) {
                if (className != null && !className.isEmpty()) {
                    intent.setClassName(packageName, className);
                    Log.d(TAG, "Set component: " + packageName + "/" + className);
                } else {
                    intent.setPackage(packageName);
                    Log.d(TAG, "Set package: " + packageName);
                }
            } else {
                Log.d(TAG, "No package name provided, using implicit intent");
            }
            
            // Set action if provided
            if (action != null && !action.isEmpty()) {
                intent.setAction(action);
                Log.d(TAG, "Set action: " + action);
            }
            
            // Add default category
            intent.addCategory(Intent.CATEGORY_DEFAULT);
            
            // Pre-generate all URI types for extras processing
            // Uses Godot's FileProvider (authority: <package_name>.fileprovider)
            Uri romContentUri = null;  // FileProvider content:// URI
            String romFilePath = null; // Raw file path
            String romFileUri = null;  // file:// URI
            String romSafUri = null;   // Original SAF content:// URI
            
            if (romPath != null && !romPath.isEmpty()) {
                String filePath = romPath;
                
                // Check if romPath is already a content URI (SAF)
                if (romPath.startsWith("content://")) {
                    romSafUri = romPath;
                    String convertedPath = getFilePathFromContentUri(activity, romPath);
                    if (convertedPath != null && !convertedPath.isEmpty()) {
                        filePath = convertedPath;
                        Log.d(TAG, "Converted SAF URI to file path: " + filePath);
                    } else {
                        Log.w(TAG, "Could not convert SAF URI to file path: " + romPath);
                    }
                }
                
                romFilePath = filePath;
                
                // Create File object and generate URIs
                File romFile = new File(filePath);
                if (romFile.exists()) {
                    // Generate file:// URI
                    romFileUri = Uri.fromFile(romFile).toString();
                    Log.d(TAG, "Generated file:// URI: " + romFileUri);
                    
                    // Generate FileProvider content:// URI
                    try {
                        // Use Godot's FileProvider authority
                        // Note: For SD card support, you must override Godot's file_paths.xml in your app's AndroidManifest.xml
                        String authority = activity.getPackageName() + ".fileprovider";
                        romContentUri = FileProvider.getUriForFile(activity, authority, romFile);
                        Log.d(TAG, "Generated FileProvider URI: " + romContentUri);
                    } catch (IllegalArgumentException e) {
                        Log.w(TAG, "Could not generate FileProvider URI: " + e.getMessage());
                        Log.w(TAG, "FileProvider failed for path: " + filePath);
                        Log.w(TAG, "For SD card support, add custom file_paths.xml to your AndroidManifest.xml");
                    }
                } else {
                    Log.w(TAG, "ROM file does not exist: " + filePath);
                }
            }
            
            // Deliver ROM based on romDelivery mode
            if (romDelivery != null && !romDelivery.isEmpty()) {
                switch (romDelivery) {
                    case "intent_data":
                        Uri dataUri = null;
                        
                        // Priority: FileProvider URI > Converted Document URI > Original SAF URI
                        if (romContentUri != null) {
                            dataUri = romContentUri;
                            Log.d(TAG, "Using FileProvider URI for intent data: " + dataUri);
                        } else if (romSafUri != null && !romSafUri.isEmpty()) {
                            String uriString = romSafUri;
                            
                            // Convert tree URI to document URI when requested (for Azahar/Eden)
                            if (uriString.contains("/tree/") && useDocumentUri && !useFileUri) {
                                String docUriString = convertTreeUriToDocumentUri(uriString);
                                if (!docUriString.equals(uriString)) {
                                    dataUri = Uri.parse(docUriString);
                                    Log.d(TAG, "Converted tree URI to document URI (useDocumentUri=true): " + dataUri);
                                } else {
                                    dataUri = Uri.parse(romSafUri);
                                    Log.d(TAG, "Using original SAF tree URI (could not convert): " + dataUri);
                                }
                            } else if (useFileUri) {
                                // Convert to file:// URI for apps with MANAGE_EXTERNAL_STORAGE permission
                                String realPath = getFilePathFromContentUri(activity, romSafUri);
                                if (realPath != null && !realPath.isEmpty() && !realPath.startsWith("content://")) {
                                    File romFile = new File(realPath);
                                    if (romFile.exists()) {
                                        dataUri = Uri.fromFile(romFile);
                                        Log.d(TAG, "Created file:// URI (useFileUri=true): " + dataUri);
                                    } else {
                                        Log.w(TAG, "File does not exist at path: " + realPath);
                                        dataUri = Uri.parse(romSafUri);
                                        Log.d(TAG, "Falling back to original SAF URI: " + dataUri);
                                    }
                                } else {
                                    Log.w(TAG, "Could not convert SAF URI to file path for file:// URI");
                                    dataUri = Uri.parse(romSafUri);
                                    Log.d(TAG, "Falling back to original SAF URI: " + dataUri);
                                }
                            } else {
                                // Try to create FileProvider URI from file path
                                String realPath = getFilePathFromContentUri(activity, romSafUri);
                                if (realPath != null && !realPath.isEmpty() && !realPath.startsWith("content://")) {
                                    File romFile = new File(realPath);
                                    if (romFile.exists()) {
                                        try {
                                            dataUri = FileProvider.getUriForFile(activity, "com.heckpoint.kyodai.fileprovider", romFile);
                                            Log.d(TAG, "Created FileProvider URI from SAF path: " + dataUri);
                                        } catch (Exception e) {
                                            Log.w(TAG, "Could not create FileProvider URI from path: " + realPath + ", error: " + e.getMessage());
                                            // Use original SAF URI instead of file:// (Android 7.0+ forbids file://)
                                            dataUri = Uri.parse(romSafUri);
                                            Log.d(TAG, "Using original SAF URI instead of file://: " + dataUri);
                                        }
                                    } else {
                                        Log.w(TAG, "File does not exist at path: " + realPath);
                                        dataUri = Uri.parse(romSafUri);
                                        Log.d(TAG, "Falling back to original SAF URI: " + dataUri);
                                    }
                                } else {
                                    // Could not convert to path, use original SAF URI
                                    dataUri = Uri.parse(romSafUri);
                                    Log.d(TAG, "Using original SAF URI (could not convert to path): " + dataUri);
                                }
                            }
                        }
                        
                        if (dataUri != null) {
                            String type = (mimeType != null && !mimeType.isEmpty()) ? mimeType : "application/octet-stream";
                            
                            // Grant permissions only when explicitly requested
                            if (grantUriPermission) {
                                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                
                                // Only grant explicit permission for FileProvider URIs (our own provider)
                                // SAF URIs cannot be explicitly granted - we must rely on FLAG_GRANT_READ_URI_PERMISSION
                                String uriStr = dataUri.toString();
                                boolean isSafUri = uriStr.contains("com.android.externalstorage.documents") ||
                                                   uriStr.contains("com.android.providers.downloads") ||
                                                   uriStr.contains("com.android.providers.media");
                                
                                if (!isSafUri && uriStr.startsWith("content://") && packageName != null && !packageName.isEmpty()) {
                                    try {
                                        activity.grantUriPermission(packageName, dataUri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                        Log.d(TAG, "Granted explicit URI permission to package: " + packageName);
                                    } catch (Exception e) {
                                        Log.w(TAG, "Could not grant explicit URI permission: " + e.getMessage());
                                    }
                                } else if (isSafUri) {
                                    Log.d(TAG, "SAF URI detected - skipping explicit grant, using FLAG_GRANT_READ_URI_PERMISSION only");
                                }
                                
                                // Use ClipData for permission grants (works for both SAF and FileProvider URIs)
                                if (uriStr.startsWith("content://")) {
                                    intent.setClipData(ClipData.newRawUri(null, dataUri));
                                    Log.d(TAG, "Granted URI read permission via ClipData and flags");
                                }
                            } else {
                                Log.d(TAG, "Skipping permission grants (grantUriPermission=false)");
                            }
                            
                            intent.setDataAndType(dataUri, type);
                            Log.d(TAG, "Set intent data (content URI): " + dataUri);
                        }
                        break;
                        
                    case "extra":
                        // ROM delivered via extras array - handled below in extras processing
                        Log.d(TAG, "ROM will be delivered via extras array");
                        break;
                        
                    case "none":
                        Log.d(TAG, "No ROM delivery requested");
                        break;
                        
                    default:
                        Log.w(TAG, "Unknown romDelivery mode: " + romDelivery + ", defaulting to intent_data");
                        if (romContentUri != null) {
                            intent.setDataAndType(romContentUri, "application/octet-stream");
                        }
                        break;
                }
            }
            
            // Process extras from JSON
            if (extrasJson != null && !extrasJson.isEmpty()) {
                try {
                    org.json.JSONArray extrasArray = new org.json.JSONArray(extrasJson);
                    Log.d(TAG, "Processing " + extrasArray.length() + " extras");
                    
                    for (int i = 0; i < extrasArray.length(); i++) {
                        org.json.JSONObject extraObj = extrasArray.getJSONObject(i);
                        String key = extraObj.getString("key");
                        String value = extraObj.optString("value", "");
                        String type = extraObj.optString("type", "string");
                        
                        // Replace {rom} placeholder based on type
                        if (value.contains("{rom}")) {
                            switch (type) {
                                case "file_path":
                                    // Raw filesystem path: /storage/emulated/0/roms/game.3ds
                                    value = value.replace("{rom}", romFilePath != null ? romFilePath : "");
                                    break;
                                    
                                case "content_uri":
                                    // FileProvider content:// URI: content://org.godotengine.../external_storage/roms/game.3ds
                                    value = value.replace("{rom}", romContentUri != null ? romContentUri.toString() : "");
                                    break;
                                    
                                case "file_uri":
                                    // Legacy file:// URI: file:///storage/emulated/0/roms/game.3ds
                                    value = value.replace("{rom}", romFileUri != null ? romFileUri : "");
                                    break;
                                    
                                case "saf_uri":
                                    // Original SAF content:// URI: content://com.android.externalstorage.documents/tree/primary:roms/game.3ds
                                    value = value.replace("{rom}", romSafUri != null ? romSafUri : "");
                                    break;
                                    
                                case "document_uri":
                                    // Converted to SAF document URI format
                                    String docUri = convertFilePathToDocumentUri(romFilePath);
                                    value = value.replace("{rom}", docUri != null ? docUri : "");
                                    break;
                                    
                                default:
                                    // Default to file path for unknown types
                                    value = value.replace("{rom}", romFilePath != null ? romFilePath : "");
                                    break;
                            }
                        }
                        
                        // Replace {core_path} placeholder
                        if (value.contains("{core_path}")) {
                            value = value.replace("{core_path}", corePath != null ? corePath : "");
                            Log.d(TAG, "Replaced {core_path} with: " + corePath);
                        }
                        
                        // Add extra based on type
                        switch (type) {
                            case "string":
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added string extra: " + key + "=" + value);
                                break;
                                
                            case "file_path":
                                // Convert SAF URI to real file path if needed
                                String filePathValue = value;
                                if (value != null && value.startsWith("content://")) {
                                    String realPath = getFilePathFromContentUri(activity, value);
                                    if (realPath != null && !realPath.isEmpty()) {
                                        filePathValue = realPath;
                                        Log.d(TAG, "Converted SAF URI to file path for extra: " + key + "=" + filePathValue);
                                    }
                                }
                                intent.putExtra(key, filePathValue);
                                Log.d(TAG, "Added file path extra: " + key + "=" + filePathValue);
                                break;
                                
                            case "content_uri":
                                // Parse as actual Uri object (not string) for proper permission handling
                                Uri contentUri = Uri.parse(value);
                                intent.putExtra(key, contentUri);
                                Log.d(TAG, "Added content URI extra: " + key + "=" + contentUri);
                                // Also add to ClipData for permission grants
                                if (grantUriPermission) {
                                    ClipData clipData = intent.getClipData();
                                    if (clipData == null) {
                                        clipData = ClipData.newRawUri(null, contentUri);
                                    } else {
                                        clipData.addItem(new ClipData.Item(contentUri));
                                    }
                                    intent.setClipData(clipData);
                                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                    Log.d(TAG, "Added content URI to ClipData for permission grant with FLAG_GRANT_READ_URI_PERMISSION");
                                }
                                break;
                                
                            case "file_uri":
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added file URI extra: " + key + "=" + value);
                                break;
                                
                            case "saf_uri":
                                // Parse as actual Uri object (not string) for proper permission handling
                                Uri safUri = Uri.parse(value);
                                intent.putExtra(key, safUri);
                                Log.d(TAG, "Added SAF URI extra: " + key + "=" + safUri);
                                // Also add to ClipData for permission grants
                                if (grantUriPermission) {
                                    ClipData clipData = intent.getClipData();
                                    if (clipData == null) {
                                        clipData = ClipData.newRawUri(null, safUri);
                                    } else {
                                        clipData.addItem(new ClipData.Item(safUri));
                                    }
                                    intent.setClipData(clipData);
                                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                    Log.d(TAG, "Added SAF URI to ClipData for permission grant with FLAG_GRANT_READ_URI_PERMISSION");
                                }
                                break;
                                
                            case "document_uri":
                                // Parse as actual Uri object (not string) for proper permission handling
                                Uri documentUri = Uri.parse(value);
                                intent.putExtra(key, documentUri);
                                Log.d(TAG, "Added document URI extra: " + key + "=" + documentUri);
                                // Also add to ClipData for permission grants
                                if (grantUriPermission) {
                                    ClipData clipData = intent.getClipData();
                                    if (clipData == null) {
                                        clipData = ClipData.newRawUri(null, documentUri);
                                    } else {
                                        clipData.addItem(new ClipData.Item(documentUri));
                                    }
                                    intent.setClipData(clipData);
                                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                    Log.d(TAG, "Added document URI to ClipData for permission grant with FLAG_GRANT_READ_URI_PERMISSION");
                                }
                                break;
                                
                            case "boolean":
                                boolean boolValue = Boolean.parseBoolean(value);
                                intent.putExtra(key, boolValue);
                                Log.d(TAG, "Added boolean extra: " + key + "=" + boolValue);
                                break;
                                
                            case "int":
                                try {
                                    int intValue = Integer.parseInt(value);
                                    intent.putExtra(key, intValue);
                                    Log.d(TAG, "Added int extra: " + key + "=" + intValue);
                                } catch (NumberFormatException e) {
                                    Log.w(TAG, "Could not parse int value for " + key + ": " + value);
                                    intent.putExtra(key, value);
                                }
                                break;
                                
                            case "string_array":
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
                                    Log.w(TAG, "Could not parse string array for " + key + ": " + value);
                                    intent.putExtra(key, value);
                                }
                                break;
                                
                            default:
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added extra (default string): " + key + "=" + value);
                                break;
                        }
                    }
                } catch (Exception e) {
                    Log.e(TAG, "ERROR parsing extras JSON: " + e.getMessage());
                }
            } else {
                Log.d(TAG, "No extras provided");
            }
            
            // Add intent flags
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (clearTask) {
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);
                Log.d(TAG, "Added FLAG_ACTIVITY_CLEAR_TASK");
            }
            if (grantUriPermission) {
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                Log.d(TAG, "Added FLAG_GRANT_READ_URI_PERMISSION");
            }
            
            // DEBUG: Log final intent details
            Log.d(TAG, "Final Intent:");
            Log.d(TAG, "  Action: " + intent.getAction());
            Log.d(TAG, "  Package: " + intent.getPackage());
            Log.d(TAG, "  Component: " + intent.getComponent());
            Log.d(TAG, "  Data: " + intent.getData());
            Log.d(TAG, "  Type: " + intent.getType());
            if (intent.getExtras() != null) {
                Log.d(TAG, "  Extras count: " + intent.getExtras().size());
                for (String key : intent.getExtras().keySet()) {
                    Log.d(TAG, "    " + key + " = " + intent.getExtras().get(key));
                }
            }
            
            // Verify ROM file exists before launching
            String checkPath = romFilePath != null ? romFilePath : romPath;
            if (checkPath != null && !checkPath.isEmpty() && !checkPath.startsWith("content://")) {
                File romFile = new File(checkPath);
                Log.d(TAG, "ROM file status - exists: " + romFile.exists() + 
                          ", readable: " + romFile.canRead() + 
                          ", size: " + romFile.length() + " bytes");
            }
            
            Log.d(TAG, "Starting activity...");
            activity.startActivity(intent);
            
            Log.d(TAG, "SUCCESS: Intent launched successfully");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching Android intent: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    /**
     * Converts a file path to a document URI (SAF format).
     * This is needed for some emulators that expect document URIs in extras.
     */
    private String convertFilePathToDocumentUri(String filePath) {
        if (filePath == null || filePath.isEmpty()) {
            return null;
        }
        
        try {
            // Try to build a document URI from the file path
            // Format: content://com.android.externalstorage.documents/document/primary:path/to/file
            
            // Check if it's already a content URI
            if (filePath.startsWith("content://")) {
                return filePath;
            }
            
            // Parse the file path to determine storage volume
            if (filePath.startsWith("/storage/emulated/0/")) {
                String relativePath = filePath.substring("/storage/emulated/0/".length());
                return "content://com.android.externalstorage.documents/document/primary:" + 
                       relativePath.replace("/", "%2F");
            } else if (filePath.startsWith("/storage/")) {
                // Extract storage ID (e.g., "ABCD-1234" from "/storage/ABCD-1234/path/to/file")
                String[] parts = filePath.split("/");
                if (parts.length >= 3) {
                    String storageId = parts[2];
                    String relativePath = filePath.substring(("/storage/" + storageId + "/").length());
                    return "content://com.android.externalstorage.documents/document/" + storageId + ":" + 
                           relativePath.replace("/", "%2F");
                }
            } else if (filePath.startsWith("/data/data/")) {
                // Internal app data - return as-is since it can't be shared via SAF
                return filePath;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error converting file path to document URI: " + e.getMessage());
        }
        
        // Fallback: return original path
        return filePath;
    }
    
    /**
     * Converts a content URI to a file path.
     * This works for external storage documents and other common providers.
     */
    private String getFilePathFromContentUri(Activity activity, String contentUri) {
        try {
            // Handle external storage tree URIs (content://com.android.externalstorage.documents/tree/...)
            if (contentUri.contains("com.android.externalstorage.documents") && contentUri.contains("/tree/")) {
                // Parse tree URI format: content://.../tree/primary:path/to/file
                int treePos = contentUri.lastIndexOf("/tree/");
                if (treePos != -1) {
                    String treePath = contentUri.substring(treePos + 6); // Skip "/tree/"
                    // URL decode the path
                    treePath = java.net.URLDecoder.decode(treePath, "UTF-8");
                    
                    // Parse format: "primary:path/to/file" or "XXXX-XXXX:path/to/file"
                    int colonPos = treePath.indexOf(':');
                    if (colonPos != -1) {
                        String storage = treePath.substring(0, colonPos);
                        String path = treePath.substring(colonPos + 1);
                        
                        if ("primary".equalsIgnoreCase(storage)) {
                            return "/storage/emulated/0/" + path;
                        } else {
                            // For other storage volumes (SD cards, etc.)
                            return "/storage/" + storage + "/" + path;
                        }
                    }
                }
            }
            
            // Handle external storage document URIs (content://com.android.externalstorage.documents/document/...)
            if (contentUri.contains("com.android.externalstorage.documents") && contentUri.contains("/document/")) {
                // Parse the document ID from the URI
                // Format: content://.../document/primary:path/to/file
                int docPos = contentUri.lastIndexOf("/document/");
                if (docPos != -1) {
                    String docId = contentUri.substring(docPos + 10); // Skip "/document/"
                    // URL decode the docId
                    docId = java.net.URLDecoder.decode(docId, "UTF-8");
                    
                    // Parse document ID format: "primary:path/to/file" or "home:path/to/file"
                    int colonPos = docId.indexOf(':');
                    if (colonPos != -1) {
                        String storage = docId.substring(0, colonPos);
                        String path = docId.substring(colonPos + 1);
                        
                        if ("primary".equalsIgnoreCase(storage)) {
                            return "/storage/emulated/0/" + path;
                        } else {
                            // For other storage volumes
                            return "/storage/" + storage + "/" + path;
                        }
                    }
                }
            }
            
            // Handle media documents (content://com.android.providers.media.documents/...)
            if (contentUri.contains("com.android.providers.media.documents")) {
                // Try to query the MediaStore for the file path
                Uri uri = Uri.parse(contentUri);
                String[] projection = {android.provider.MediaStore.MediaColumns.DATA};
                try (android.database.Cursor cursor = activity.getContentResolver().query(uri, projection, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        int columnIndex = cursor.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATA);
                        return cursor.getString(columnIndex);
                    }
                }
            }
            
            // For other content URIs, try a generic query
            Uri uri = Uri.parse(contentUri);
            String[] projection = {android.provider.MediaStore.MediaColumns.DATA};
            try (android.database.Cursor cursor = activity.getContentResolver().query(uri, projection, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    int columnIndex = cursor.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATA);
                    return cursor.getString(columnIndex);
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error converting content URI to file path: " + e.getMessage());
        }
        
        return null;
    }
    
    /**
     * Converts a tree URI to a document URI.
     * Tree URI format: content://authority/tree/treeEncodedId/path/to/file
     * Document URI format: content://authority/document/treeEncodedId%2Fpath%2Fto%2Ffile
     */
    private String convertTreeUriToDocumentUri(String treeUri) {
        if (treeUri == null || !treeUri.startsWith("content://")) {
            return treeUri;
        }
        
        // Check if it's already a document URI
        if (treeUri.contains("/document/")) {
            return treeUri;
        }
        
        // Find the /tree/ position
        int treePos = treeUri.indexOf("/tree/");
        if (treePos == -1) {
            return treeUri;
        }
        
        // Extract parts
        String base = treeUri.substring(0, treePos);
        String afterTree = treeUri.substring(treePos + 6); // Skip "/tree/"
        
        // The tree ID is the first segment, rest is the path
        int firstSlash = afterTree.indexOf("/");
        if (firstSlash == -1) {
            // Just a tree root
            return base + "/document/" + afterTree;
        }
        
        String treeId = afterTree.substring(0, firstSlash);
        String path = afterTree.substring(firstSlash + 1);
        
        // Build document URI with encoded path
        return base + "/document/" + treeId + "%2F" + path.replace("/", "%2F");
    }
    
    /**
     * Converts a SAF (Storage Access Framework) content URI to a real file path.
     * Returns the actual filesystem path for tree URIs and document URIs.
     * Returns empty string if the URI cannot be converted.
     */
    @UsedByGodot
    public String getRealPathFromSafUri(String safUri) {
        Log.d(TAG, "getRealPathFromSafUri() called: " + safUri);
        
        if (safUri == null || safUri.isEmpty()) {
            return "";
        }
        
        String realPath = getFilePathFromContentUri(activity, safUri);
        if (realPath != null && !realPath.isEmpty()) {
            Log.d(TAG, "Converted SAF URI to path: " + realPath);
            return realPath;
        }
        
        Log.w(TAG, "Could not convert SAF URI to real path: " + safUri);
        return "";
    }
    
    @UsedByGodot
    public boolean createSafDirectory(String treeUriString, String dirName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "createSafDirectory() called");
        Log.d(TAG, "Tree URI: " + treeUriString);
        Log.d(TAG, "Directory name: " + dirName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        // Skip invalid directory names
        if (dirName == null || dirName.isEmpty() || dirName.equals(".") || dirName.equals("..")) {
            Log.d(TAG, "Skipping invalid directory name: " + dirName);
            return true;
        }
        
        try {
            Uri treeUri = Uri.parse(treeUriString);
            DocumentFile pickedDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (pickedDir == null) {
                Log.e(TAG, "ERROR: Could not get DocumentFile from tree URI");
                return false;
            }
            
            if (!pickedDir.exists()) {
                Log.e(TAG, "ERROR: Tree directory does not exist");
                return false;
            }
            
            // Check if directory already exists
            DocumentFile existingDir = pickedDir.findFile(dirName);
            if (existingDir != null && existingDir.isDirectory()) {
                Log.d(TAG, "Directory already exists: " + dirName);
                return true;
            }
            
            // Create the directory
            DocumentFile newDir = pickedDir.createDirectory(dirName);
            if (newDir != null) {
                Log.d(TAG, "SUCCESS: Created directory: " + dirName);
                Log.d(TAG, "==========================================");
                return true;
            } else {
                Log.e(TAG, "ERROR: Failed to create directory");
                return false;
            }
        } catch (Exception e) {
            Log.e(TAG, "ERROR creating SAF directory: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Creates a directory recursively in SAF storage given a full SAF path.
     * Creates all parent directories as needed.
     * Returns true if successful, false otherwise.
     */
    @UsedByGodot
    public boolean createSafDirectoryFromFullPath(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "createSafDirectoryFromFullPath() called");
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
                // Just the tree root, nothing to create
                Log.d(TAG, "Path is tree root, nothing to create");
                return true;
            }
            
            // Extract tree base URI
            String treeBase = fullPath.substring(0, nextSlash);
            Log.d(TAG, "Tree base: " + treeBase);
            
            // Extract relative path from tree
            String relativePath = fullPath.substring(nextSlash + 1);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Skip invalid paths
            if (relativePath.isEmpty() || relativePath.equals(".") || relativePath.equals("..")) {
                Log.d(TAG, "Skipping invalid relative path: " + relativePath);
                return true;
            }
            
            // Navigate to/create each directory level
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            String[] pathParts = relativePath.split("/");
            
            for (String dirName : pathParts) {
                if (dirName.isEmpty() || dirName.equals(".") || dirName.equals("..")) {
                    continue;
                }
                
                Log.d(TAG, "Processing directory level: " + dirName);
                
                // Check if directory already exists
                DocumentFile nextDir = currentDir.findFile(dirName);
                if (nextDir != null && nextDir.isDirectory()) {
                    Log.d(TAG, "Directory exists: " + dirName);
                    currentDir = nextDir;
                    continue;
                }
                
                // Create the directory
                Log.d(TAG, "Creating directory: " + dirName);
                nextDir = currentDir.createDirectory(dirName);
                if (nextDir == null) {
                    Log.e(TAG, "ERROR: Failed to create directory: " + dirName);
                    return false;
                }
                
                Log.d(TAG, "Successfully created: " + dirName);
                currentDir = nextDir;
            }
            
            Log.d(TAG, "SUCCESS: Created all directories in path");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR creating SAF directory from full path: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    @UsedByGodot
    public boolean copyFileToSaf(String sourcePath, String treeUriString, String fileName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "copyFileToSaf() called");
        Log.d(TAG, "Source: " + sourcePath);
        Log.d(TAG, "Tree URI: " + treeUriString);
        Log.d(TAG, "File name: " + fileName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        File sourceFile = new File(sourcePath);
        if (!sourceFile.exists()) {
            Log.e(TAG, "ERROR: Source file does not exist: " + sourcePath);
            return false;
        }
        
        long fileSize = sourceFile.length();
        Log.d(TAG, "Source file size: " + fileSize + " bytes");
        
        try {
            Log.d(TAG, "Parsing tree URI...");
            Uri treeUri = Uri.parse(treeUriString);
            Log.d(TAG, "Tree URI parsed: " + treeUri.toString());
            
            // Check if we have permission for this URI
            Log.d(TAG, "Checking URI permissions...");
            int takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
            try {
                activity.getContentResolver().takePersistableUriPermission(treeUri, takeFlags);
                Log.d(TAG, "URI permission persisted successfully");
            } catch (SecurityException e) {
                Log.e(TAG, "ERROR: No persistable permission for URI: " + e.getMessage());
                Log.e(TAG, "The user needs to re-select the directory in settings");
                return false;
            }
            
            Log.d(TAG, "Getting DocumentFile from tree URI...");
            DocumentFile pickedDir = DocumentFile.fromTreeUri(activity, treeUri);
            Log.d(TAG, "DocumentFile obtained: " + (pickedDir != null ? "YES" : "NULL"));
            
            if (pickedDir == null) {
                Log.e(TAG, "ERROR: Could not get DocumentFile from tree URI");
                return false;
            }
            
            if (!pickedDir.exists()) {
                Log.e(TAG, "ERROR: Tree directory does not exist");
                return false;
            }
            
            // Navigate to subdirectory if needed (e.g., "dc/file.chd")
            DocumentFile targetDir = pickedDir;
            String actualFileName = fileName;
            
            if (fileName.contains("/")) {
                String[] pathParts = fileName.split("/");
                for (int i = 0; i < pathParts.length - 1; i++) {
                    String dirName = pathParts[i];
                    if (dirName.isEmpty() || dirName.equals(".") || dirName.equals("..")) continue;
                    
                    DocumentFile subDir = targetDir.findFile(dirName);
                    if (subDir == null || !subDir.isDirectory()) {
                        Log.d(TAG, "Creating subdirectory: " + dirName);
                        subDir = targetDir.createDirectory(dirName);
                        if (subDir == null) {
                            Log.e(TAG, "ERROR: Failed to create subdirectory: " + dirName);
                            return false;
                        }
                    }
                    targetDir = subDir;
                }
                actualFileName = pathParts[pathParts.length - 1];
                Log.d(TAG, "Navigated to subdirectory, file: " + actualFileName);
            }
            
            // Check if file already exists and delete it
            DocumentFile existingFile = targetDir.findFile(actualFileName);
            if (existingFile != null) {
                Log.d(TAG, "File already exists, deleting: " + actualFileName);
                existingFile.delete();
            }
            
            // Determine MIME type based on extension
            String mimeType = getMimeType(actualFileName);
            Log.d(TAG, "Creating file with MIME type: " + mimeType);
            
            // Create the destination file
            DocumentFile destFile = targetDir.createFile(mimeType, actualFileName);
            if (destFile == null) {
                Log.e(TAG, "ERROR: Failed to create destination file");
                return false;
            }
            
            Log.d(TAG, "Starting file copy...");
            
            // Copy the file
            FileInputStream inputStream = new FileInputStream(sourceFile);
            OutputStream outputStream = activity.getContentResolver().openOutputStream(destFile.getUri());
            
            if (outputStream == null) {
                Log.e(TAG, "ERROR: Could not open output stream");
                inputStream.close();
                return false;
            }
            
            byte[] buffer = new byte[8192];
            int bytesRead;
            long totalBytesRead = 0;
            long lastProgressLog = 0;
            long lastProgressEmit = 0;
            
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
                totalBytesRead += bytesRead;
                
                // Log progress every 50MB
                if (totalBytesRead - lastProgressLog > 50 * 1024 * 1024) {
                    int progress = (int) ((totalBytesRead * 100) / fileSize);
                    Log.d(TAG, "Copy progress: " + progress + "% (" + totalBytesRead + "/" + fileSize + " bytes)");
                    lastProgressLog = totalBytesRead;
                }
                
                // Emit signal to Godot every 10MB for UI updates
                if (totalBytesRead - lastProgressEmit > 10 * 1024 * 1024) {
                    int progressPercent = (int) ((totalBytesRead * 100) / fileSize);
                    emitSignal("saf_copy_progress", actualFileName, progressPercent);
                    lastProgressEmit = totalBytesRead;
                }
            }
            
            outputStream.flush();
            outputStream.close();
            inputStream.close();
            
            Log.d(TAG, "SUCCESS: Copied " + totalBytesRead + " bytes");
            Log.d(TAG, "Destination: " + destFile.getUri().toString());
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR copying file to SAF: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    private String getMimeType(String fileName) {
        String extension = fileName.substring(fileName.lastIndexOf(".") + 1).toLowerCase();
        switch (extension) {
            case "apk":
                return "application/vnd.android.package-archive";
            case "zip":
                return "application/zip";
            case "7z":
                return "application/x-7z-compressed";
            case "rar":
                return "application/x-rar-compressed";
            case "iso":
                return "application/x-iso9660-image";
            case "bin":
            case "cue":
                return "application/octet-stream";
            case "chd":
                return "application/x-chd";
            case "nds":
            case "gba":
            case "gbc":
            case "gb":
                return "application/x-nintendo-rom";
            default:
                return "application/octet-stream";
        }
    }
    
    /**
     * Deletes a file or directory using a SAF (Storage Access Framework) URI.
     * Returns true if deletion was successful, false otherwise.
     */
    @UsedByGodot
    public boolean deleteSafFile(String fileUriString) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "deleteSafFile() called");
        Log.d(TAG, "File URI: " + fileUriString);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Parse the tree URI to extract tree base and relative path
            // Format: content://authority/tree/treeId/subdir1/subdir2/filename
            int treePos = fileUriString.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format - no /tree/ found");
                return false;
            }
            
            // Find end of tree ID (first / after /tree/)
            int afterTree = treePos + 6;
            int nextSlash = fileUriString.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                Log.e(TAG, "ERROR: Path is tree root, no file to delete");
                return false;
            }
            
            // Extract tree base URI (up to and including tree ID)
            String treeBase = fileUriString.substring(0, nextSlash);
            Log.d(TAG, "Tree base: " + treeBase);
            
            // Extract relative path from tree
            String relativePath = fileUriString.substring(nextSlash + 1);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate through DocumentFile tree (same as safFileExists)
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            // Split relative path into components
            String[] pathParts = relativePath.split("/");
            
            // Navigate through directories
            for (int i = 0; i < pathParts.length - 1; i++) {
                String dirName = pathParts[i];
                if (dirName.isEmpty()) continue;
                
                Log.d(TAG, "Looking for directory: " + dirName);
                DocumentFile subDir = currentDir.findFile(dirName);
                if (subDir == null || !subDir.isDirectory()) {
                    Log.e(TAG, "Directory not found: " + dirName);
                    return false;
                }
                currentDir = subDir;
            }
            
            // Find the file
            String fileName = pathParts[pathParts.length - 1];
            Log.d(TAG, "Looking for file: " + fileName);
            DocumentFile file = currentDir.findFile(fileName);
            
            if (file == null || !file.exists()) {
                Log.e(TAG, "ERROR: File does not exist");
                return false;
            }
            
            // Delete the file
            boolean deleted = file.delete();
            
            if (deleted) {
                Log.d(TAG, "SUCCESS: Deleted file at " + fileUriString);
                Log.d(TAG, "==========================================");
                return true;
            } else {
                Log.e(TAG, "ERROR: DocumentFile.delete() returned false");
                return false;
            }
        } catch (Exception e) {
            Log.e(TAG, "ERROR deleting SAF file: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    /**
     * Recursively lists all files in a SAF tree directory and returns them as a JSON array.
     * Format: ["platform/file1.ext", "platform/file2.ext", ...]
     */
    @UsedByGodot
    public String listSafFiles(String treeUriString) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "listSafFiles() called");
        Log.d(TAG, "Tree URI: " + treeUriString);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return "[]";
        }
        
        try {
            Uri treeUri = Uri.parse(treeUriString);
            
            // Check permissions
            int takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION;
            try {
                activity.getContentResolver().takePersistableUriPermission(treeUri, takeFlags);
            } catch (SecurityException e) {
                Log.e(TAG, "ERROR: No permission for URI: " + e.getMessage());
                return "[]";
            }
            
            DocumentFile rootDir = DocumentFile.fromTreeUri(activity, treeUri);
            if (rootDir == null || !rootDir.exists()) {
                Log.e(TAG, "ERROR: Cannot access directory");
                return "[]";
            }
            
            List<String> fileList = new ArrayList<>();
            enumerateFiles(rootDir, "", fileList);
            
            // Convert to JSON array string
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < fileList.size(); i++) {
                if (i > 0) json.append(",");
                json.append("\"").append(fileList.get(i)).append("\"");
            }
            json.append("]");
            
            Log.d(TAG, "Found " + fileList.size() + " files");
            Log.d(TAG, "==========================================");
            return json.toString();
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR listing SAF files: " + e.getMessage());
            return "[]";
        }
    }
    
    private void enumerateFiles(DocumentFile dir, String pathPrefix, List<String> results) {
        DocumentFile[] files = dir.listFiles();
        if (files == null) return;
        
        for (DocumentFile file : files) {
            String currentPath = pathPrefix;
            if (!currentPath.isEmpty()) {
                currentPath += "/";
            }
            currentPath += file.getName();
            
            if (file.isDirectory()) {
                enumerateFiles(file, currentPath, results);
            } else {
                results.add(currentPath);
            }
        }
    }
    
    /**
     * Checks if a directory exists in SAF storage.
     * Returns true if the directory exists and is accessible, false otherwise.
     */
    @UsedByGodot
    public boolean safDirExists(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "safDirExists() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Parse the path to extract tree base and directory path
            // Format: content://authority/tree/treeId/subdir1/subdir2
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format - no /tree/ found");
                return false;
            }
            
            // Find end of tree ID (first / after /tree/)
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                // Just the tree root
                Log.d(TAG, "Path is tree root, checking if accessible");
                Uri treeUri = Uri.parse(fullPath);
                DocumentFile treeDir = DocumentFile.fromTreeUri(activity, treeUri);
                boolean exists = treeDir != null && treeDir.exists() && treeDir.isDirectory();
                Log.d(TAG, "Tree root exists: " + exists);
                return exists;
            }
            
            // Extract tree base URI (up to and including tree ID)
            String treeBase = fullPath.substring(0, nextSlash);
            Log.d(TAG, "Tree base: " + treeBase);
            
            // Extract relative path from tree
            String relativePath = fullPath.substring(nextSlash + 1);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate through DocumentFile tree
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            // Split relative path into components
            String[] pathParts = relativePath.split("/");
            
            // Navigate through directories
            for (String dirName : pathParts) {
                if (dirName.isEmpty()) continue;
                
                Log.d(TAG, "Looking for directory: " + dirName);
                DocumentFile subDir = currentDir.findFile(dirName);
                if (subDir == null || !subDir.isDirectory()) {
                    Log.d(TAG, "Directory not found: " + dirName);
                    return false;
                }
                currentDir = subDir;
            }
            
            boolean exists = currentDir.exists();
            Log.d(TAG, "Directory exists: " + exists);
            Log.d(TAG, "==========================================");
            return exists;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR checking directory existence: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
    }
    
    /**
     * Lists files in a SAF directory.
     * Returns a Godot array-compatible string representation of file names.
     * Only lists immediate children (not recursive).
     */
    @UsedByGodot
    public String safListFiles(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "safListFiles() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return "[]";
        }
        
        try {
            List<String> fileList = new ArrayList<>();
            
            // Parse the path to extract tree base and directory path
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format");
                return "[]";
            }
            
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            Uri treeUri;
            DocumentFile targetDir;
            
            if (nextSlash == -1) {
                // Just the tree root
                treeUri = Uri.parse(fullPath);
                targetDir = DocumentFile.fromTreeUri(activity, treeUri);
            } else {
                String treeBase = fullPath.substring(0, nextSlash);
                String relativePath = fullPath.substring(nextSlash + 1);
                
                treeUri = Uri.parse(treeBase);
                targetDir = DocumentFile.fromTreeUri(activity, treeUri);
                
                // Navigate to target directory
                String[] pathParts = relativePath.split("/");
                for (String dirName : pathParts) {
                    if (dirName.isEmpty()) continue;
                    
                    DocumentFile subDir = targetDir.findFile(dirName);
                    if (subDir == null || !subDir.isDirectory()) {
                        Log.d(TAG, "Directory not found: " + dirName);
                        return "[]";
                    }
                    targetDir = subDir;
                }
            }
            
            if (targetDir == null || !targetDir.exists()) {
                Log.e(TAG, "ERROR: Cannot access directory");
                return "[]";
            }
            
            // List files
            DocumentFile[] files = targetDir.listFiles();
            if (files != null) {
                for (DocumentFile file : files) {
                    fileList.add(file.getName());
                }
            }
            
            // Convert to JSON array string
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < fileList.size(); i++) {
                if (i > 0) json.append(",");
                json.append("\"").append(fileList.get(i)).append("\"");
            }
            json.append("]");
            
            Log.d(TAG, "Found " + fileList.size() + " items");
            Log.d(TAG, "==========================================");
            return json.toString();
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR listing files: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return "[]";
        }
    }
    
    /**
     * Writes text content to a file in SAF storage.
     * Creates parent directories if they don't exist.
     * Returns true if successful, false otherwise.
     */
    @UsedByGodot
    public boolean writeSafFile(String fullPath, String content) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "writeSafFile() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Parse the path to extract tree base and file path
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "ERROR: Invalid SAF path format");
                return false;
            }
            
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                Log.e(TAG, "ERROR: Path is tree root, cannot write file");
                return false;
            }
            
            String treeBase = fullPath.substring(0, nextSlash);
            String relativePath = fullPath.substring(nextSlash + 1);
            
            Log.d(TAG, "Tree base: " + treeBase);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate to parent directory and create if needed
            Uri treeUri = Uri.parse(treeBase);
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "ERROR: Could not access tree root");
                return false;
            }
            
            // Split path and navigate/create directories
            String[] pathParts = relativePath.split("/");
            String fileName = pathParts[pathParts.length - 1];
            
            // Navigate through parent directories
            for (int i = 0; i < pathParts.length - 1; i++) {
                String dirName = pathParts[i];
                if (dirName.isEmpty()) continue;
                
                DocumentFile subDir = currentDir.findFile(dirName);
                if (subDir == null || !subDir.isDirectory()) {
                    // Create the directory
                    subDir = currentDir.createDirectory(dirName);
                    if (subDir == null) {
                        Log.e(TAG, "ERROR: Failed to create directory: " + dirName);
                        return false;
                    }
                }
                currentDir = subDir;
            }
            
            // Check if file exists and delete it
            DocumentFile existingFile = currentDir.findFile(fileName);
            if (existingFile != null) {
                existingFile.delete();
            }
            
            // Create new file
            String mimeType = getMimeType(fileName);
            DocumentFile newFile = currentDir.createFile(mimeType, fileName);
            
            if (newFile == null) {
                Log.e(TAG, "ERROR: Failed to create file");
                return false;
            }
            
            // Write content
            OutputStream outputStream = activity.getContentResolver().openOutputStream(newFile.getUri());
            if (outputStream == null) {
                Log.e(TAG, "ERROR: Could not open output stream");
                return false;
            }
            
            outputStream.write(content.getBytes("UTF-8"));
            outputStream.flush();
            outputStream.close();
            
            Log.d(TAG, "SUCCESS: Wrote file");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR writing file: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            Log.e(TAG, "Stack trace:");
            for (StackTraceElement element : e.getStackTrace()) {
                Log.e(TAG, "  at " + element.toString());
            }
            return false;
        }
    }
    
    /**
     * Navigates to a file in SAF storage given a full SAF path.
     * Returns the DocumentFile if found, null otherwise.
     */
    private DocumentFile navigateToSafFile(String fullPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "navigateToSafFile() called");
        Log.d(TAG, "Full path: " + fullPath);
        
        try {
            // Parse the path to extract tree base and file path
            int treePos = fullPath.indexOf("/tree/");
            if (treePos == -1) {
                Log.e(TAG, "Invalid SAF path format - no /tree/ found");
                return null;
            }
            
            int afterTree = treePos + 6;
            int nextSlash = fullPath.indexOf("/", afterTree);
            
            if (nextSlash == -1) {
                // Just the tree root, can't be a file
                Log.e(TAG, "Path is tree root, not a file");
                return null;
            }
            
            // Extract tree base URI
            String treeBase = fullPath.substring(0, nextSlash);
            String relativePath = fullPath.substring(nextSlash + 1);
            
            Log.d(TAG, "Tree base: " + treeBase);
            Log.d(TAG, "Relative path: " + relativePath);
            
            // Navigate to the file
            Uri treeUri = Uri.parse(treeBase);
            Log.d(TAG, "Parsed tree URI: " + treeUri.toString());
            
            DocumentFile currentDir = DocumentFile.fromTreeUri(activity, treeUri);
            
            if (currentDir == null) {
                Log.e(TAG, "Could not access tree root");
                return null;
            }
            
            Log.d(TAG, "Successfully accessed tree root");
            
            String[] pathParts = relativePath.split("/");
            Log.d(TAG, "Path parts count: " + pathParts.length);
            
            for (int i = 0; i < pathParts.length; i++) {
                String part = pathParts[i];
                Log.d(TAG, "Processing part " + i + ": '" + part + "'");
                
                if (part.isEmpty() || part.equals(".") || part.equals("..")) {
                    Log.d(TAG, "Skipping empty/./.. part");
                    continue;
                }
                
                boolean isLastPart = (i == pathParts.length - 1);
                Log.d(TAG, "Looking for: '" + part + "', isLastPart=" + isLastPart);
                
                DocumentFile nextFile = currentDir.findFile(part);
                
                if (nextFile == null) {
                    Log.e(TAG, "File/directory not found: '" + part + "'");
                    // List what's available for debugging
                    Log.d(TAG, "Available files in current directory:");
                    for (DocumentFile file : currentDir.listFiles()) {
                        Log.d(TAG, "  - " + file.getName() + " (isFile=" + file.isFile() + ", isDir=" + file.isDirectory() + ")");
                    }
                    return null;
                }
                
                Log.d(TAG, "Found: '" + part + "' (isFile=" + nextFile.isFile() + ", isDir=" + nextFile.isDirectory() + ")");
                
                if (isLastPart) {
                    // This should be the file
                    if (!nextFile.isFile()) {
                        Log.e(TAG, "Expected file but found directory: " + part);
                        return null;
                    }
                    Log.d(TAG, "SUCCESS: Found target file");
                    Log.d(TAG, "==========================================");
                    return nextFile;
                } else {
                    // This should be a directory
                    if (!nextFile.isDirectory()) {
                        Log.e(TAG, "Expected directory but found file: " + part);
                        return null;
                    }
                    currentDir = nextFile;
                    Log.d(TAG, "Navigated into directory: " + part);
                }
            }
            
            Log.e(TAG, "Could not navigate to file");
            return null;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR navigating to SAF file: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            e.printStackTrace();
            return null;
        }
    }
    
    /**
     * Copies a file from SAF storage to a local file path.
     * Used to read SAF files by copying them to temp location first.
     * Returns true if successful, false otherwise.
     */
    @UsedByGodot
    public boolean copySafFileToLocal(String safUri, String localPath) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "copySafFileToLocal() called");
        Log.d(TAG, "SAF URI: " + safUri);
        Log.d(TAG, "Local path: " + localPath);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            // Convert Godot user:// path to absolute path if needed
            String absolutePath = localPath;
            if (localPath.startsWith("user:")) {
                // Godot user:// maps to /data/data/[package]/files/
                String userPath = localPath.substring(5); // Remove "user:" prefix
                if (userPath.startsWith("/")) {
                    userPath = userPath.substring(1);
                }
                absolutePath = activity.getFilesDir().getAbsolutePath() + "/" + userPath;
                Log.d(TAG, "Converted user:// path to: " + absolutePath);
            }
            
            // Create parent directories for local path
            File localFile = new File(absolutePath);
            File parentDir = localFile.getParentFile();
            if (parentDir != null && !parentDir.exists()) {
                boolean created = parentDir.mkdirs();
                Log.d(TAG, "Created parent directories: " + created + " for " + parentDir.getAbsolutePath());
            }
            
            // Navigate to the file using DocumentFile
            DocumentFile sourceFile = navigateToSafFile(safUri);
            if (sourceFile == null) {
                Log.e(TAG, "ERROR: Could not find SAF file");
                return false;
            }
            
            // Get input stream from the file's URI
            Uri fileUri = sourceFile.getUri();
            Log.d(TAG, "File URI: " + fileUri.toString());
            java.io.InputStream inputStream = activity.getContentResolver().openInputStream(fileUri);
            
            if (inputStream == null) {
                Log.e(TAG, "ERROR: Could not open SAF input stream");
                return false;
            }
            
            // Create output stream to local file
            java.io.FileOutputStream outputStream = new java.io.FileOutputStream(absolutePath);
            
            // Copy data
            byte[] buffer = new byte[8192];
            int bytesRead;
            long totalBytes = 0;
            
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
                totalBytes += bytesRead;
            }
            
            inputStream.close();
            outputStream.flush();
            outputStream.close();
            
            Log.d(TAG, "SUCCESS: Copied " + totalBytes + " bytes");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR copying file from SAF: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
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