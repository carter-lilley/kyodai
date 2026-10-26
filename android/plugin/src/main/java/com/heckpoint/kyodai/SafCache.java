package com.heckpoint.kyodai;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Session-scoped metadata cache for SAF (DocumentsContract) reads on
 * restricted paths. Every SAF existence/type/listing call is a binder
 * round-trip to ExternalStorageProvider, and bulk sweeps (platform-card
 * precompute, recursive firmware search) issue thousands of them.
 *
 * All kyodai mutations flow through this plugin, so entries are invalidated
 * (or primed) by our own writes; a short TTL bounds staleness from
 * out-of-band changes (user-side file managers, the emulator itself).
 */
public final class SafCache {
    private static final long TTL_NANOS = 5_000_000_000L; // 5s

    private static final class Meta {
        final boolean exists;
        final boolean isDir;
        final long at = System.nanoTime();
        Meta(boolean exists, boolean isDir) { this.exists = exists; this.isDir = isDir; }
        boolean fresh() { return System.nanoTime() - at < TTL_NANOS; }
    }

    private static final class Listing {
        final List<String> names;
        final long at = System.nanoTime();
        Listing(List<String> names) { this.names = names; }
        boolean fresh() { return System.nanoTime() - at < TTL_NANOS; }
    }

    private static final ConcurrentHashMap<String, Meta> META = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Listing> LISTINGS = new ConcurrentHashMap<>();

    private SafCache() {}

    /** Cached (exists, isDir) for an absolute path; null when unknown or stale. */
    public static boolean[] lookup(String path) {
        Meta m = META.get(path);
        if (m == null || !m.fresh()) return null;
        return new boolean[]{m.exists, m.isDir};
    }

    public static void put(String path, boolean exists, boolean isDir) {
        META.put(path, new Meta(exists, isDir));
    }

    /** Cached child-name listing for a directory; null when unknown or stale. */
    public static List<String> lookupListing(String dir) {
        Listing l = LISTINGS.get(dir);
        if (l == null || !l.fresh()) return null;
        return l.names;
    }

    /** Cache a directory listing and prime per-child meta from it. */
    public static void putListing(String dir, List<String> names, Map<String, Boolean> childIsDir) {
        LISTINGS.put(dir, new Listing(names));
        String prefix = dir.endsWith("/") ? dir : dir + "/";
        for (Map.Entry<String, Boolean> e : childIsDir.entrySet()) {
            META.put(prefix + e.getKey(), new Meta(true, e.getValue()));
        }
    }

    /** Drop one path's meta (e.g. it was just written or deleted). */
    public static void invalidate(String path) {
        META.remove(path);
    }

    /** Drop meta/listings for a path, everything beneath it, and its parent's
     *  listing (the parent's child set changed). Use after any mutation. */
    public static void invalidateTree(String path) {
        String prefix = path.endsWith("/") ? path : path + "/";
        META.keySet().removeIf(k -> k.equals(path) || k.startsWith(prefix));
        LISTINGS.keySet().removeIf(k -> k.equals(path) || k.startsWith(prefix));
        int idx = path.lastIndexOf('/');
        if (idx > 0) LISTINGS.remove(path.substring(0, idx));
    }
}
