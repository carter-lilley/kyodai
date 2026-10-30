package com.heckpoint.kyodai;

import android.util.Base64;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Bounded, session-based streaming for restricted-path file I/O. Keeps the
 * underlying stream (and its AssetFileDescriptor, when present) open across
 * calls so large files never make a whole-file base64/JNI round trip.
 */
final class SafStreams {
    static final int DEFAULT_CHUNK_BYTES = 1024 * 1024;
    private static final int MAX_CHUNK_BYTES = 4 * 1024 * 1024;

    static final class Session {
        final String path;
        final InputStream input;
        final OutputStream output;
        final File rootStaging;
        boolean failed;

        Session(String path, InputStream input, OutputStream output, File rootStaging) {
            this.path = path;
            this.input = input;
            this.output = output;
            this.rootStaging = rootStaging;
        }
    }

    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);
    private static final ConcurrentHashMap<Integer, Session> SESSIONS = new ConcurrentHashMap<>();

    private SafStreams() {}

    static int openRead(String path, InputStream input) {
        int id = NEXT_ID.getAndIncrement();
        SESSIONS.put(id, new Session(path, input, null, null));
        return id;
    }

    static int openWrite(String path, OutputStream output, File rootStaging) {
        int id = NEXT_ID.getAndIncrement();
        SESSIONS.put(id, new Session(path, null, output, rootStaging));
        return id;
    }

    /** Returns null on error, an empty string on EOF, or a base64 chunk. */
    static String readChunk(int id, int maxBytes) {
        Session session = SESSIONS.get(id);
        if (session == null || session.input == null) return null;
        int size = Math.max(1, Math.min(maxBytes, MAX_CHUNK_BYTES));
        try {
            byte[] buffer = new byte[size];
            int read = session.input.read(buffer);
            if (read < 0) return "";
            if (read == buffer.length) {
                return Base64.encodeToString(buffer, Base64.NO_WRAP);
            }
            byte[] chunk = new byte[read];
            System.arraycopy(buffer, 0, chunk, 0, read);
            return Base64.encodeToString(chunk, Base64.NO_WRAP);
        } catch (Exception e) {
            session.failed = true;
            return null;
        }
    }

    static boolean writeChunk(int id, String base64Data) {
        Session session = SESSIONS.get(id);
        if (session == null || session.output == null || session.failed || base64Data == null) {
            return false;
        }
        try {
            byte[] data = Base64.decode(base64Data, Base64.NO_WRAP);
            session.output.write(data);
            return true;
        } catch (Exception e) {
            session.failed = true;
            return false;
        }
    }

    static boolean closeRead(int id) {
        Session session = SESSIONS.remove(id);
        if (session == null) return false;
        try {
            if (session.input != null) session.input.close();
            return !session.failed;
        } catch (IOException e) {
            return false;
        }
    }

    /** Closes the stream and returns the session for destination finalization. */
    static Session closeWrite(int id) {
        Session session = SESSIONS.remove(id);
        if (session == null) return null;
        try {
            if (session.output != null) {
                session.output.flush();
                session.output.close();
            }
        } catch (Exception e) {
            session.failed = true;
        }
        return session;
    }
}
