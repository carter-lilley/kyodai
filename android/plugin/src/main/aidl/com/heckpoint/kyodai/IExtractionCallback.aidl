package com.heckpoint.kyodai;

/**
 * AIDL interface for ExtractionService callbacks.
 * Provides guaranteed delivery of extraction completion and progress events.
 */
interface IExtractionCallback {
    /**
     * Called when extraction completes (success or failure)
     */
    void onExtractionComplete(boolean success, String zipPath, String extractDir, String error);
    
    /**
     * Called periodically during extraction with progress updates
     */
    void onExtractionProgress(int progressPercent, int filesExtracted, int totalFiles, long bytesExtracted, String zipPath);
}
