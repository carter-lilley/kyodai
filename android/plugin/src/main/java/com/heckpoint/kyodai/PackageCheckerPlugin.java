package com.heckpoint.kyodai;

import android.app.Activity;
import android.content.Intent;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.util.Log;
import androidx.documentfile.provider.DocumentFile;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;

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
    
    @UsedByGodot
    public boolean launchAndroidIntent(String action, String packageName, String className, String romUri, String coreName) {
        Log.d(TAG, "==========================================");
        Log.d(TAG, "launchAndroidIntent() called");
        Log.d(TAG, "Action: " + action);
        Log.d(TAG, "Package: " + packageName);
        Log.d(TAG, "Class: " + className);
        Log.d(TAG, "ROM URI: " + romUri);
        Log.d(TAG, "Core: " + coreName);
        
        if (activity == null) {
            Log.e(TAG, "ERROR: Activity is null!");
            return false;
        }
        
        try {
            Intent intent = new Intent();
            
            // Set component (package + class) - this is REQUIRED
            if (packageName != null && !packageName.isEmpty() && className != null && !className.isEmpty()) {
                intent.setClassName(packageName, className);
                Log.d(TAG, "Set component: " + packageName + "/" + className);
            } else {
                Log.e(TAG, "ERROR: Package name and class name are required");
                return false;
            }
            
            // Set action
            if (action != null && !action.isEmpty()) {
                intent.setAction(action);
            }
            
            // Add extras for RetroArch
            if (romUri != null && !romUri.isEmpty()) {
                Uri romFileUri = Uri.parse(romUri);
                intent.putExtra("ROM", romUri);
                Log.d(TAG, "Added ROM extra: " + romUri);
                
                // Grant explicit URI permission to the target package
                Log.d(TAG, "Granting URI permission to: " + packageName);
                activity.grantUriPermission(packageName, romFileUri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
            if (coreName != null && !coreName.isEmpty()) {
                intent.putExtra("LIBRETRO", coreName);
                Log.d(TAG, "Added LIBRETRO extra: " + coreName);
            }
            
            // Also add flag for intent-based permission
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            
            Log.d(TAG, "Starting activity with intent...");
            activity.startActivity(intent);
            
            Log.d(TAG, "SUCCESS: Android intent launched");
            Log.d(TAG, "==========================================");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "ERROR launching Android intent: " + e.getMessage());
            Log.e(TAG, "Exception type: " + e.getClass().getName());
            return false;
        }
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
}