# amalgame-threading

Threading primitives for [Amalgame](https://github.com/amalgame-lang/Amalgame).
**Mutex**, **Channel**, **Thread.Spawn / Join / Sleep** — wraps
POSIX pthread on Unix-like systems (Windows MSYS2 / MinGW
inherits pthread-w32 transparently). Every spawned thread is
registered with the bdwgc collector so locals on the thread's
stack stay scannable — raw `pthread_create` would crash or leak.

## Prerequisites

`pthread` is part of libc on every supported OS, and `libgc-dev`
(thread-enabled) is **already a dependency of the main Amalgame
runtime**. So **no extra install command is needed** if you've
already got `amc` working — this package is a thin wrapper, not
a new system dep.

| OS / distro | What you need (already there if amc runs) |
|---|---|
| Debian / Ubuntu | `libgc-dev` (`apt install libgc-dev`) + libc pthread |
| Fedora / RHEL | `gc-devel` + libc pthread |
| Arch / Manjaro | `gc` + libc pthread |
| Alpine | `gc-dev` + musl pthread |
| macOS | libSystem (built-in) + Homebrew `bdw-gc` |
| Windows (MSYS2) | `mingw-w64-x86_64-gc` + pthread-w32 |

Native Windows threads (Vista `CRITICAL_SECTION` + `CreateThread`)
is a v2 concern — too much `#ifdef` churn for v0.1.0. MSYS2 +
MinGW work today since they ship pthread-w32.

## Install

```bash
amc package add threading                                # via index
amc package add github.com/amalgame-lang/amalgame-threading@v0.1.0
```

Requires **amc 0.8.19+**.

## Surface

```amalgame
import Amalgame.Threading

public class Program {
    public static void Main(string[] args) {

        // ── Channel: bounded FIFO ──────────────────────
        let ch = Threading.ChannelNew(8)

        // ── Worker thread that produces 5 values ───────
        let worker = (id: int) => {
            var i: int = 0
            while (i < 5) {
                Threading.ChannelSend(ch, id * 10 + i)
                i = i + 1
            }
            Threading.ChannelClose(ch)
            return 0
        }
        let t = Threading.ThreadSpawn(worker, 7)

        // ── Consumer (main thread) ─────────────────────
        while (true) {
            let v: int = Threading.ChannelReceive(ch)
            if (Threading.ChannelIsClosed(ch)
                && Threading.ChannelCount(ch) == 0
                && v == 0) {
                break
            }
            Console.WriteLine("got " + String_FromInt(v))
        }
        Threading.ThreadJoin(t)
    }
}
```

### v0.1.0 method surface

| Method | Returns | Notes |
|---|---|---|
| **Mutex** | | |
| `Threading.MutexNew()` | `AmalgameMutex*` | Non-recursive |
| `Threading.MutexLock(m)` | `void` | Blocks |
| `Threading.MutexUnlock(m)` | `void` | |
| `Threading.MutexTryLock(m)` | `bool` | True if locked successfully |
| **Channel** — bounded FIFO of i64-erased values | | |
| `Threading.ChannelNew(capacity)` | `AmalgameChannel*` | capacity ≥ 1 |
| `Threading.ChannelSend(ch, value)` | `bool` | Blocks if full; false if closed |
| `Threading.ChannelReceive(ch)` | `int` | Blocks if empty; **0 sentinel** if closed + empty |
| `Threading.ChannelTrySend(ch, value)` | `bool` | Non-blocking; false if full or closed |
| `Threading.ChannelTryReceive(ch)` | `int` | Non-blocking; 0 if empty |
| `Threading.ChannelClose(ch)` | `void` | Wakes every blocked sender / receiver |
| `Threading.ChannelIsClosed(ch)` | `bool` | |
| `Threading.ChannelCount(ch)` | `int` | Current buffered count |
| `Threading.ChannelCapacity(ch)` | `int` | Capacity passed at New time |
| **Thread** | | |
| `Threading.ThreadSpawn(closure, arg)` | `AmalgameThread*` | `closure` is `(arg: int) => int`; runs once |
| `Threading.ThreadJoin(t)` | `void` | Wait for completion |
| `Threading.ThreadIsAlive(t)` | `bool` | |
| `Threading.ThreadSleep(ms)` | `void` | Current thread sleeps |

### Value erasure

Channels store values as `void*` at the C level (same as
`AmalgameList`). For primitive payloads (`int`, `bool`, enums)
the manifest declares `Send`/`Receive` as `i64` so amc does the
boxing/unboxing dance automatically. For pointer payloads
(`List<X>*`, your own class), they round-trip cleanly.

The **0 sentinel** for closed-and-empty `Receive` means you
should pair `Receive` with `IsClosed()` if `0` is a legitimate
value to send — otherwise the receiver loop can't distinguish
"got 0" from "channel drained". The example in the surface
above shows the safe pattern.

### Closure model

`ThreadSpawn` takes a 1-arg `AmalgameClosure` plus a single
`int` arg passed through. If you don't need the arg, write
`let work = (_x: int) => { ... }` and pass `0`. The closure
captures enclosing locals by value at creation time, so the
spawned thread sees a **snapshot** of those — mutate shared
state through `Channel` or `Mutex`.

For multi-arg threads, ship the data through a channel rather
than stuffing everything into the captured environment.

## bdwgc safety

Every spawned thread goes through `GC_pthread_create`, which
registers the thread with the Boehm GC so locals on its stack
stay scannable. **Don't bypass with raw `pthread_create`** in
`@c {}` blocks — locals would either get freed mid-use or pin
live objects forever, both nasty bugs to debug.

The wrapper handles this automatically; you only need to be
careful if you're writing your own `@c {}` thread code.

## Deferred to v2

- Native Windows threads (`CRITICAL_SECTION` + `CreateThread`).
  Today this works on MSYS2 / MinGW via pthread-w32.
- `ThreadPool` (build it on top of `Spawn` + `Channel` in user
  code, or wait for v2)
- `ReadWriteLock` / `Semaphore` / `Condition` (compose from
  `Mutex` + `Channel`)
- Thread-local storage
- Atomic primitives (single-writer + Channel suffices for now)
- `async` / `await` — that's separate language-level work, not
  a runtime feature

## Tests

```bash
./tests/run_tests.sh /path/to/amc
```

10 tests, all self-contained — no external service required.
Includes a multi-producer / single-consumer stress run that
exercises mutex contention + cond-var wakeups under real
concurrency.

## Licence

Apache-2.0 — see [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
pthread is libc-provided; libgc is X11-style permissive
(Apache-2.0 compatible).
