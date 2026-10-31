package com.heckpoint.kyodai.task;

import java.util.List;

/** Explicit standard tier: no privileged task operations are exposed. */
public final class PublicTaskBackend implements AndroidTaskBackend {
    @Override
    public Capabilities probeCapabilities() {
        return new Capabilities();
    }

    @Override
    public List<TaskInfo> listTasks() throws TaskBackendException {
        throw unsupported();
    }

    @Override
    public Result captureTaskSnapshot(int taskId, String packageName, String topActivity) throws TaskBackendException {
        throw unsupported();
    }

    @Override
    public Result focusTask(int taskId, String packageName, String topActivity) throws TaskBackendException {
        throw unsupported();
    }

    @Override
    public Result forceStopPackage(int taskId, String packageName, int userId) throws TaskBackendException {
        throw unsupported();
    }

    @Override
    public Result removeTask(int taskId, String packageName) throws TaskBackendException {
        throw unsupported();
    }

    @Override
    public Result moveTaskToDisplay(int taskId, String packageName, int displayId) throws TaskBackendException {
        throw unsupported();
    }

    private TaskBackendException unsupported() {
        return new TaskBackendException("unsupported", "Enhanced device access is unavailable on this firmware");
    }
}
