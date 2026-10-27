#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-threading — Test Runner
#  Usage: ./tests/run_tests.sh [/path/to/amc]
#
#  Self-contained: no external service. pthread is built into
#  the platform on every supported OS (POSIX libc, Windows
#  MSYS2/MinGW). libgc-dev must have thread support enabled
#  (the default since Boehm GC 8.x — every distro ships it
#  that way).
# ─────────────────────────────────────────────────────

set -u

if [ $# -ge 1 ]; then
    AMC="$1"
elif [ -n "${AMC:-}" ]; then
    :
elif command -v amc >/dev/null 2>&1; then
    AMC="$(command -v amc)"
else
    echo "ERROR: amc not found." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_RUNTIME="$PKG_ROOT/runtime"

AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
if [ -d "$AMC_DIR/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/runtime"
elif [ -d "$AMC_DIR/../share/amalgame/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/../share/amalgame/runtime"
elif [ -n "${AMC_RUNTIME:-}" ]; then
    :
else
    echo "ERROR: amc runtime/ not found. Set AMC_RUNTIME=..." >&2
    exit 2
fi

BUILD_DIR="$(mktemp -d -t athrd-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
PROJ_DIR="$BUILD_DIR/proj"
mkdir -p "$PROJ_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
PASS=0; FAIL=0; SKIP=0

echo ""
echo "════════════════════════════════════════════"
echo "  amalgame-threading — Tests"
echo "════════════════════════════════════════════"
echo "  amc:     $AMC ($("$AMC" --version 2>&1 | head -1))"
echo "  runtime: $AMC_RUNTIME"
echo ""

# ── Gate : libgc with thread support ────────────────
# bdwgc ships with --enable-threads=pthreads on every distro
# but verify just in case — try linking a GC_pthread_create call.
echo "── Probing libgc thread support ────────────"
LIBGC_OK=0
cat > "$BUILD_DIR/_gcprobe.c" <<'EOF'
#define GC_THREADS
#include <gc.h>
#include <pthread.h>
int main(void) { pthread_t t; (void)GC_pthread_create(&t,0,0,0); return 0; }
EOF
if gcc "$BUILD_DIR/_gcprobe.c" -lgc -lpthread -o "$BUILD_DIR/_gcprobe" 2>/dev/null; then
    LIBGC_OK=1
    echo "  GC_pthread_create:   found"
else
    echo "  GC_pthread_create:   NOT FOUND (libgc built without --enable-threads?)"
fi
echo ""

# ── Stage fake cache for the test fixture ───────────
FAKE_CACHE="$BUILD_DIR/cache"
PKG_GIT="github.com/amalgame-lang/amalgame-threading"
PKG_TAG="${PKG_TAG:-v0.1.0}"
FAKE_SHA="deadbeefcafebabe0000000000000000000000ab"
SHORT_SHA="${FAKE_SHA:0:8}"
PKG_CACHE_DIR="$FAKE_CACHE/$PKG_GIT/${PKG_TAG}_${SHORT_SHA}"

mkdir -p "$(dirname "$PKG_CACHE_DIR")"
rm -rf "$PKG_CACHE_DIR"
ln -s "$PKG_ROOT" "$PKG_CACHE_DIR"

cat > "$PROJ_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-threading"
git  = "$PKG_GIT"
tag  = "$PKG_TAG"
rev  = "$FAKE_SHA"
EOF

export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"

run_test() {
    local name="$1"
    local expected="$2"
    printf "  %-46s" "$name"
    if [ "$LIBGC_OK" = "0" ]; then
        echo -e "${YELLOW}SKIP${NC} (libgc thread support missing)"
        SKIP=$((SKIP + 1)); return
    fi
    cp "$SCRIPT_DIR/stdlib_threading.am" "$PROJ_DIR/test.am"
    local out_base="$PROJ_DIR/test"
    local out
    out=$(cd "$PROJ_DIR" && "$AMC" -o test test.am 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAIL${NC} (amc)"; echo "$out" | head -3 | sed 's/^/    /'
        FAIL=$((FAIL + 1)); return
    fi
    if [ ! -f "$out_base.c" ]; then
        echo -e "${RED}FAIL${NC} (no .c)"; FAIL=$((FAIL + 1)); return
    fi
    gcc -O2 -w \
        -I"$AMC_RUNTIME" -I"$PKG_RUNTIME" \
        "$out_base.c" \
        -lgc -lm -lcurl -ldl -lpthread \
        -o "$out_base" 2>"$BUILD_DIR/link.log"
    if [ ! -x "$out_base" ]; then
        echo -e "${RED}FAIL${NC} (gcc link)"
        cat "$BUILD_DIR/link.log" | head -3 | sed 's/^/    /'
        FAIL=$((FAIL + 1)); return
    fi
    local run_output
    run_output=$("$out_base" 2>&1)
    if echo "$run_output" | grep -qF "$expected"; then
        echo -e "${GREEN}PASS${NC}"; PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        echo "    expected: $expected"
        echo "    got:      $(echo "$run_output" | head -3 | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

echo "── Threading ───────────────────────────────"
run_test "Mutex lock/unlock + trylock"           "[PASS] Mutex lock/unlock + trylock"
run_test "Channel Count == 3"                    "[PASS] Channel Count == 3"
run_test "Channel FIFO order"                    "[PASS] Channel FIFO order"
run_test "TrySend/TryReceive round-trip"         "[PASS] TrySend/TryReceive round-trip"
run_test "TryReceive on empty returns 0"         "[PASS] TryReceive on empty returns 0"
run_test "ChannelClose"                          "[PASS] ChannelClose"
run_test "Receive drains then sentinels"         "[PASS] Receive drains then sentinels"
run_test "Thread.Sleep returns cleanly"          "[PASS] Thread.Sleep returns cleanly"
run_test "worker thread + channel"               "[PASS] worker thread + channel consumed 5 values"
run_test "4 producers x 10 sends"                "[PASS] 4 producers x 10 sends consumed correctly"

echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}SKIP: $SKIP${NC}"
echo "────────────────────────────────────────────"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
