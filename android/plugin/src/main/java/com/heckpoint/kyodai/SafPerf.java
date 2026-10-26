package com.heckpoint.kyodai;

import java.util.ArrayList;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Diagnostic op-timing aggregator for the SAF storage tier. Records per-op
 * count/total/max wall time so the cost of binder round-trips to
 * ExternalStorageProvider (vs direct File I/O) can be measured on-device.
 * Purely additive instrumentation - no behavior change.
 */
public final class SafPerf {
    private static final class Stat {
        final AtomicLong count = new AtomicLong();
        final AtomicLong totalNanos = new AtomicLong();
        final AtomicLong maxNanos = new AtomicLong();
    }

    private static final ConcurrentHashMap<String, Stat> OPS = new ConcurrentHashMap<>();

    private SafPerf() {}

    public static long start() {
        return System.nanoTime();
    }

    public static void record(String op, long startNanos) {
        long elapsed = System.nanoTime() - startNanos;
        Stat s = OPS.computeIfAbsent(op, k -> new Stat());
        s.count.incrementAndGet();
        s.totalNanos.addAndGet(elapsed);
        s.maxNanos.accumulateAndGet(elapsed, Math::max);
    }

    /** Human-readable summary of everything recorded since the last snapshot, then resets. */
    public static synchronized String snapshotAndReset() {
        if (OPS.isEmpty()) return "no ops recorded";
        ArrayList<Map.Entry<String, Stat>> entries = new ArrayList<>(OPS.entrySet());
        entries.sort((a, b) -> Long.compare(b.getValue().totalNanos.get(), a.getValue().totalNanos.get()));
        long grand = 0;
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, Stat> e : entries) {
            Stat s = e.getValue();
            grand += s.totalNanos.get();
            sb.append(String.format(Locale.US, "%s{n=%d tot=%.0fms avg=%.1fms max=%.0fms} ",
                    e.getKey(),
                    s.count.get(),
                    s.totalNanos.get() / 1e6,
                    s.totalNanos.get() / 1e6 / Math.max(1, s.count.get()),
                    s.maxNanos.get() / 1e6));
        }
        OPS.clear();
        return String.format(Locale.US, "grand=%.0fms :: ", grand / 1e6) + sb.toString().trim();
    }
}
