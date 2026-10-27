#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-crypto — Test Runner
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
# Resolve to absolute — the runner cd's into a tmp project dir
# before invoking AMC, so relative paths break.
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
BUILD_DIR="$(mktemp -d -t afcrypto-tests-XXXXXX)"
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
echo "  amalgame-crypto — Test Suite"
echo "════════════════════════════════════════════"
echo "  amc:     $AMC ($("$AMC" --version 2>&1 | head -1))"
echo "  package: $PKG_ROOT"
echo "  runtime: $AMC_RUNTIME"

# ── Stage a fake cache pointing at the local working tree ──
# Avoid going through `amc package add` (no published tag in CI).
FAKE_CACHE="$BUILD_DIR/cache"
PKG_GIT="github.com/amalgame-lang/amalgame-crypto"
PKG_TAG="${PKG_TAG:-v0.2.1}"
FAKE_SHA="deadbeefcafebabe0000000000000000000000ab"
SHORT_SHA="${FAKE_SHA:0:8}"
PKG_CACHE_DIR="$FAKE_CACHE/$PKG_GIT/${PKG_TAG}_${SHORT_SHA}"

mkdir -p "$(dirname "$PKG_CACHE_DIR")"
ln -s "$PKG_ROOT" "$PKG_CACHE_DIR"

cat > "$PROJ_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-crypto"
git  = "$PKG_GIT"
tag  = "$PKG_TAG"
rev  = "$FAKE_SHA"
EOF

export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"
echo "  cache:   $FAKE_CACHE → $PKG_ROOT"
echo ""

# ── Compute PlatformTag — mirror PackageRegistry.PlatformTag ──
case "$(uname -s)" in
    Linux*)               PLAT="linux-$(uname -m)" ;;
    Darwin*)              PLAT="macos-$(uname -m)" ;;
    MINGW*|MSYS*|CYGWIN*) PLAT="windows-$(uname -m)" ;;
    *)                    PLAT="unknown-$(uname -m)" ;;
esac
PLAT="${PLAT/amd64/x86_64}"
PLAT="${PLAT/aarch64/arm64}"

# Note: $PKG_CACHE_DIR is a symlink to $PKG_ROOT — writing under it
# writes to the working tree. We isolate the per-test archive in
# $BUILD_DIR/build/$PLAT and symlink it into place to keep the
# working tree clean during repeated runs.
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
ARCHIVE="$FACADE_BUILD_DIR/libamalgame-pkg-Crypto.a"

# ── Pre-build the facade archive (mimics PrecompileFacade) ──
echo "── Pre-compiling facade.am → libamalgame-pkg-Crypto.a ──"
"$AMC" --lib --quiet "$PKG_ROOT/facade.am" -o "$FACADE_BUILD_DIR/Crypto-facade"
gcc -O2 -I"$AMC_RUNTIME" -w -c "$FACADE_BUILD_DIR/Crypto-facade.c" \
    -o "$FACADE_BUILD_DIR/Crypto-facade.o"
ar rcs "$ARCHIVE" "$FACADE_BUILD_DIR/Crypto-facade.o"
ARSIZE=$(stat -c%s "$ARCHIVE" 2>/dev/null || stat -f%z "$ARCHIVE")
echo "  built: $ARCHIVE ($ARSIZE bytes)"
echo ""

# ── Helper ─────────────────────────────────────────────
run_test() {
    local name="$1"
    local expected="$2"

    printf "  %-38s" "$name"

    cp "$SCRIPT_DIR/stdlib_crypto.am" "$PROJ_DIR/test.am"
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
        -lgc -lm -lcurl -lz -ldl -lpthread -lcrypto -o "$out_base" 2>&1)
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
echo "── Amalgame.Crypto ────────────────────────"
run_test "sha256 empty"                 "[PASS] sha256 empty"
run_test "sha256 abc"                   "[PASS] sha256 abc"
run_test "hmac RFC 4231 TC1"            "[PASS] hmac rfc4231 tc1"
run_test "hmac fox"                     "[PASS] hmac fox"
run_test "aead empty KAT"               "[PASS] aead aes256gcm empty KAT"
run_test "aead sealed length"           "[PASS] aead sealed length"
run_test "aead roundtrip"               "[PASS] aead roundtrip Hello"
run_test "aead tampered ct rejected"    "[PASS] aead tag mismatch rejected"
run_test "aead wrong AAD rejected"      "[PASS] aead wrong-AAD rejected"
run_test "aead auto seal length"        "[PASS] aead auto seal length"
run_test "aead auto roundtrip"          "[PASS] aead auto roundtrip"
run_test "aead auto fresh nonce"        "[PASS] aead auto uses fresh nonce"
run_test "aead auto tamper rejected"    "[PASS] aead auto tamper rejected"
run_test "aead auto short rejected"     "[PASS] aead auto short bundle rejected"
# ── v0.3.0 — base64url + JwsKey ─────────────────────────
run_test "base64url RFC 4648"           "[PASS] base64url RFC 4648 vectors"
run_test "base64url roundtrip"          "[PASS] base64url roundtrip"
run_test "jws es256 generate"           "[PASS] jws es256 generate"
run_test "jws es256 sig length"         "[PASS] jws es256 sig length 64"
run_test "jws es256 verify"             "[PASS] jws es256 verify"
run_test "jws es256 tamper rejected"    "[PASS] jws es256 tamper rejected"
run_test "jws es256 jwk shape"          "[PASS] jws es256 jwk canonical shape"
run_test "jws es256 thumbprint"         "[PASS] jws es256 thumbprint length 43"
run_test "jws es256 pem header"         "[PASS] jws es256 pem header"
run_test "jws es256 pem roundtrip"      "[PASS] jws es256 pem roundtrip"
run_test "jws rs256 sign+verify"        "[PASS] jws rs256 sign+verify"

run_test "password hash format"         "[PASS] password hash format"
run_test "password verify correct"      "[PASS] password verify correct"
run_test "password verify wrong reject" "[PASS] password verify wrong rejected"
run_test "password salt randomized"     "[PASS] password salt randomized"
run_test "password verify 2nd hash"     "[PASS] password verify 2nd hash"
run_test "password malformed rejected"  "[PASS] password malformed rejected"

run_test "ct-equals match"              "[PASS] ct-equals match"
run_test "ct-equals one-byte diff"      "[PASS] ct-equals one-byte diff"
run_test "ct-equals length mismatch"    "[PASS] ct-equals length mismatch"

# ── TOTP / 2FA (RFC 6238) — v0.5.0 ──
run_test "totp 8-digit vectors"         "[PASS] totp rfc6238 8-digit vectors"
run_test "totp 6-digit vector"          "[PASS] totp 6-digit (287082)"
run_test "totp verify"                  "[PASS] totp verify (current ok, 000000 rejected)"

# ── JwsKey.FromJwkRsa — JWK n/e import for OIDC (v0.6.0) ──
run_test "jwk import + verify"          "[PASS] jws FromJwkRsa import + verify"
run_test "jwk rejects tampered input"   "[PASS] jws FromJwkRsa rejects tampered input"
run_test "jwk rejects bogus modulus"    "[PASS] jws FromJwkRsa rejects bogus modulus"

# ── JwsKey.FromCoseEc2 + SignDer/VerifyDer — WebAuthn (v0.7.0) ──
run_test "coseec2 + verifyder roundtrip" "[PASS] jws FromCoseEc2 + VerifyDer round-trip"
run_test "verifyder rejects tampered"    "[PASS] jws VerifyDer rejects tampered assertion"
# ── v0.8.0 — ECDH P-256 + AES-128-GCM (Web Push) ───────
run_test "ecdh public raw 65 bytes"      "[PASS] ecdh public raw is 65 bytes"
run_test "ecdh shared secret matches"    "[PASS] ecdh shared secret matches both ways (32 bytes)"
run_test "aes128gcm seal length"         "[PASS] aes128gcm seal length = pt + 16"

# ── Cleanup the symlinked build dir to leave the tree clean ──
rm -f "$WORK_BUILD_DIR"

# ── Summary ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}SKIP: $SKIP${NC}"
echo "────────────────────────────────────────────"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
