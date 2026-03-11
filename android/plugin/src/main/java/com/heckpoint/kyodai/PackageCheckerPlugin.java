package com.heckpoint.kyodai;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.util.Log;
import androidx.core.content.FileProvider;
import androidx.documentfile.provider.DocumentFile;
import org.godotengine.godot.Godot;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.File;
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
     * NEW UNIFIED INTENT LAUNCHER
     * 
     * Supports multiple ways to deliver the ROM to the emulator:
     * - "intent_data": ROM passed via intent.setDataAndType() as content:// URI
     * - "extra_file_path": ROM path passed as string extra
     * - "extra_file_uri": ROM URI passed as string extra (content://)
     * - "extra_document_uri": ROM URI passed as document URI string
     * - "none": No ROM delivery (just launch the emulator)
     * 
     * Extras can be configured with types:
     * - "string": Literal string value
     * - "file_path": File system path (replaces {rom} with ROM path)
     * - "file_uri": content:// URI (replaces {rom} with content URI)
     * - "document_uri": Document provider URI
     * - "boolean": Boolean value
     * 
     * @param action Intent action (e.g., "android.intent.action.VIEW")
     * @param packageName Target app package name
     * @param className Target activity class name (can be null for package-only launch)
     * @param romPath Absolute file path to the ROM
     * @param romDelivery How to deliver the ROM (see above)
     * @param extrasJson JSON array string of extras (format: [{"key": "name", "value": "val", "type": "string"}, ...])
     * @param mimeType MIME type for intent data (default: "application/octet-stream")
     * @param clearTask Whether to use FLAG_ACTIVITY_CLEAR_TASK
     * @param grantUriPermission Whether to grant FLAG_GRANT_READ_URI_PERMISSION
     */
    @UsedByGodot
    public boolean launchAndroidIntent(String action, String packageName, String className, String romPath,
                                        String corePath, String romDelivery, String extrasJson, String mimeType,
                                        boolean clearTask, boolean grantUriPermission, boolean useDocumentUri) {
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
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent();
            
            // Set component if className provided, otherwise just set package
            if (packageName != null && !packageName.isEmpty()) {
                if (className != null && !className.isEmpty()) {
                    intent.setClassName(packageName, className);
                    Log.d(TAG, "Set component: " + packageName + "/" + className);
                } else {
                    intent.setPackage(packageName);
                    Log.d(TAG, "Set package: " + packageName);
                }
            } else {
                Log.e(TAG, "ERROR: Package name is required");
                return false;
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
                        String authority = activity.getPackageName() + ".fileprovider";
                        romContentUri = FileProvider.getUriForFile(activity, authority, romFile);
                        Log.d(TAG, "Generated FileProvider URI: " + romContentUri);
                    } catch (IllegalArgumentException e) {
                        Log.w(TAG, "Could not generate FileProvider URI: " + e.getMessage());
                    }
                } else {
                    Log.w(TAG, "ROM file does not exist: " + filePath);
                }
            }
            
            // Deliver ROM based on romDelivery mode
            if (romDelivery != null && !romDelivery.isEmpty()) {
                switch (romDelivery) {
                    case "intent_data":
                        if (romContentUri != null) {
                            String type = (mimeType != null && !mimeType.isEmpty()) ? mimeType : "application/octet-stream";
                            
                            // Convert tree URI to document URI ONLY when explicitly requested (for Eden)
                            if (useDocumentUri) {
                                String uriString = romContentUri.toString();
                                if (uriString.contains("/tree/")) {
                                    String docUriString = convertTreeUriToDocumentUri(uriString);
                                    if (!docUriString.equals(uriString)) {
                                        romContentUri = Uri.parse(docUriString);
                                        Log.d(TAG, "Converted tree URI to document URI: " + romContentUri);
                                    }
                                }
                            }
                            
                            intent.setDataAndType(romContentUri, type);
                            Log.d(TAG, "Set intent data (content URI): " + romContentUri);
                            
                            // Grant read permission via ClipData for VIEW intents
                            if (grantUriPermission || action.equals(Intent.ACTION_VIEW)) {
                                intent.setClipData(ClipData.newRawUri(null, romContentUri));
                                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                Log.d(TAG, "Granted URI read permission via ClipData");
                            }
                        }
                        break;
                        
                    case "extra_file_path":
                        // ROM delivered as file path string in extras (handled below)
                        Log.d(TAG, "ROM will be delivered via extra as file path");
                        break;
                        
                    case "extra_file_uri":
                        // ROM delivered as content:// URI string in extras (handled below)
                        Log.d(TAG, "ROM will be delivered via extra as content URI");
                        break;
                        
                    case "extra_document_uri":
                        // ROM delivered as document URI in extras (handled below)
                        Log.d(TAG, "ROM will be delivered via extra as document URI");
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
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added file path extra: " + key + "=" + value);
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
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added SAF URI extra: " + key + "=" + value);
                                break;
                                
                            case "document_uri":
                                intent.putExtra(key, value);
                                Log.d(TAG, "Added document URI extra: " + key + "=" + value);
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
                    if (dirName.isEmpty()) continue;
                    
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
            
            while ((bytesRead = inputStream.read(buffer)) != -1) {
                outputStream.write(buffer, 0, bytesRead);
                totalBytesRead += bytesRead;
                
                // Log progress every 50MB
                if (totalBytesRead - lastProgressLog > 50 * 1024 * 1024) {
                    int progress = (int) ((totalBytesRead * 100) / fileSize);
                    Log.d(TAG, "Copy progress: " + progress + "% (" + totalBytesRead + "/" + fileSize + " bytes)");
                    lastProgressLog = totalBytesRead;
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
}