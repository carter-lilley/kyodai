package com.heckpoint.kyodai;

import android.content.Context;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.Charset;
import java.util.concurrent.TimeUnit;

/**
 * Runs shell scripts as root through the vendor daemons shipped on gaming handhelds:
 * AYN/Retroid expose a "PServerBinder" system service; Ayaneo ships /product/bin/xsu.
 * Neither daemon reports a script's exit code and both return only the first line of
 * output, so scripts are written to a file and run through a wrapper that captures
 * full output to a file and echoes the exit code as the last line.
 *
 * Approach ported from argosy-launcher (com.nendo.argosy.util.RootShell/PServerExecutor/
 * XsuExecutor), which uses the same route for LED control and save-folder access.
 */
public final class RootShell {

    public static final class Result {
        public final Integer exitCode;
        public final String output;

        Result(Integer exitCode, String output) {
            this.exitCode = exitCode;
            this.output = output;
        }

        public boolean succeeded() {
            return exitCode != null && exitCode == 0;
        }
    }

    private static final String TAG = "KyodaiBridge";
    private static final String WORK_DIR = "root-shell";
    private static final String SCRIPT_NAME = "root-op.sh";
    private static final String WRAPPER_NAME = "root-run.sh";
    private static final String OUTPUT_NAME = "run-output.txt";

    private static final Object LOCK = new Object();

    private RootShell() {}

    public static boolean isAvailable() {
        return PServer.isAvailable() || Xsu.isAvailable();
    }

    /** Single-string quoting for shell script bodies. */
    public static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    private static String execute(String command) throws Exception {
        if (PServer.isAvailable()) {
            return PServer.execute(command);
        }
        return Xsu.execute(command);
    }

    /**
     * Runs {@code body} as root. Returns null when no vendor daemon exists or the
     * route refused the call. Scripts must be built from fixed strings with
     * {@link #quote(String)} for any path; never interpolate user/ROM-derived text.
     */
    public static Result run(Context context, String body) {
        synchronized (LOCK) {
            if (!isAvailable()) return null;
            try {
                File dir = new File(context.getCacheDir(), WORK_DIR);
                dir.mkdirs();
                dir.setExecutable(true, false);

                File script = new File(dir, SCRIPT_NAME);
                writeText(script, body + "\n");

                File output = new File(dir, OUTPUT_NAME);
                output.delete();

                File wrapper = new File(dir, WRAPPER_NAME);
                writeText(wrapper,
                        "sh " + script.getAbsolutePath() + " > " + output.getAbsolutePath() + " 2>&1\n" +
                        "rc=$?\n" +
                        "chmod 644 " + output.getAbsolutePath() + "\n" +
                        "echo $rc\n");

                script.setReadable(true, false);
                wrapper.setReadable(true, false);

                String exitStr = execute("sh " + wrapper.getAbsolutePath());
                Integer exit = null;
                if (exitStr != null) {
                    try {
                        exit = Integer.parseInt(exitStr.trim());
                    } catch (NumberFormatException ignored) {}
                }
                String out = output.canRead() ? readAll(output) : "";
                return new Result(exit, out);
            } catch (Exception e) {
                Log.w(TAG, "root shell failed: " + e.getMessage());
                return null;
            }
        }
    }

    private static void writeText(File file, String text) throws Exception {
        FileOutputStream fos = new FileOutputStream(file);
        try {
            fos.write(text.getBytes(Charset.forName("UTF-8")));
        } finally {
            fos.close();
        }
    }

    private static String readAll(File file) throws Exception {
        FileInputStream fis = new FileInputStream(file);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = fis.read(buf)) != -1) {
                bos.write(buf, 0, n);
            }
            return bos.toString("UTF-8");
        } finally {
            fis.close();
        }
    }

    /** AYN/Retroid: root command execution via the PServerBinder system service. */
    static final class PServer {
        private static IBinder binder;
        private static boolean probed = false;
        private static Boolean callWorks = null;

        static synchronized boolean isAvailable() {
            // A registered binder whose host process died stays listed by
            // ServiceManager; treat dead binders as unavailable and re-resolve,
            // so a restarted host is picked up.
            if (binder != null && !binder.isBinderAlive()) {
                binder = null;
                probed = false;
                callWorks = null;
            }
            if (!probed) {
                probed = true;
                try {
                    Class<?> serviceManager = Class.forName("android.os.ServiceManager");
                    binder = (IBinder) serviceManager
                            .getDeclaredMethod("getService", String.class)
                            .invoke(null, "PServerBinder");
                } catch (Throwable t) {
                    binder = null;
                }
            }
            if (binder == null || !binder.isBinderAlive()) {
                return false;
            }
            // A live binder is not enough: stock AYN Android 13 SELinux
            // hard-denies untrusted_app -> pservice binder calls (the
            // ServiceManager lookup alone is permissive). Probe with a real
            // transaction once per process.
            if (callWorks == null) {
                boolean ok = false;
                try {
                    String out = transact("id");
                    ok = out != null && out.contains("uid=0");
                } catch (Throwable t) {
                    ok = false;
                }
                callWorks = ok;
                if (!ok) {
                    Log.i(TAG, "PServerBinder present but calls are denied (SELinux); root daemon unusable");
                }
            }
            return callWorks;
        }

        /** The daemon returns only the first line of command output. */
        static String execute(String cmd) throws Exception {
            if (!isAvailable()) {
                throw new IllegalStateException("PServerBinder not available");
            }
            return transact(cmd);
        }

        private static String transact(String cmd) throws Exception {
            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                data.writeStringArray(new String[]{cmd, "1"});
                boolean transacted = binder.transact(0, data, reply, 0);
                if (!transacted) {
                    throw new IllegalStateException("PServerBinder rejected transaction");
                }
                byte[] bytes = reply.createByteArray();
                if (bytes == null) return null;
                String result = new String(bytes, Charset.defaultCharset()).trim();
                return "null".equals(result) ? null : result;
            } finally {
                data.recycle();
                reply.recycle();
            }
        }
    }

    /** Ayaneo: root via the vendor /product/bin/xsu binary (always exits 0). */
    static final class Xsu {
        private static final String XSU_PATH = "/product/bin/xsu";
        private static final String ROOT_UID_MARKER = "uid=0(";
        private static Boolean available = null;

        static synchronized boolean isAvailable() {
            if (available == null) {
                boolean ok = false;
                try {
                    if (new File(XSU_PATH).canExecute()) {
                        String out = execute("id");
                        ok = out != null && out.contains(ROOT_UID_MARKER);
                    }
                } catch (Throwable t) {
                    ok = false;
                }
                available = ok;
            }
            return available;
        }

        static String execute(String command) throws Exception {
            Process process = new ProcessBuilder(XSU_PATH, command)
                    .redirectErrorStream(true)
                    .start();
            String out = readAll(process.getInputStream());
            if (!process.waitFor(30, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                throw new IllegalStateException("xsu timed out");
            }
            return out;
        }

        private static String readAll(java.io.InputStream in) throws Exception {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                bos.write(buf, 0, n);
            }
            return bos.toString("UTF-8");
        }
    }
}
