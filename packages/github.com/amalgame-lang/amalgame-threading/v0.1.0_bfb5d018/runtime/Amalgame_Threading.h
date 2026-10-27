/*
 * Amalgame Standard Library — Amalgame.Threading
 * Copyright (c) 2026 Bastien MOUGET
 * https://github.com/amalgame-lang/Amalgame
 *
 * Threading primitives for Amalgame: Mutex, Channel, Thread.
 *
 * Wraps POSIX pthread on Unix-like systems; works on Windows
 * MSYS2 / MinGW via pthread-w32. Native Windows threads
 * (CRITICAL_SECTION) is a v2 concern.
 *
 * Critical detail: every thread we spawn is registered with
 * libgc via GC_pthread_create so locals on the thread's stack
 * stay scannable. Don't bypass with raw pthread_create — locals
 * would either get freed mid-use or pin live objects forever.
 *
 * Surface (v1):
 *
 *   ── Mutex ──────────────────────────────────────────
 *   AmalgameMutex* MutexNew()
 *   void           MutexLock(m)
 *   void           MutexUnlock(m)
 *   code_bool      MutexTryLock(m)              // true if locked
 *
 *   ── Channel — bounded FIFO of i64-erased values ────
 *   AmalgameChannel* ChannelNew(i64 capacity)
 *   code_bool        ChannelSend(ch, value)     // blocks if full
 *   i64              ChannelReceive(ch)         // blocks if empty
 *   code_bool        ChannelTrySend(ch, value)  // non-blocking
 *   i64              ChannelTryReceive(ch)      // non-blocking
 *   void             ChannelClose(ch)
 *   code_bool        ChannelIsClosed(ch)
 *   i64              ChannelCount(ch)
 *   i64              ChannelCapacity(ch)
 *
 *   ── Thread ─────────────────────────────────────────
 *   AmalgameThread*  ThreadSpawn(closure, arg)  // closure is
 *                                                // an AmalgameClosure*
 *                                                // called as call1(arg)
 *   void             ThreadJoin(t)              // wait for completion
 *   void             ThreadSleep(i64 ms)        // current thread
 *   code_bool        ThreadIsAlive(t)
 *
 * Channel values are erased to `void*` at the C level (same as
 * AmalgameList cell storage). Pass i64-ish primitives boxed via
 * `(void*)(intptr_t)value` and unbox with `(intptr_t)cell` —
 * the manifest [stdlib.functions] declares Send/Receive as `i64`
 * so the AM-side cgen does this dance automatically for the
 * common case of int/bool/enum payloads. For pointer payloads
 * (List<X>*, custom struct*), cells round-trip cleanly.
 *
 * Closure model: ThreadSpawn takes a 1-arg AmalgameClosure plus
 * a single i64 arg passed through to it. If you don't need the
 * arg, write `let work = (_x: int) => { ... }` and pass 0.
 * Multi-arg threads should use Channel for plumbing instead of
 * stuffing everything into the single closure capture.
 *
 * Memory: every wrapper struct is GC_MALLOC'd. Mutex and
 * Channel register a finalizer that destroys the underlying
 * pthread primitives if the user lets the handle drop without
 * an explicit Close. Thread join via GC_pthread_join.
 */

#ifndef AMALGAME_THREADING_H
#define AMALGAME_THREADING_H

#include "_runtime.h"
#include "Amalgame_Collections.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* bdwgc's threading helpers (GC_pthread_create / _join / etc.)
 * are only declared in <gc.h> when GC_THREADS is defined BEFORE
 * the first include. _runtime.h pulls gc.h in transparently
 * without that define, which locks the prototypes out via the
 * header guard. Forward-declare what we need so the wrapper
 * compiles cleanly regardless of include order. Symbols come
 * from the system libgc.so at link time — `libgc-dev` ships
 * with `--enable-threads=pthreads` on every distro we target. */
extern int  GC_pthread_create(pthread_t* new_thread,
                               const pthread_attr_t* attr,
                               void* (*start_routine)(void*),
                               void* arg);
extern int  GC_pthread_join(pthread_t thread, void** retval);

/* ═══════════════════════════════════════════════════════
 *  Mutex
 * ═══════════════════════════════════════════════════════ */

typedef struct AmalgameMutex {
    pthread_mutex_t mutex;
    int             initialised;
} AmalgameMutex;

static void _amth_mutex_finalize(void* obj, void* cd) {
    (void) cd;
    AmalgameMutex* m = (AmalgameMutex*) obj;
    if (m && m->initialised) {
        pthread_mutex_destroy(&m->mutex);
        m->initialised = 0;
    }
}

static inline AmalgameMutex* Amalgame_Threading_MutexNew(void) {
    AmalgameMutex* m = (AmalgameMutex*) GC_MALLOC(sizeof(AmalgameMutex));
    pthread_mutex_init(&m->mutex, NULL);
    m->initialised = 1;
    GC_register_finalizer(m, _amth_mutex_finalize, NULL, NULL, NULL);
    return m;
}

static inline void Amalgame_Threading_MutexLock(AmalgameMutex* m) {
    if (m && m->initialised) pthread_mutex_lock(&m->mutex);
}

static inline void Amalgame_Threading_MutexUnlock(AmalgameMutex* m) {
    if (m && m->initialised) pthread_mutex_unlock(&m->mutex);
}

static inline code_bool Amalgame_Threading_MutexTryLock(AmalgameMutex* m) {
    if (!m || !m->initialised) return 0;
    return pthread_mutex_trylock(&m->mutex) == 0;
}

/* ═══════════════════════════════════════════════════════
 *  Channel — bounded FIFO with cond-var wait
 * ═══════════════════════════════════════════════════════ */

typedef struct AmalgameChannel {
    pthread_mutex_t mutex;
    pthread_cond_t  not_full;    /* signal when a slot frees up */
    pthread_cond_t  not_empty;   /* signal when a value arrives */
    void**          buffer;       /* capacity slots, circular */
    i64             capacity;
    i64             count;
    i64             head;         /* read index */
    i64             tail;         /* write index */
    int             closed;
    int             initialised;
} AmalgameChannel;

static void _amth_chan_finalize(void* obj, void* cd) {
    (void) cd;
    AmalgameChannel* ch = (AmalgameChannel*) obj;
    if (ch && ch->initialised) {
        pthread_mutex_destroy(&ch->mutex);
        pthread_cond_destroy(&ch->not_full);
        pthread_cond_destroy(&ch->not_empty);
        ch->initialised = 0;
    }
}

static inline AmalgameChannel* Amalgame_Threading_ChannelNew(i64 capacity) {
    if (capacity <= 0) capacity = 1;
    AmalgameChannel* ch = (AmalgameChannel*) GC_MALLOC(sizeof(AmalgameChannel));
    ch->buffer      = (void**) GC_MALLOC(sizeof(void*) * (size_t) capacity);
    ch->capacity    = capacity;
    ch->count       = 0;
    ch->head        = 0;
    ch->tail        = 0;
    ch->closed      = 0;
    pthread_mutex_init(&ch->mutex, NULL);
    pthread_cond_init(&ch->not_full, NULL);
    pthread_cond_init(&ch->not_empty, NULL);
    ch->initialised = 1;
    GC_register_finalizer(ch, _amth_chan_finalize, NULL, NULL, NULL);
    return ch;
}

/* Blocking send. Returns false if the channel is closed (sender
 * is expected to stop pushing after Close). */
static inline code_bool Amalgame_Threading_ChannelSend(AmalgameChannel* ch, i64 value) {
    if (!ch) return 0;
    pthread_mutex_lock(&ch->mutex);
    while (!ch->closed && ch->count == ch->capacity) {
        pthread_cond_wait(&ch->not_full, &ch->mutex);
    }
    if (ch->closed) {
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    ch->buffer[ch->tail] = (void*) (intptr_t) value;
    ch->tail = (ch->tail + 1) % ch->capacity;
    ch->count++;
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
    return 1;
}

/* Non-blocking send. Returns false if the channel is full
 * OR closed. */
static inline code_bool Amalgame_Threading_ChannelTrySend(AmalgameChannel* ch, i64 value) {
    if (!ch) return 0;
    pthread_mutex_lock(&ch->mutex);
    if (ch->closed || ch->count == ch->capacity) {
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    ch->buffer[ch->tail] = (void*) (intptr_t) value;
    ch->tail = (ch->tail + 1) % ch->capacity;
    ch->count++;
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
    return 1;
}

/* Blocking receive. Returns 0 if the channel is closed and
 * empty (terminates a `while (true) { ch.Receive() }` reader).
 * Note: 0 is also a valid value to send through the channel —
 * pair Receive with IsClosed() if you need to distinguish. */
static inline i64 Amalgame_Threading_ChannelReceive(AmalgameChannel* ch) {
    if (!ch) return 0;
    pthread_mutex_lock(&ch->mutex);
    while (!ch->closed && ch->count == 0) {
        pthread_cond_wait(&ch->not_empty, &ch->mutex);
    }
    if (ch->count == 0) {
        /* closed + empty */
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    i64 v = (i64) (intptr_t) ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    return v;
}

/* Non-blocking receive. Returns 0 if the channel is empty (and
 * 0 is also a valid value — pair with Count() if needed). */
static inline i64 Amalgame_Threading_ChannelTryReceive(AmalgameChannel* ch) {
    if (!ch) return 0;
    pthread_mutex_lock(&ch->mutex);
    if (ch->count == 0) {
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    i64 v = (i64) (intptr_t) ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    return v;
}

/* Close the channel: subsequent Send returns false; subsequent
 * Receive drains the remaining buffered values, then returns 0
 * once empty. Wakes every waiter so blocked Send/Receive
 * threads exit cleanly. */
static inline void Amalgame_Threading_ChannelClose(AmalgameChannel* ch) {
    if (!ch) return;
    pthread_mutex_lock(&ch->mutex);
    ch->closed = 1;
    pthread_cond_broadcast(&ch->not_full);
    pthread_cond_broadcast(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
}

static inline code_bool Amalgame_Threading_ChannelIsClosed(AmalgameChannel* ch) {
    if (!ch) return 1;
    pthread_mutex_lock(&ch->mutex);
    int c = ch->closed;
    pthread_mutex_unlock(&ch->mutex);
    return c ? 1 : 0;
}

static inline i64 Amalgame_Threading_ChannelCount(AmalgameChannel* ch) {
    if (!ch) return 0;
    pthread_mutex_lock(&ch->mutex);
    i64 n = ch->count;
    pthread_mutex_unlock(&ch->mutex);
    return n;
}

static inline i64 Amalgame_Threading_ChannelCapacity(AmalgameChannel* ch) {
    return ch ? ch->capacity : 0;
}

/* ═══════════════════════════════════════════════════════
 *  Thread — spawn an AmalgameClosure on a fresh thread
 * ═══════════════════════════════════════════════════════ */

typedef struct AmalgameThread {
    pthread_t        handle;
    AmalgameClosure* fn;
    void*            arg;
    int              joined;
    int              alive;
    int              started;
    pthread_mutex_t  state_mutex;
} AmalgameThread;

static void* _amth_thread_entry(void* raw) {
    AmalgameThread* t = (AmalgameThread*) raw;
    /* bdwgc thread registration: GC_pthread_create already does
     * this for us — calling GC_register_my_thread again would
     * be a double-register. Just run the user code. */
    if (t->fn) {
        AmalgameClosure_call1(t->fn, t->arg);
    }
    pthread_mutex_lock(&t->state_mutex);
    t->alive = 0;
    pthread_mutex_unlock(&t->state_mutex);
    return NULL;
}

static inline AmalgameThread* Amalgame_Threading_ThreadSpawn(
        AmalgameClosure* fn, i64 arg) {
    AmalgameThread* t = (AmalgameThread*) GC_MALLOC(sizeof(AmalgameThread));
    t->fn      = fn;
    t->arg     = (void*) (intptr_t) arg;
    t->joined  = 0;
    t->alive   = 1;
    t->started = 0;
    pthread_mutex_init(&t->state_mutex, NULL);

    /* GC_pthread_create wraps the platform pthread_create with
     * the bdwgc-required thread registration. The thread's
     * stack becomes a root for the collector while it runs;
     * locals + captured closure env stay scannable. */
    if (GC_pthread_create(&t->handle, NULL, _amth_thread_entry, t) != 0) {
        t->alive = 0;
        return t;
    }
    t->started = 1;
    return t;
}

static inline void Amalgame_Threading_ThreadJoin(AmalgameThread* t) {
    if (!t || !t->started || t->joined) return;
    GC_pthread_join(t->handle, NULL);
    t->joined = 1;
}

static inline code_bool Amalgame_Threading_ThreadIsAlive(AmalgameThread* t) {
    if (!t) return 0;
    pthread_mutex_lock(&t->state_mutex);
    int a = t->alive;
    pthread_mutex_unlock(&t->state_mutex);
    return a ? 1 : 0;
}

/* Static-style sleep. Suspends the calling thread for ms
 * milliseconds. Implemented via nanosleep on POSIX. */
static inline void Amalgame_Threading_ThreadSleep(i64 ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec  = (time_t) (ms / 1000);
    ts.tv_nsec = (long) ((ms % 1000) * 1000000L);
    nanosleep(&ts, NULL);
}

#endif /* AMALGAME_THREADING_H */
