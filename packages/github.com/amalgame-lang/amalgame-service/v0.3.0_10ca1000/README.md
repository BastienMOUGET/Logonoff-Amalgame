# amalgame-service

Pure-Amalgame service facade for [Amalgame](https://github.com/amalgame-lang/Amalgame).
**SIGTERM/SIGINT** signal handler + `ShouldStop()` polling +
interruptible `Sleep()` + **native Windows Service Control Manager
dispatcher** — the primitives every long-running daemon needs to
run cleanly under systemd, launchd, and the Windows SCM with no
external wrapper.

Originally bundled in amc's `src/stdlib/service.am`; extracted into
this external package as part of the framework split (post-v0.7.5).
v0.2.0 added the native Windows SCM dispatcher — `amc new --template
service` scaffolds no longer ship NSSM as a dependency.

## Install

```bash
amc package add service                  # via the curated index
amc package add github.com/amalgame-lang/amalgame-service@v0.3.0
```

Requires **amc 0.7.7+**.

## Surface

```amalgame
import Amalgame.Service

class Program {
    public static int Main(List<string> args) {
        Service.RunAsService("my-daemon")       // install signal handler + (Windows)
                                                // bootstrap SCM dispatcher on a
                                                // worker thread; same binary works
                                                // in console mode AND as a native
                                                // Windows service

        while (!Service.ShouldStop()) {
            // … do work …
            Service.Sleep(5000)                 // interruptible, returns
                                                // immediately on shutdown
        }
        return 0
    }
}
```

`Service.Install()` (no name) is the v0.1.0 entry point — installs
the OS signal/Ctrl handler only, no Windows SCM integration. Still
supported for the "console-only daemon" case and for embedding the
loop in a non-service process.

`Service.RequestStop()` is the programmatic shutdown trigger — same
flag the signal handler flips, useful from in-process callers (e.g.
an admin HTTP endpoint).

### Session and power events (v0.3.0)

```amalgame
Service.EnableSessionEvents()            // ask the SCM for SESSIONCHANGE + POWEREVENT
Service.RunAsService("my-daemon")

while (!Service.ShouldStop()) {
    let evs: List<ServiceEvent> = Service.PollEvents()   // never blocks
    for i in 0..evs.Count() {
        let e: ServiceEvent = evs.Get(i)
        // e.Kind: Logon, Logoff, Lock, Unlock, ConsoleConnect,
        //         ConsoleDisconnect, RemoteConnect, RemoteDisconnect,
        //         RemoteControl, SessionCreate, SessionTerminate,
        //         Suspend, Resume, Shutdown, Stop
        // e.SessionId (-1 for power / shutdown), e.TimeNanos (UTC)
    }
    Service.Sleep(1000)
}
```

Events are buffered in a 256-entry ring (oldest dropped on overflow),
timestamped when the SCM delivers them. `Service.InjectEvent(kind,
sessionId)` pushes a synthetic event into the same queue (tests,
app-level markers). On POSIX only injected events ever appear.

### Windows session helpers (v0.3.0)

All return empty / `false` / `-1` / `0` on POSIX. Those marked †
need the process to run as a service under **LocalSystem**
(`WTSQueryUserToken`).

| Call | Returns |
|---|---|
| `IsRunningUnderScm()` | started by the SCM vs console launch |
| `ActiveConsoleSession()` | session on the physical console, `-1` if none |
| `UserSessions()` | ids of sessions with a logged-on user (console + RDP) |
| `SessionUserName(id)` / `SessionDomain(id)` | account / domain, UTF-8 |
| `SessionState(id)` | `Active`, `Disconnected`, … or `Unknown` |
| `SessionLockState(id)` | `Locked` / `Unlocked` / `Unknown` (Windows 8+) |
| `SessionUserSid(id)` † | `S-1-5-21-…` |
| `SessionUserIsAdmin(id)` † | member of Administrators (UAC linked token checked) |
| `SendMessage(id, title, msg, timeoutSec)` | message box on that desktop, non-blocking |
| `LaunchInSession(id, cmdLine)` † | pid of a process started as that user on `winsta0\default`, `0` on failure |

`wtsapi32.dll` and `userenv.dll` are resolved at runtime, so no extra
link flags are needed on any platform.

## Windows service registration

With v0.2.0, the binary is a real Windows service — register it
with the built-in `sc.exe`, no NSSM download required:

```powershell
sc.exe create my-daemon binPath= "C:\path\to\my-daemon.exe" start= auto
sc.exe start  my-daemon
sc.exe stop   my-daemon
sc.exe delete my-daemon
```

The same binary launched directly from a console keeps behaving
like a plain foreground process — `StartServiceCtrlDispatcher`
returns immediately with `ERROR_FAILED_SERVICE_CONTROLLER_CONNECT`
in that case, and `Ctrl+C` triggers the same `ShouldStop` flag.

## Tests

```bash
./tests/run_tests.sh /path/to/amc
```

## License

Apache-2.0 — see `LICENSE`. No vendored third-party code.
