# amalgame-datetime

Pure-Amalgame datetime facade for [Amalgame](https://github.com/amalgame-lang/Amalgame).
**Instant** (nanosecond precision, UTC-only) + **Duration** (signed
i64 nanoseconds) + **Stopwatch** over the monotonic clock + **Sleep**
(thread sleep) + ISO 8601 format/parse.

Originally bundled in amc's `src/stdlib/datetime.am`; extracted into
this external package as part of the framework split (post-v0.7.5).

## Install

```bash
amc package add datetime                  # via the curated index
amc package add github.com/amalgame-lang/amalgame-datetime@v0.1.0
```

Requires **amc 0.7.6+** for the facade pre-compile pipeline
(PR #377).

## Surface

```amalgame
import Amalgame.DateTime

class Program {
    public static void Main() {
        // ── Wall clock + ISO 8601 ───────────────────
        let now: Instant = Instant.Now()
        Console.WriteLine(now.Format())
        // → 2026-05-13T14:23:01.123456789Z

        let parsed: InstantResult = Instant.Parse("2026-01-01T00:00:00Z")
        if (parsed.Ok) {
            Console.WriteLine(String_FromInt(parsed.Value.UnixSeconds()))
        }

        // ── Arithmetic ──────────────────────────────
        let oneHour: Duration = Duration.FromHours(1)
        let later:   Instant  = now.Add(oneHour)
        let elapsed: Duration = later.Since(now)
        Console.WriteLine(elapsed.Format())  // → 1h0m0s

        // ── Monotonic clock ─────────────────────────
        let sw = new Stopwatch()
        var sum: int = 0
        for i in 0..10000 { sum = sum + i }
        let took: Duration = sw.Elapsed()
        Console.WriteLine(took.Format())

        // ── Sleep ───────────────────────────────────
        DateTime.SleepMillis(500)             // half a second
        let oneSec: Duration = Duration.FromSeconds(1)
        oneSec.Sleep()                         // Duration-typed sleep
    }
}
```

See `facade.am` for the full API — `Instant.Now` /
`Instant.FromUnix{Seconds,Millis,Nanos}` / `.Format` / `.Parse` /
`.Add` / `.Subtract` / `.Since` / `.IsBefore` / `.IsAfter` /
`.Equals`, `Duration.From{Hours,Minutes,Seconds,Millis,Nanos}` /
`.Plus` / `.Minus` / `.Times` / `.Negate` / `.Format`,
`Stopwatch.Elapsed` / `.Reset`,
`DateTime.SleepNanos(ns)` / `.SleepMillis(ms)` / `.SleepSeconds(s)` /
`Duration.Sleep()`.

### Local time (v0.3.0)

The machine's configured zone, DST included (`localtime_r` /
`mktime` on POSIX — honours `$TZ`; the dynamic time-zone API on
Windows). Everything else stays UTC.

```amalgame
let off: int = DateTime.LocalOffsetSeconds(epochSecs)   // 3600 / 7200 in Paris
let t0:  int = DateTime.LocalToEpoch(2026, 3, 29, 0, 0, 0)  // local midnight → epoch s

let now: Instant = Instant.Now()
now.LocalDate()      // "2026-10-26"
now.FormatLocal()    // "2026-10-26T14:23:01+01:00"
now.LocalParts()     // [y, mo, d, h, mi, s, fracNs, isoWeekday 1..7]
Instant.FromLocal(2026, 10, 26, 8, 30, 0)
```

## Tests

```bash
./tests/run_tests.sh /path/to/amc
```

## License

Apache-2.0 — see `LICENSE`. No vendored third-party code.
