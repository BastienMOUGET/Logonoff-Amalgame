# NOTICE — amalgame-threading

## Authorship

Copyright 2026 Bastien Mouget. Original work — see
`runtime/Amalgame_Threading.h`.

Part of the Amalgame ecosystem
([github.com/amalgame-lang/Amalgame](https://github.com/amalgame-lang/Amalgame)).
External contributions are paused at the ecosystem level; see the
main repo's `CONTRIBUTING.md` for the policy.

AI tools (Anthropic Claude) were used during development. Per
the project's authorship policy, AI is treated as a tool, not a
co-author at law.

## Licence

Apache License 2.0. See `LICENSE` for the full text.

## Third-party content

**None vendored.** This package binds to two system libraries
that ship with every modern Unix-like target:

### pthread (POSIX threads)

`pthread_create / mutex / cond / nanosleep` etc. are part of
POSIX libc on every Unix-like system. Windows MSYS2 / MinGW
ships `libpthread-mingw32` (also called pthread-w32) providing
the same surface. No installation required — it's in the C
standard library.

### libgc (Boehm garbage collector)

`GC_pthread_create` / `GC_pthread_join` wrappers come from
Boehm GC (libgc), already a transitive dependency of every
Amalgame package via the main runtime. The wrapper registers
each spawned thread with the GC so locals on the thread's stack
stay scannable; raw `pthread_create` would let the collector
either free those locals early or pin live objects forever.

libgc is distributed under a permissive licence very similar to
[X11](https://github.com/ivmai/bdwgc/blob/master/README.QUICK) —
public domain modifications with no copyleft virality, Apache-2.0
compatible.

This package does not include or redistribute any pthread or
libgc code; users obtain those via their OS package manager
(libgc-dev on Debian, etc.) — already a prereq of the main
Amalgame runtime, so no extra install step is needed.

## Trademarks

None claimed. "POSIX" is a registered trademark of the IEEE.
