package com.heckpoint.kyodai;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;
import android.util.Log;
import androidx.core.app.NotificationCompat;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipInputStream;
import java.util.Enumeration;

/**
 * Extraction service that runs in a separate process to avoid sharing memory with Godot.
 * This prevents OOM kills during large game extractions on low-RAM devices.
 *
 * Destinations under another app's /Android/data/ (or /Android/obb/) are written
 * via DocumentsContract (persisted tree grant, or manage=true for
 * MANAGE_EXTERNAL_STORAGE holders) when direct File I/O is denied.
 * 
 * Usage:
 * Intent intent = new Intent(context, ExtractorService.class);
 * intent.setAction("EXTRACT");
 * intent.putExtra("zip_path", "/path/to/game.zip");
 * intent.putExtra("extract_dir", "/path/to/dest");
 * context.startService(intent);
 * 
 * The service sends a broadcast when extraction completes or fails:
 * Action: "com.heckpoint.kyodai.EXTRACTION_COMPLETE"
 * Extras: "success" (boolean), "zip_path" (String), "extract_dir" (String), "error" (String)
 */
public class ExtractorService extends Service {
    private static final String TAG = "ExtractorService";
    private static final String CHANNEL_ID = "kyodai_extractor";
    private static final int NOTIFICATION_ID = 2001;
    private static final String ACTION_EXTRACTION_COMPLETE = "com.heckpoint.kyodai.EXTRACTION_COMPLETE";
    private static final String DOCS_AUTHORITY = "com.android.externalstorage.documents";

    private boolean jobTracked = false;
    
    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "ExtractorService created in process " + android.os.Process.myPid());
        createNotificationChannel();
    }
    
    @Override
    public IBinder onBind(Intent intent) {
        return null; // Not a bound service
    }
    
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        
        String action = intent.getAction();
        if (action == null) action = "";
        
        switch (action) {
            case "EXTRACT":
                String zipPath = intent.getStringExtra("zip_path");
                String extractDir = intent.getStringExtra("extract_dir");
                String gameName = intent.getStringExtra("game_name");
                if (gameName == null) gameName = "Game";
                
                if (zipPath != null && extractDir != null) {
                    startExtraction(zipPath, extractDir, gameName);
                } else {
                    Log.e(TAG, "Missing zip_path or extract_dir");
                    stopSelf();
                }
                break;
                
            default:
                stopSelf();
                break;
        }
        
        return START_STICKY;
    }
    
    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Kyodai Game Extraction",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Shows game extraction progress");
            channel.setSound(null, null);
            channel.enableVibration(false);
            
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
    
    private void startExtraction(String zipPath, String extractDir, String gameName) {
        // Start as foreground service immediately
        Notification notification = buildNotification(gameName, 0);
        try {
            startForeground(NOTIFICATION_ID, notification);
            jobTracked = true;
            SleepSaver.jobStarted();
            Log.d(TAG, "Started foreground extraction for: " + gameName);
        } catch (Exception e) {
            Log.e(TAG, "Failed to start foreground: " + e.getMessage());
        }
        
        // Derive a unique marker base from the zip filename so concurrent extractions
        // into the same directory don't overwrite each other's completion markers.
        String markerBase = deriveMarkerBase(zipPath);
        
        // Run extraction on a background thread
        final String finalMarkerBase = markerBase;
        new Thread(() -> {
            boolean success = extractZipStreaming(zipPath, extractDir, gameName, finalMarkerBase);
            
            // Write completion marker files for 100% reliable completion detection
            // The Godot side polls for these files, so we don't depend on broadcasts
            writeCompletionMarkers(extractDir, success, finalMarkerBase);
            
            // Also send broadcast as a fallback/notification mechanism
            Log.d(TAG, "Sending extraction completion broadcast, success=" + success);
            Intent broadcast = new Intent(ACTION_EXTRACTION_COMPLETE);
            broadcast.putExtra("success", success);
            broadcast.putExtra("zip_path", zipPath);
            broadcast.putExtra("extract_dir", extractDir);
            broadcast.putExtra("marker_base", finalMarkerBase);
            if (!success) {
                broadcast.putExtra("error", "Extraction failed");
            }
            broadcast.setPackage(getPackageName());
            sendBroadcast(broadcast);
            
            // Stop service
            releaseJob();
            stopForeground(true);
            stopSelf();
        }).start();
    }
    
    private void releaseJob() {
        if (jobTracked) {
            jobTracked = false;
            SleepSaver.jobFinished();
        }
    }

    @Override
    public void onDestroy() {
        releaseJob();
        super.onDestroy();
    }

    /**
     * Derives a unique marker base name from the ZIP filename. This ensures that
     * concurrent extractions into the same output directory (e.g. RetroArch cores)
     * each use their own completion/progress markers instead of overwriting shared
     * marker files.
     */
    private String deriveMarkerBase(String zipPath) {
        if (zipPath == null || zipPath.isEmpty()) {
            return "archive";
        }
        File zipFile = new File(zipPath);
        String name = zipFile.getName();
        // Strip .zip extension if present
        if (name.toLowerCase().endsWith(".zip")) {
            name = name.substring(0, name.length() - 4);
        }
        if (name.isEmpty()) {
            return "archive";
        }
        return name;
    }
    
    private Notification buildNotification(String gameName, int progress) {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Extracting " + gameName)
            .setContentText("Preparing game files...")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(pendingIntent);
        
        if (progress > 0) {
            builder.setProgress(100, progress, false);
        } else {
            builder.setProgress(0, 0, true);
        }
        
        return builder.build();
    }
    
    private void updateNotification(String gameName, int extractedCount, long totalBytes) {
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            Notification notification = buildProgressNotification(gameName, extractedCount, totalBytes);
            manager.notify(NOTIFICATION_ID, notification);
        }
    }
    
    private Notification buildProgressNotification(String gameName, int extractedCount, long totalBytes) {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );
        
        String progressText = extractedCount + " files, " + (totalBytes / 1048576) + " MB";
        
        return new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Extracting " + gameName)
            .setContentText(progressText)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setProgress(0, 0, true)
            .setContentIntent(pendingIntent)
            .build();
    }
    
    /**
     * Extracts ZIP using streaming with memory pressure relief.
     * Runs in this service's own process with separate memory budget.
     */
    private boolean extractZipStreaming(String zipPath, String extractDir, String gameName, String markerBase) {
        Log.d(TAG, "Starting streaming extraction: " + zipPath + " -> " + extractDir + " (markerBase=" + markerBase + ")");

        ZipInputStream zis = null;
        InputStream fis = null;
        byte[] buffer = new byte[131072]; // 128KB buffer for better throughput
        int extractedCount = 0;
        int totalFiles = 0;
        long totalBytes = 0;
        long extractedBytes = 0;
        long totalUncompressedBytes = 0;
        boolean totalEstimated = true;
        String currentFile = "";
        long lastLogTime = System.currentTimeMillis();
        long lastProgressWrite = System.currentTimeMillis();

        try {
            if (!ensureDir(extractDir)) {
                Log.e(TAG, "Could not create extraction directory: " + extractDir);
                return false;
            }
            File destDir = new File(extractDir);
            
            // Count total files and uncompressed size first using ZipFile (random access, doesn't stream)
            try {
                ZipFile zipFile = new ZipFile(zipPath);
                Enumeration<? extends ZipEntry> entries = zipFile.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    if (!entry.isDirectory()) {
                        totalFiles++;
                        long size = entry.getSize();
                        if (size > 0) {
                            totalUncompressedBytes += size;
                        }
                    }
                }
                zipFile.close();
                totalEstimated = false;
                Log.d(TAG, "Total files to extract: " + totalFiles + ", uncompressed bytes: " + totalUncompressedBytes);
            } catch (Exception e) {
                Log.w(TAG, "Could not count total files: " + e.getMessage());
                // Fall back to the compressed zip size as a rough upper bound for progress.
                totalUncompressedBytes = new java.io.File(zipPath).length();
                totalEstimated = true;
            }
            
            // Write an initial progress marker so the host app immediately sees totals.
            writeProgressMarker(extractDir, extractedCount, totalFiles, extractedBytes, totalUncompressedBytes, totalEstimated, currentFile, markerBase);
            
            fis = openInputFor(zipPath);
            if (fis == null) {
                throw new java.io.IOException("Could not open zip: " + zipPath);
            }
            zis = new ZipInputStream(fis);
            
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                String entryName = entry.getName();
                File outputFile = new File(destDir, entryName);

                // Security check: entry must equal the destination dir itself or
                // live strictly beneath it (separator boundary, so a sibling
                // like /a/tmp2 doesn't pass a startsWith("/a/tmp") test).
                String canonicalDest = destDir.getCanonicalPath();
                String canonicalOutput = outputFile.getCanonicalPath();
                if (!canonicalOutput.equals(canonicalDest) && !canonicalOutput.startsWith(canonicalDest + File.separator)) {
                    Log.e(TAG, "ZIP entry tried to escape destination: " + entryName);
                    continue;
                }

                if (entry.isDirectory()) {
                    ensureDir(outputFile.getPath());
                    continue;
                }

                currentFile = entryName;
                File parentDir = outputFile.getParentFile();
                if (parentDir != null && !ensureDir(parentDir.getPath())) {
                    throw new java.io.IOException("Could not create directory: " + parentDir.getPath());
                }

                // Extract with streaming (DocumentsContract for restricted destinations)
                OutputStream fos = null;
                try {
                    fos = openOutputFor(outputFile.getPath());
                    if (fos == null) {
                        throw new java.io.IOException("Could not open output: " + outputFile.getPath());
                    }
                    int count;
                    while ((count = zis.read(buffer)) != -1) {
                        fos.write(buffer, 0, count);
                        extractedBytes += count;
                        
                        // Report byte-level progress mid-entry so archives with a few
                        // very large files still show movement (~1s throttle).
                        long midNow = System.currentTimeMillis();
                        if (midNow - lastProgressWrite > 1000) {
                            writeProgressMarker(extractDir, extractedCount, totalFiles, extractedBytes, totalUncompressedBytes, totalEstimated, currentFile, markerBase);
                            updateNotification(gameName, extractedCount, extractedBytes);
                            lastProgressWrite = midNow;
                        }
                    }
                    fos.flush();
                    
                    if (extractedCount % 100 == 0) {
                        try {
                            fos.flush();
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
                
                // Write progress file every 2 seconds
                long now = System.currentTimeMillis();
                if (now - lastProgressWrite > 2000) {
                    writeProgressMarker(extractDir, extractedCount, totalFiles, extractedBytes, totalUncompressedBytes, totalEstimated, currentFile, markerBase);
                    updateNotification(gameName, extractedCount, extractedBytes);
                    lastProgressWrite = now;
                }
                
                // Log progress every 30 seconds
                if (now - lastLogTime > 30000) {
                    Log.d(TAG, "Extraction progress: " + extractedCount + "/" + totalFiles + " files, " + (extractedBytes / 1048576) + " MB");
                    lastLogTime = now;
                }
                
                // GC every 500 files to prevent memory buildup
                if (extractedCount % 500 == 0) {
                    System.gc();
                }
            }
            
            // Write final progress with the actual extracted total (no longer an estimate).
            writeProgressMarker(extractDir, extractedCount, totalFiles, extractedBytes, extractedBytes, false, currentFile, markerBase);
            Log.d(TAG, "Extraction complete: " + extractedCount + "/" + totalFiles + " files, " + (extractedBytes / 1048576) + " MB");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "Extraction failed: " + e.getMessage());
            e.printStackTrace();
            return false;
        } finally {
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
    
    private void writeProgressMarker(String extractDir, int extractedCount, int totalFiles, long extractedBytes, long totalBytes, boolean totalEstimated, String currentFile, String markerBase) {
        try {
            ensureDir(extractDir);
            writeTextFile(extractDir + "/.extraction_progress_" + markerBase,
                "{\"extracted\":" + extractedCount
                + ",\"total\":" + totalFiles
                + ",\"extracted_bytes\":" + extractedBytes
                + ",\"total_bytes\":" + totalBytes
                + ",\"total_estimated\":" + (totalEstimated ? "true" : "false")
                + ",\"current_file\":\"" + escapeJson(currentFile) + "\"}");
        } catch (Exception e) {
            Log.w(TAG, "Failed to write progress marker", e);
        }
    }
    
    private String escapeJson(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    // ========================================================================
    // Restricted path support (/Android/data/, /Android/obb/ of other apps).
    // Primary: AltAccess — direct File I/O through storage-root symlinks
    // (KyodaiUC/data -> Android/data), which bypasses the FUSE path filter
    // with only MANAGE_EXTERNAL_STORAGE (same trick as argosy-launcher).
    // Fallback: DocumentsContract (persisted SAF tree grant, or manage=true
    // honored for MANAGE_EXTERNAL_STORAGE holders on some ROMs).
    // ========================================================================

    private static final String ALT_ACCESS_DIR = "KyodaiUC";

    private volatile Boolean altAccessSupported = null;

    private boolean isAltAccessSupported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false;
        boolean hasManageStorage = Environment.isExternalStorageManager();
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
            if (hasManageStorage) {
                altAccessSupported = anySupported;
            }
            return anySupported;
        }
    }

    private java.util.List<String> getAltStorageRoots() {
        java.util.List<String> roots = new java.util.ArrayList<>();
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
            return altDir.exists() && dataLink.canRead();
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

    private boolean requiresDocumentsContract(String path) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false;
        return path.contains("/Android/data/") || path.contains("/Android/obb/");
    }

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

    private android.net.Uri applyManagedParameter(android.net.Uri uri, String relativePath) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return uri;
        boolean needsManaged = relativePath.startsWith("Android/data")
                || relativePath.startsWith("Android/obb")
                || relativePath.equals("Android");
        return needsManaged ? uri.buildUpon().appendQueryParameter("manage", "true").build() : uri;
    }

    /** Finds a persisted read+write tree grant whose tree covers the given path. */
    private android.net.Uri treeUriForPath(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String targetDocId = vp[0] + ":" + vp[1];
        for (android.content.UriPermission p : getContentResolver().getPersistedUriPermissions()) {
            if (!p.isReadPermission() || !p.isWritePermission()) continue;
            android.net.Uri uri = p.getUri();
            if (!uri.toString().startsWith("content://" + DOCS_AUTHORITY + "/tree/")) continue;
            try {
                String treeDocId = android.provider.DocumentsContract.getTreeDocumentId(uri);
                if (targetDocId.equals(treeDocId) || targetDocId.startsWith(treeDocId + "/")) {
                    return uri;
                }
            } catch (Exception ignored) {}
        }
        return null;
    }

    private android.net.Uri documentUriFor(String path) {
        String[] vp = splitVolumePath(path);
        if (vp == null) return null;
        String docId = vp[0] + ":" + vp[1];
        android.net.Uri treeUri = treeUriForPath(path);
        if (treeUri != null) {
            try {
                return android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            } catch (Exception e) {
                Log.w(TAG, "buildDocumentUriUsingTree failed: " + e.getMessage());
            }
        }
        return applyManagedParameter(
                android.provider.DocumentsContract.buildDocumentUri(DOCS_AUTHORITY, docId), vp[1]);
    }

    /** Creates a directory (and parents), falling back to DocumentsContract. */
    private boolean ensureDir(String path) {
        File dir = directFile(path);
        if (dir.exists() && dir.isDirectory()) return true;
        if (dir.mkdirs()) return true;

        if (!requiresDocumentsContract(path)) return false;
        return createDirViaSaf(path);
    }

    /**
     * Creates a directory under a granted SAF tree. Only walks/creates segments
     * BELOW the granted tree root — segments at or above it are outside the
     * grant's coverage and would be denied (they already exist anyway).
     */
    private boolean createDirViaSaf(String path) {
        android.net.Uri treeUri = treeUriForPath(path);
        if (treeUri == null) return false;
        String[] vp = splitVolumePath(path);
        if (vp == null) return false;
        String targetDocId = vp[0] + ":" + vp[1];
        String treeDocId;
        try {
            treeDocId = android.provider.DocumentsContract.getTreeDocumentId(treeUri);
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
                    android.net.Uri parentUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDocId);
                    android.provider.DocumentsContract.createDocument(
                            getContentResolver(), parentUri,
                            android.provider.DocumentsContract.Document.MIME_TYPE_DIR, segment);
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

    private boolean safDocExists(android.net.Uri treeUri, String docId) {
        try {
            android.net.Uri docUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
            android.database.Cursor cursor = getContentResolver().query(
                    docUri,
                    new String[]{android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID},
                    null, null, null);
            if (cursor != null) {
                boolean exists = cursor.moveToFirst();
                cursor.close();
                return exists;
            }
        } catch (Exception ignored) {}
        return false;
    }

    /** Opens a truncating write stream: direct File first (AltAccess symlink for
     *  restricted paths), then DocumentsContract with create-if-missing. */
    private OutputStream openOutputFor(String path) throws Exception {
        File file = directFile(path);
        File parent = file.getParentFile();
        if (parent != null && parent.canWrite()) {
            return new FileOutputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            android.net.Uri uri = documentUriFor(path);
            if (uri != null) {
                try {
                    OutputStream out = getContentResolver().openOutputStream(uri, "wt");
                    if (out != null) return out;
                } catch (Exception e) {
                    Log.d(TAG, "openOutputFor: existing doc open failed, creating: " + e.getMessage());
                }
                String parentPath = path.substring(0, path.lastIndexOf('/'));
                String name = path.substring(path.lastIndexOf('/') + 1);
                android.net.Uri parentUri = documentUriFor(parentPath);
                if (parentUri != null) {
                    android.net.Uri created = android.provider.DocumentsContract.createDocument(
                            getContentResolver(), parentUri, "application/octet-stream", name);
                    if (created != null) {
                        return getContentResolver().openOutputStream(created, "wt");
                    }
                }
            }
        }
        return null;
    }

    /** Opens a read stream: direct File first (AltAccess symlink for restricted
     *  paths), then DocumentsContract. */
    private InputStream openInputFor(String path) throws Exception {
        File file = directFile(path);
        if (file.exists() && file.canRead()) {
            return new FileInputStream(file);
        }
        if (requiresDocumentsContract(path)) {
            android.net.Uri uri = documentUriFor(path);
            if (uri != null) {
                return getContentResolver().openInputStream(uri);
            }
        }
        return null;
    }

    private void writeTextFile(String path, String content) throws Exception {
        OutputStream out = openOutputFor(path);
        if (out == null) {
            throw new java.io.IOException("Could not open for write: " + path);
        }
        out.write(content.getBytes("UTF-8"));
        out.flush();
        out.close();
    }
    
    private void writeCompletionMarkers(String extractDir, boolean success, String markerBase) {
        try {
            ensureDir(extractDir);

            // Write success/failure marker FIRST. The completion marker must be
            // last: the Godot poller treats it as "everything is final" and reads
            // the success marker immediately. Under SAF/DocsProvider writes the
            // inter-marker gap is wide enough that the poller could observe
            // completion while the success marker was still missing/empty and
            // misreport a successful extraction as failed.
            writeTextFile(extractDir + "/.extraction_success_" + markerBase, success ? "true" : "false");
            Log.d(TAG, "Wrote success marker: " + extractDir + "/.extraction_success_" + markerBase + " = " + success);

            // Write completion marker (always last)
            writeTextFile(extractDir + "/.extraction_complete_" + markerBase, "complete");
            Log.d(TAG, "Wrote completion marker: " + extractDir + "/.extraction_complete_" + markerBase);
        } catch (Exception e) {
            Log.e(TAG, "Failed to write completion markers", e);
        }
    }
}
