package com.heckpoint.kyodai.task;

import android.app.ActivityManager;
import android.graphics.Bitmap;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.os.IBinder;
import android.os.Process;
import android.os.SystemClock;
import android.view.SurfaceControl;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Entry point executed by app_process through the vendor privilege bridge. */
public final class PrivilegedTaskHelper {
    private static final int PROTOCOL = 1;

    private JSONObject request;
    private JSONObject expected;
    private File requestDir;
    private String nonce;

    public static void main(String[] args) {
        PrivilegedTaskHelper helper = new PrivilegedTaskHelper();
        boolean homeCurtain = args.length == 2 && "--home-curtain".equals(args[1]);
        try {
            if (args.length != 1 && !homeCurtain) {
                throw new Exception("invalid_request", new Exception("Expected request directory"));
            }
            helper.requestDir = new File(args[0]).getCanonicalFile();
            helper.readRequest();
            helper.requirePrivileged();
            if (homeCurtain) {
                helper.runHomeCurtain();
            } else {
                helper.execute();
            }
        } catch (Throwable t) {
            if (!homeCurtain) helper.writeFailure(t);
        }
    }

    private void readRequest() throws Exception {
        String text = readText(new File(requestDir, "request.json"));
        request = new JSONObject(text);
        if (request.optInt("protocol", -1) != PROTOCOL) {
            throw new Exception("invalid_request", new Exception("Unsupported protocol"));
        }
        nonce = request.getString("nonce");
        if (nonce.isEmpty() || nonce.length() > 80 || nonce.contains("..")) {
            throw new Exception("invalid_request", new Exception("Invalid nonce"));
        }
        expected = request.optJSONObject("expected");
        if (expected == null) expected = new JSONObject();
    }

    private void requirePrivileged() throws Exception {
        int uid = Process.myUid();
        // UID 2000 is accepted only to make direct on-device helper diagnostics
        // possible. VendorTaskBackend still requires UID 0 for the full tier.
        if (uid != 0 && uid != 2000) {
            throw new Exception("denied", new Exception("Privileged helper identity required"));
        }
    }

    private void execute() throws Exception {
        String op = request.getString("op");
        switch (op) {
            case "probe": probe(); break;
            case "list": list(); break;
            case "snapshot": snapshot(); break;
            case "focus": focus(); break;
            case "force_stop": forceStop(); break;
            case "remove_task": removeTask(); break;
            case "move_display": moveDisplay(); break;
            default: throw new Exception("invalid_request", new Exception("Unknown operation"));
        }
    }

    private void probe() throws Exception {
        JSONObject caps = new JSONObject();
        caps.put("privileged", Process.myUid() == 0);
        caps.put("listTasks", hasTaskManagerMethod("getTasks"));
        caps.put("snapshots", hasTaskSnapshotSignature());
        caps.put("focus", hasTaskManagerMethod("setFocusedTask"));
        caps.put("forceStop", hasActivityManagerMethod("forceStopPackage"));
        caps.put("removeTask", hasTaskManagerMethod("removeTask"));
        caps.put("moveDisplay", hasTaskManagerMethod("moveRootTaskToDisplay"));
        JSONObject result = baseResult();
        result.put("capabilities", caps);
        writeResult(result);
    }

    private void list() throws Exception {
        JSONArray tasks = new JSONArray();
        for (ActivityManager.RunningTaskInfo info : getTasks()) {
            tasks.put(taskJson(info));
        }
        JSONObject result = baseResult();
        result.put("tasks", tasks);
        writeResult(result);
    }

    private void snapshot() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        Object snapshot = getTaskSnapshot(taskId);
        if (snapshot == null) throw new Exception("capture_failed", new Exception("No task snapshot"));
        HardwareBuffer buffer = (HardwareBuffer) snapshot.getClass().getMethod("getHardwareBuffer").invoke(snapshot);
        if (buffer == null) throw new Exception("capture_failed", new Exception("Empty snapshot buffer"));
        ColorSpace colorSpace = (ColorSpace) snapshot.getClass().getMethod("getColorSpace").invoke(snapshot);
        boolean real = (boolean) snapshot.getClass().getMethod("isRealSnapshot").invoke(snapshot);
        Bitmap bitmap = Bitmap.wrapHardwareBuffer(buffer, colorSpace);
        if (bitmap == null) throw new Exception("capture_failed", new Exception("Could not wrap snapshot"));
        File output = new File(requestDir, "frame.jpg");
        writeJpeg(bitmap, output);
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        JSONObject image = new JSONObject();
        image.put("path", output.getAbsolutePath());
        image.put("width", bitmap.getWidth());
        image.put("height", bitmap.getHeight());
        image.put("real", real);
        result.put("snapshot", image);
        result.put("homeCurtain", spawnHomeCurtain());
        writeResult(result);
    }

    private boolean spawnHomeCurtain() {
        try {
            ProcessBuilder builder = new ProcessBuilder(
                    "/system/bin/app_process", "/system/bin",
                    PrivilegedTaskHelper.class.getName(), requestDir.getAbsolutePath(), "--home-curtain");
            builder.redirectErrorStream(true);
            builder.redirectOutput(new File("/dev/null"));
            builder.start();
            // Do not let GDScript start updating behind the curtain until the
            // child has a real SurfaceFlinger layer on screen.
            File ready = new File(requestDir, "curtain-ready");
            long deadline = SystemClock.uptimeMillis() + 300;
            while (SystemClock.uptimeMillis() < deadline) {
                if (ready.isFile()) return true;
                SystemClock.sleep(20);
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private void runHomeCurtain() throws Exception {
        int taskId = requireTaskId();
        requireTask(taskId);
        SurfaceControl curtain = showResumeCurtain(taskId);
        if (curtain == null) return;
        try {
            try (FileOutputStream ready = new FileOutputStream(new File(requestDir, "curtain-ready"))) {
                ready.write("1".getBytes(StandardCharsets.UTF_8));
            }
            File release = new File(requestDir, "release-curtain");
            long deadline = SystemClock.uptimeMillis() + 5000;
            while (!release.isFile() && SystemClock.uptimeMillis() < deadline) {
                SystemClock.sleep(40);
            }
        } finally {
            hideResumeCurtain(curtain);
        }
    }

    private void focus() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        SurfaceControl curtain = showResumeCurtain(taskId);
        try {
            taskManager().getClass().getMethod("setFocusedTask", int.class).invoke(taskManager(), taskId);
            // Cover the OS task-slide and the first frames of the resumed game.
            // This is a real SurfaceFlinger layer, not an in-app fake PiP view.
            SystemClock.sleep(650);
        } finally {
            hideResumeCurtain(curtain);
        }
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        result.put("curtain", curtain != null);
        writeResult(result);
    }

    private SurfaceControl showResumeCurtain(int taskId) {
        try {
            Object snapshot = getTaskSnapshot(taskId);
            if (snapshot == null) return null;
            HardwareBuffer buffer = (HardwareBuffer) snapshot.getClass().getMethod("getHardwareBuffer").invoke(snapshot);
            if (buffer == null) return null;
            try {
                SurfaceControl curtain = new SurfaceControl.Builder()
                        .setName("KyodaiResumeCurtain")
                        .setBufferSize(buffer.getWidth(), buffer.getHeight())
                        .setOpaque(true)
                        .build();
                SurfaceControl.Transaction transaction = new SurfaceControl.Transaction();
                transaction.setBuffer(curtain, buffer)
                        .setPosition(curtain, 0, 0)
                        .setLayer(curtain, Integer.MAX_VALUE)
                        .setVisibility(curtain, true)
                        .apply();
                return curtain;
            } finally {
                buffer.close();
            }
        } catch (Throwable ignored) {
            return null; // curtain is best-effort; task focus must still work
        }
    }

    private void hideResumeCurtain(SurfaceControl curtain) {
        if (curtain == null) return;
        try {
            new SurfaceControl.Transaction()
                    .setVisibility(curtain, false)
                    .apply();
        } catch (Throwable ignored) {
        } finally {
            curtain.release();
        }
    }

    private void forceStop() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        if (requiredBooleanField(info, "isVisible")) throw new Exception("unsafe_operation", new Exception("Refusing to close a visible game"));
        String packageName = expectedPackage(info);
        int userId = expected.getInt("userId");
        int taskUserId = requiredIntField(info, "userId");
        if (userId != taskUserId) {
            throw new Exception("stale_task", new Exception("Task user/profile changed"));
        }
        activityManager().getClass().getMethod("forceStopPackage", String.class, int.class)
                .invoke(activityManager(), packageName, userId);
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private void removeTask() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        boolean removed = (boolean) taskManager().getClass().getMethod("removeTask", int.class)
                .invoke(taskManager(), taskId);
        if (!removed) throw new Exception("stale_task", new Exception("Task could not be removed"));
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private void moveDisplay() throws Exception {
        int taskId = requireTaskId();
        ActivityManager.RunningTaskInfo info = requireTask(taskId);
        int displayId = expected.getInt("displayId");
        if (displayId < 0) throw new Exception("invalid_request", new Exception("Invalid display"));
        taskManager().getClass().getMethod("moveRootTaskToDisplay", int.class, int.class)
                .invoke(taskManager(), taskId, displayId);
        JSONObject result = baseResult();
        result.put("task", taskJson(info));
        writeResult(result);
    }

    private int requireTaskId() throws Exception {
        int taskId = expected.getInt("taskId");
        if (taskId <= 0) throw new Exception("invalid_request", new Exception("Invalid task ID"));
        return taskId;
    }

    private ActivityManager.RunningTaskInfo requireTask(int taskId) throws Exception {
        for (ActivityManager.RunningTaskInfo info : getTasks()) {
            if (info.taskId != taskId) continue;
            String expectedPackage = expected.optString("packageName", "");
            if (expectedPackage.isEmpty()) {
                throw new Exception("invalid_request", new Exception("Expected package identity required"));
            }
            String top = info.topActivity == null ? "" : info.topActivity.getClassName();
            if (info.topActivity == null || !expectedPackage.equals(info.topActivity.getPackageName())) {
                throw new Exception("stale_task", new Exception("Task package changed"));
            }
            // topActivity is informational and may change as the emulator
            // navigates. Stable task/package identity is validated above.
            // The returned metadata always reflects the current top activity.
            return info;
        }
        throw new Exception("stale_task", new Exception("Task no longer exists"));
    }

    private String expectedPackage(ActivityManager.RunningTaskInfo info) throws Exception {
        String value = expected.optString("packageName", "");
        if (!value.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+")) {
            throw new Exception("invalid_request", new Exception("Invalid package name"));
        }
        if (info.topActivity != null && !value.equals(info.topActivity.getPackageName())) {
            throw new Exception("stale_task", new Exception("Task package changed"));
        }
        return value;
    }

    @SuppressWarnings("unchecked")
    private List<ActivityManager.RunningTaskInfo> getTasks() throws Exception {
        Object manager = taskManager();
        try {
            return (List<ActivityManager.RunningTaskInfo>) manager.getClass()
                    .getMethod("getTasks", int.class, boolean.class, boolean.class, int.class)
                    .invoke(manager, 64, false, false, -1);
        } catch (NoSuchMethodException ignored) {
            return (List<ActivityManager.RunningTaskInfo>) manager.getClass()
                    .getMethod("getTasks", int.class, boolean.class, boolean.class)
                    .invoke(manager, 64, false, false);
        }
    }

    private Object getTaskSnapshot(int taskId) throws Exception {
        Object manager = taskManager();
        try {
            return manager.getClass().getMethod("getTaskSnapshot", int.class, boolean.class)
                    .invoke(manager, taskId, false);
        } catch (NoSuchMethodException ignored) {
            return manager.getClass().getMethod("getTaskSnapshot", int.class, boolean.class, boolean.class)
                    .invoke(manager, taskId, false, false);
        }
    }

    private boolean hasTaskSnapshotSignature() {
        try {
            Class<?> type = Class.forName("android.app.IActivityTaskManager");
            type.getMethod("getTaskSnapshot", int.class, boolean.class);
            return true;
        } catch (Throwable ignored) {
            try {
                Class.forName("android.app.IActivityTaskManager")
                        .getMethod("getTaskSnapshot", int.class, boolean.class, boolean.class);
                return true;
            } catch (Throwable ignoredAgain) {
                return false;
            }
        }
    }

    private Object taskManager() throws Exception {
        return binder("activity_task", "android.app.IActivityTaskManager$Stub");
    }

    private Object activityManager() throws Exception {
        return binder("activity", "android.app.IActivityManager$Stub");
    }

    private Object binder(String name, String stub) throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManager.getMethod("getService", String.class).invoke(null, name);
        if (binder == null || !binder.isBinderAlive()) throw new Exception("unavailable", new Exception(name));
        return Class.forName(stub).getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    private boolean hasTaskManagerMethod(String name) {
        return hasMethod("android.app.IActivityTaskManager", name);
    }

    private boolean hasActivityManagerMethod(String name) {
        return hasMethod("android.app.IActivityManager", name);
    }

    private boolean hasMethod(String className, String name) {
        try {
            for (Method method : Class.forName(className).getMethods()) {
                if (method.getName().equals(name)) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

    private JSONObject taskJson(ActivityManager.RunningTaskInfo info) throws JSONException {
        JSONObject out = new JSONObject();
        out.put("taskId", info.taskId);
        out.put("packageName", info.topActivity == null ? "" : info.topActivity.getPackageName());
        out.put("topActivity", info.topActivity == null ? "" : info.topActivity.getClassName());
        out.put("baseActivity", info.baseActivity == null ? "" : info.baseActivity.flattenToShortString());
        out.put("displayId", intField(info, "displayId", 0));
        out.put("userId", intField(info, "userId", 0));
        out.put("visible", booleanField(info, "isVisible", false));
        return out;
    }

    private int intField(Object object, String name, int fallback) {
        try {
            Field field = object.getClass().getField(name);
            return field.getInt(object);
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    private boolean booleanField(Object object, String name, boolean fallback) {
        try {
            Field field = object.getClass().getField(name);
            return field.getBoolean(object);
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    private int requiredIntField(Object object, String name) throws Exception {
        try {
            Field field = object.getClass().getField(name);
            return field.getInt(object);
        } catch (Throwable t) {
            throw new Exception("unsupported", new Exception("Could not verify task " + name));
        }
    }

    private boolean requiredBooleanField(Object object, String name) throws Exception {
        try {
            Field field = object.getClass().getField(name);
            return field.getBoolean(object);
        } catch (Throwable t) {
            throw new Exception("unsafe_operation", new Exception("Could not verify task visibility"));
        }
    }

    private JSONObject baseResult() throws JSONException {
        JSONObject result = new JSONObject();
        result.put("ok", true);
        result.put("code", "ok");
        result.put("nonce", nonce);
        return result;
    }

    private void writeFailure(Throwable throwable) {
        try {
            while (throwable instanceof InvocationTargetException
                    && ((InvocationTargetException) throwable).getTargetException() != null) {
                throwable = ((InvocationTargetException) throwable).getTargetException();
            }
            String code;
            if (throwable instanceof SecurityException) code = "denied";
            else if (throwable instanceof NoSuchMethodException) code = "unsupported";
            else {
                String message = throwable.getMessage();
                switch (message == null ? "" : message) {
                    case "invalid_request":
                    case "stale_task":
                    case "capture_failed":
                    case "unsafe_operation":
                    case "io_error":
                    case "unavailable":
                        code = message;
                        break;
                    default:
                        code = "unknown";
                }
            }
            JSONObject result = new JSONObject();
            result.put("ok", false);
            result.put("code", code);
            result.put("nonce", nonce == null ? "" : nonce);
            result.put("error", throwable.toString());
            if (requestDir != null) writeResult(result);
        } catch (Throwable ignored) {}
    }

    private void writeResult(JSONObject result) throws Exception {
        writeJsonAtomic(new File(requestDir, "result.json"), result);
    }

    private void writeJsonAtomic(File output, JSONObject value) throws Exception {
        File tmp = new File(output.getParentFile(), output.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(value.toString().getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        }
        tmp.setReadable(true, false);
        if (!tmp.renameTo(output)) throw new Exception("io_error", new Exception("Could not publish result"));
    }

    private void writeJpeg(Bitmap bitmap, File output) throws Exception {
        File tmp = new File(output.getParentFile(), output.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)) {
                throw new Exception("capture_failed", new Exception("JPEG encoding failed"));
            }
            out.getFD().sync();
        }
        tmp.setReadable(true, false);
        if (!tmp.renameTo(output)) throw new Exception("io_error", new Exception("Could not publish frame"));
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
