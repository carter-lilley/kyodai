package com.heckpoint.kyodai.task;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.List;

/** Platform-independent contract for Android task/session operations. */
public interface AndroidTaskBackend {
    final class Capabilities {
        public boolean privileged;
        public boolean listTasks;
        public boolean snapshots;
        public boolean focus;
        public boolean forceStop;
        public boolean removeTask;
        public boolean moveDisplay;

        public boolean retainedSessionsSupported() {
            return privileged && listTasks && focus && forceStop && removeTask;
        }

        public JSONObject toJson() throws JSONException {
            JSONObject out = new JSONObject();
            out.put("privileged", privileged);
            out.put("listTasks", listTasks);
            out.put("snapshots", snapshots);
            out.put("focus", focus);
            out.put("forceStop", forceStop);
            out.put("removeTask", removeTask);
            out.put("moveDisplay", moveDisplay);
            out.put("retainedSessions", retainedSessionsSupported());
            return out;
        }
    }

    final class TaskInfo {
        public int taskId = -1;
        public String packageName = "";
        public String topActivity = "";
        public String baseActivity = "";
        public int displayId = 0;
        public int userId = 0;
        public boolean visible;

        public JSONObject toJson() throws JSONException {
            JSONObject out = new JSONObject();
            out.put("taskId", taskId);
            out.put("packageName", packageName);
            out.put("topActivity", topActivity);
            out.put("baseActivity", baseActivity);
            out.put("displayId", displayId);
            out.put("userId", userId);
            out.put("visible", visible);
            return out;
        }
    }

    final class Result {
        public boolean ok;
        public String code = "unknown";
        public String nonce = "";
        public String error = "";
        public TaskInfo task;
        public String snapshotPath = "";
        public int snapshotWidth;
        public int snapshotHeight;
        public boolean realSnapshot;

        public static Result failure(String code, String error) {
            Result result = new Result();
            result.code = code;
            result.error = error;
            return result;
        }

        public JSONObject toJson() throws JSONException {
            JSONObject out = new JSONObject();
            out.put("ok", ok);
            out.put("code", code);
            out.put("nonce", nonce);
            if (task != null) out.put("task", task.toJson());
            if (!snapshotPath.isEmpty()) {
                JSONObject snapshot = new JSONObject();
                snapshot.put("path", snapshotPath);
                snapshot.put("width", snapshotWidth);
                snapshot.put("height", snapshotHeight);
                snapshot.put("real", realSnapshot);
                out.put("snapshot", snapshot);
            }
            if (!error.isEmpty()) out.put("error", error);
            return out;
        }
    }

    final class TaskBackendException extends Exception {
        public final String code;

        public TaskBackendException(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    Capabilities probeCapabilities() throws TaskBackendException;
    List<TaskInfo> listTasks() throws TaskBackendException;
    Result captureTaskSnapshot(int taskId, String packageName, String topActivity) throws TaskBackendException;
    Result focusTask(int taskId, String packageName, String topActivity) throws TaskBackendException;
    Result forceStopPackage(int taskId, String packageName, int userId) throws TaskBackendException;
    Result removeTask(int taskId, String packageName) throws TaskBackendException;
    Result moveTaskToDisplay(int taskId, String packageName, int displayId) throws TaskBackendException;
}
