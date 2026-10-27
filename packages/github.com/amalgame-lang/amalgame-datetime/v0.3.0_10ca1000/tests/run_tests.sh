#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-datetime — Test Runner
#  Usage: ./tests/run_tests.sh [/path/to/amc]
#
#  Stages a fake package cache pointing at the local working tree,
#  pre-builds the per-package facade archive (mimicking what
#  AddCommand.PrecompileFacade does at `amc package add` time),
#  then compiles + links + runs the test sample, asserting the
#  expected [PASS] lines appear on stdout.
#
#  Discovers amc:
#    1. First positional arg
#    2. AMC environment variable
#    3. `amc` on PATH
#
#  Requires amc 0.7.6+ for the [stdlib].facade pipeline.
# ─────────────────────────────────────────────────────

set -u
# Local-time tests assert Europe/Paris offsets (CET/CEST).
export TZ=Europe/Paris

# ── Locate amc ─────────────────────────────────────────
if [ $# -ge 1 ]; then
    AMC="$1"
elif [ -n "${AMC:-}" ]; then
    :
elif command -v amc >/dev/null 2>&1; then
    AMC="$(command -v amc)"
else
    echo "ERROR: amc not found. Pass the path as first arg, set AMC env var, or put amc on PATH." >&2
    exit 2
fi

if [ ! -x "$AMC" ]; then
    echo "ERROR: amc binary at '$AMC' is not executable." >&2
    exit 2
fi
AMC="$(cd "$(dirname "$AMC")" && pwd)/$(basename "$AMC")"

# ── Locate package root ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Locate amc's runtime/ (core stdlib C headers) ─────
AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
if [ -d "$AMC_DIR/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/runtime"
elif [ -n "${AMC_RUNTIME:-}" ]; then
    :
else
    echo "ERROR: can't find amc's runtime/ headers." >&2
    echo "       Tried $AMC_DIR/runtime, AMC_RUNTIME env var unset." >&2
    echo "       Either run from a source build of Amalgame, or set" >&2
    echo "       AMC_RUNTIME=/path/to/Amalgame/runtime before running." >&2
    exit 2
fi

# ── Setup ──────────────────────────────────────────────
BUILD_DIR="$(mktemp -d -t afdt-tests-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

PROJ_DIR="$BUILD_DIR/proj"
mkdir -p "$PROJ_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

echo ""
echo "════════════════════════════════════════════"
echo "  amalgame-datetime — Test Suite"
echo "════════════════════════════════════════════"
echo "  amc:     $AMC ($("$AMC" --version 2>&1 | head -1))"
echo "  package: $PKG_ROOT"
echo "  runtime: $AMC_RUNTIME"

# ── Stage a fake cache pointing at the local working tree ──
FAKE_CACHE="$BUILD_DIR/cache"
PKG_GIT="github.com/amalgame-lang/amalgame-datetime"
PKG_TAG="${PKG_TAG:-v0.1.0}"
FAKE_SHA="deadbeefcafebabe0000000000000000000000ab"
SHORT_SHA="${FAKE_SHA:0:8}"
PKG_CACHE_DIR="$FAKE_CACHE/$PKG_GIT/${PKG_TAG}_${SHORT_SHA}"

mkdir -p "$(dirname "$PKG_CACHE_DIR")"
ln -s "$PKG_ROOT" "$PKG_CACHE_DIR"

cat > "$PROJ_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-datetime"
git  = "$PKG_GIT"
tag  = "$PKG_TAG"
rev  = "$FAKE_SHA"
EOF

export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"
echo "  cache:   $FAKE_CACHE → $PKG_ROOT"
echo ""

# ── Compute PlatformTag ──
case "$(uname -s)" in
    Linux*)               PLAT="linux-$(uname -m)" ;;
    Darwin*)              PLAT="macos-$(uname -m)" ;;
    MINGW*|MSYS*|CYGWIN*) PLAT="windows-$(uname -m)" ;;
    *)                    PLAT="unknown-$(uname -m)" ;;
esac
PLAT="${PLAT/amd64/x86_64}"
PLAT="${PLAT/aarch64/arm64}"

FACADE_BUILD_DIR="$BUILD_DIR/build/$PLAT"
mkdir -p "$FACADE_BUILD_DIR"
WORK_BUILD_DIR="$PKG_ROOT/build/$PLAT"
mkdir -p "$(dirname "$WORK_BUILD_DIR")"
if [ -e "$WORK_BUILD_DIR" ] && [ ! -L "$WORK_BUILD_DIR" ]; then
    echo "WARNING: $WORK_BUILD_DIR exists as a directory; removing." >&2
    rm -rf "$WORK_BUILD_DIR"
fi
rm -f "$WORK_BUILD_DIR"
ln -s "$FACADE_BUILD_DIR" "$WORK_BUILD_DIR"
ARCHIVE="$FACADE_BUILD_DIR/libamalgame-pkg-DateTime.a"

# ── Pre-build the facade archive ──
echo "── Pre-compiling facade.am → libamalgame-pkg-DateTime.a ──"
"$AMC" --lib --quiet "$PKG_ROOT/facade.am" -o "$FACADE_BUILD_DIR/DateTime-facade"
gcc -O2 -I"$AMC_RUNTIME" -w -c "$FACADE_BUILD_DIR/DateTime-facade.c" \
    -o "$FACADE_BUILD_DIR/DateTime-facade.o"
ar rcs "$ARCHIVE" "$FACADE_BUILD_DIR/DateTime-facade.o"
ARSIZE=$(stat -c%s "$ARCHIVE" 2>/dev/null || stat -f%z "$ARCHIVE")
echo "  built: $ARCHIVE ($ARSIZE bytes)"
echo ""

# ── Helper ─────────────────────────────────────────────
run_test() {
    local name="$1"
    local expected="$2"

    printf "  %-38s" "$name"

    cp "$SCRIPT_DIR/stdlib_datetime.am" "$PROJ_DIR/test.am"
    local out_base="$PROJ_DIR/test"

    local out
    out=$(cd "$PROJ_DIR" && "$AMC" -o test test.am --quiet 2>&1)
    local amc_exit=$?
    if [ $amc_exit -ne 0 ]; then
        echo -e "${RED}FAIL${NC} (amc exited $amc_exit)"
        echo "$out" | head -3 | sed 's/^/    /'
        FAIL=$((FAIL + 1)); return
    fi
    if [ ! -f "$out_base.c" ]; then
        echo -e "${RED}FAIL${NC} (no .c emitted)"
        FAIL=$((FAIL + 1)); return
    fi
    local gcc_log
    gcc_log=$(gcc -O2 -I"$AMC_RUNTIME" "$out_base.c" "$ARCHIVE" \
        -lgc -lm -lcurl -lz -ldl -lpthread -o "$out_base" 2>&1)
    if [ ! -x "$out_base" ]; then
        echo -e "${RED}FAIL${NC} (gcc link failed)"
        echo "$gcc_log" | head -5 | sed 's/^/    /'
        FAIL=$((FAIL + 1)); return
    fi
    local run_output
    run_output=$("$out_base" 2>&1)
    if echo "$run_output" | grep -qF "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} (output mismatch)"
        echo "    expected: $expected"
        echo "    got:      $(echo "$run_output" | head -3 | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

# ── Cases ──────────────────────────────────────────────
echo "── Amalgame.DateTime ──────────────────────"
run_test "Now plausible"                "[PASS] Now plausible"
run_test "FromUnixSeconds"              "[PASS] FromUnixSeconds"
run_test "iso round trip"               "[PASS] iso round trip"
run_test "iso fractional"               "[PASS] iso fractional"
run_test "parse rejects bad"            "[PASS] parse rejects bad"
run_test "Instant.Add hours"            "[PASS] Instant.Add hours"
run_test "Instant.Subtract hours"       "[PASS] Instant.Subtract hours"
run_test "Instant.Since"                "[PASS] Instant.Since"
run_test "Instant comparison"           "[PASS] Instant comparison"
run_test "Duration arithmetic"          "[PASS] Duration arithmetic"
run_test "Duration Times"               "[PASS] Duration Times"
run_test "Duration Negate"              "[PASS] Duration Negate"
run_test "dur fmt zero"                 "[PASS] dur fmt zero"
run_test "dur fmt ns"                   "[PASS] dur fmt ns"
run_test "dur fmt us"                   "[PASS] dur fmt us"
run_test "dur fmt ms"                   "[PASS] dur fmt ms"
run_test "dur fmt s"                    "[PASS] dur fmt s"
run_test "dur fmt min"                  "[PASS] dur fmt min"
run_test "dur fmt hour"                 "[PASS] dur fmt hour"
run_test "Stopwatch elapsed"            "[PASS] Stopwatch elapsed"
run_test "Stopwatch reset"              "[PASS] Stopwatch reset"
run_test "SleepMillis waits"            "[PASS] SleepMillis waits"
run_test "Duration.Sleep + no-op"       "[PASS] Duration.Sleep + no-op"
run_test "LocalOffsetSeconds DST"       "[PASS] LocalOffsetSeconds DST"
run_test "LocalToEpoch"                 "[PASS] LocalToEpoch"
run_test "FormatLocal + weekday"        "[PASS] FormatLocal + weekday"
run_test "LocalDate + FromLocal"        "[PASS] LocalDate + FromLocal"

# ── Cleanup the symlinked build dir to leave the tree clean ──
rm -f "$WORK_BUILD_DIR"

# ── Summary ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}SKIP: $SKIP${NC}"
echo "────────────────────────────────────────────"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
