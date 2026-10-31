package com.heckpoint.kyodai.task;

import android.content.Context;

import com.heckpoint.kyodai.RootShell;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Full tier backed by a fresh privileged app_process invocation per request. */
public final class VendorTaskBackend implements AndroidTaskBackend {
    private static final int PROTOCOL = 1;
    private final Context context;

    public VendorTaskBackend(Context context) {
        this.context = context.getApplicationContext();
    }

    @Override
    public Capabilities probeCapabilities() throws TaskBackendException {
        if (!RootShell.isAvailable()) return new Capabilities();
        try {
            JSONObject result = execute("probe", new JSONObject());
            return capabilitiesFrom(result.getJSONObject("capabilities"));
        } catch (JSONException e) {
            throw new TaskBackendException("invalid_response", e.toString());
        }
    }

    @Override
    public List<TaskInfo> listTasks() throws TaskBackendException {
        try {
            JSONObject result = execute("list", new JSONObject());
            List<TaskInfo> tasks = new ArrayList<>();
            JSONArray array = result.getJSONArray("tasks");
            for (int i = 0; i < array.length(); i++) {
                tasks.add(taskFrom(array.getJSONObject(i)));
            }
            return tasks;
        } catch (JSONException e) {
            throw new TaskBackendException("invalid_response", e.toString());
        }
    }

    @Override
    public Result captureTaskSnapshot(int taskId, String packageName, String topActivity) throws TaskBackendException {
        return operation("snapshot", taskId, packageName, topActivity, -1, -1);
    }

    @Override
    public Result focusTask(int taskId, String packageName, String topActivity) throws TaskBackendException {
        return operation("focus", taskId, packageName, topActivity, -1, -1);
    }

    @Override
    public Result forceStopPackage(int taskId, String packageName, int userId) throws TaskBackendException {
        return operation("force_stop", taskId, packageName, "", userId, -1);
    }

    @Override
    public Result removeTask(int taskId, String packageName) throws TaskBackendException {
        return operation("remove_task", taskId, packageName, "", -1, -1);
    }

    @Override
    public Result moveTaskToDisplay(int taskId, String packageName, int displayId) throws TaskBackendException {
        return operation("move_display", taskId, packageName, "", -1, displayId);
    }

    private Result operation(String op, int taskId, String packageName, String topActivity,
                             int userId, int displayId) throws TaskBackendException {
        if (taskId <= 0) throw new TaskBackendException("invalid_request", "Invalid task ID");
        if (packageName == null || packageName.isEmpty()) {
            throw new TaskBackendException("invalid_request", "Expected package identity required");
        }
        if ("force_stop".equals(op) && userId < 0) {
            throw new TaskBackendException("invalid_request", "Expected user/profile identity required");
        }
        if ("move_display".equals(op) && displayId < 0) {
            throw new TaskBackendException("invalid_request", "Invalid display ID");
        }
        try {
            JSONObject expected = new JSONObject();
            expected.put("taskId", taskId);
            if (packageName != null && !packageName.isEmpty()) expected.put("packageName", packageName);
            if (topActivity != null && !topActivity.isEmpty()) expected.put("topActivity", topActivity);
            if (userId >= 0) expected.put("userId", userId);
            if (displayId >= 0) expected.put("displayId", displayId);
            JSONObject result = execute(op, expected);
            Result converted = resultFrom(result);
            if (!converted.ok) {
                throw new TaskBackendException(converted.code, converted.error);
            }
            return converted;
        } catch (JSONException e) {
            throw new TaskBackendException("invalid_response", e.toString());
        }
    }

    private JSONObject execute(String op, JSONObject expected) throws TaskBackendException {
        if (!RootShell.isAvailable()) {
            throw new TaskBackendException("unsupported", "Enhanced device access is unavailable on this firmware");
        }
        File dir = null;
        try {
            String nonce = UUID.randomUUID().toString();
            dir = new File(context.getFilesDir(), "task-requests/" + nonce);
            if (!dir.mkdirs() && !dir.isDirectory()) {
                throw new TaskBackendException("io_error", "Could not create task request directory");
            }
            JSONObject request = new JSONObject();
            request.put("protocol", PROTOCOL);
            request.put("op", op);
            request.put("nonce", nonce);
            request.put("expected", expected);
            writeText(new File(dir, "request.json"), request.toString());

            String command = "CLASSPATH=" + RootShell.quote(context.getApplicationInfo().sourceDir)
                    + " /system/bin/app_process /system/bin com.heckpoint.kyodai.task.PrivilegedTaskHelper "
                    + RootShell.quote(dir.getAbsolutePath());
            RootShell.Result shell = RootShell.run(context, command);
            if (shell == null) {
                throw new TaskBackendException("unavailable", "Privileged task helper did not run");
            }
            if ("timeout".equals(shell.output)) {
                throw new TaskBackendException("timeout", "Privileged task helper timed out");
            }
            File resultFile = new File(dir, "result.json");
            if (!resultFile.isFile()) {
                throw new TaskBackendException("invalid_response",
                        shell.output == null || shell.output.isEmpty() ? "No helper result" : shell.output);
            }
            JSONObject result = new JSONObject(readText(resultFile));
            if (!nonce.equals(result.optString("nonce", ""))) {
                throw new TaskBackendException("invalid_response", "Stale helper response");
            }
            if (!result.optBoolean("ok", false)) {
                throw new TaskBackendException(result.optString("code", "unknown"),
                        result.optString("error", "Task operation failed"));
            }
            return result;
        } catch (TaskBackendException e) {
            throw e;
        } catch (Exception e) {
            throw new TaskBackendException("invalid_response", e.toString());
        } finally {
            if (dir != null) {
                if ("snapshot".equals(op)) {
                    pruneTaskRequests();
                } else {
                    deleteRecursively(dir);
                }
            }
        }
    }

    private void pruneTaskRequests() {
        File root = new File(context.getFilesDir(), "task-requests");
        File[] directories = root.listFiles();
        if (directories == null) return;
        java.util.Arrays.sort(directories, (a, b) -> Long.compare(b.lastModified(), a.lastModified()));
        for (int i = 8; i < directories.length; i++) deleteRecursively(directories[i]);
    }

    private static void deleteRecursively(File file) {
        if (file == null || !file.exists()) return;
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) deleteRecursively(child);
        }
        file.delete();
    }

    private Capabilities capabilitiesFrom(JSONObject value) throws JSONException {
        Capabilities caps = new Capabilities();
        caps.privileged = value.optBoolean("privileged", false);
        caps.listTasks = value.optBoolean("listTasks", false);
        caps.snapshots = value.optBoolean("snapshots", false);
        caps.focus = value.optBoolean("focus", false);
        caps.forceStop = value.optBoolean("forceStop", false);
        caps.removeTask = value.optBoolean("removeTask", false);
        caps.moveDisplay = value.optBoolean("moveDisplay", false);
        return caps;
    }

    private Result resultFrom(JSONObject value) throws JSONException {
        Result result = new Result();
        result.ok = value.optBoolean("ok", false);
        result.code = value.optString("code", result.ok ? "ok" : "unknown");
        result.nonce = value.optString("nonce", "");
        result.error = value.optString("error", "");
        JSONObject task = value.optJSONObject("task");
        if (task != null) result.task = taskFrom(task);
        JSONObject snapshot = value.optJSONObject("snapshot");
        if (snapshot != null) {
            result.snapshotPath = snapshot.optString("path", "");
            result.snapshotWidth = snapshot.optInt("width", 0);
            result.snapshotHeight = snapshot.optInt("height", 0);
            result.realSnapshot = snapshot.optBoolean("real", false);
        }
        return result;
    }

    private TaskInfo taskFrom(JSONObject value) throws JSONException {
        TaskInfo task = new TaskInfo();
        task.taskId = value.getInt("taskId");
        task.packageName = value.optString("packageName", "");
        task.topActivity = value.optString("topActivity", "");
        task.baseActivity = value.optString("baseActivity", "");
        task.displayId = value.optInt("displayId", 0);
        task.userId = value.optInt("userId", 0);
        task.visible = value.optBoolean("visible", false);
        return task;
    }

    private static void writeText(File file, String text) throws Exception {
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
    }

    private static String readText(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            int offset = 0;
            while (offset < bytes.length) {
                int read = in.read(bytes, offset, bytes.length - offset);
                if (read < 0) break;
                offset += read;
            }
            return new String(bytes, 0, offset, StandardCharsets.UTF_8);
        }
    }
}
