#!/usr/bin/env bash
# build.sh — build Logonoff on Linux (dev) or Windows (MSYS2 MINGW64 shell).
#
# Same recipe as musicall-server: `amc` transpiles, gcc links against the
# package archives. Packages come from ./packages (see
# tools/vendor-packages.sh) through AMALGAME_PACKAGES_DIR, so no network
# is needed and locally modified packages are picked up.
#
# Windows prerequisites (MSYS2 MINGW64):
#   pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-gc \
#             mingw-w64-x86_64-openssl mingw-w64-x86_64-nghttp2
#   amc ≥ 0.8.90 on PATH (bin/amc.exe from the release zip).
#
# Output: dist/ — the executable, www/, install scripts and (Windows) the
# MinGW DLLs it needs, ready to copy to C:\Program Files\Logonoff.
set -euo pipefail
cd "$(dirname "$0")"

log()  { printf '\033[1;32m→ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) PLAT="windows-x86_64"; EXE="logonoff.exe"; WIN=1 ;;
    Linux*)               PLAT="linux-$(uname -m)"; EXE="logonoff"; WIN=0 ;;
    *) die "unsupported platform $(uname -s)" ;;
esac
PLAT="${PLAT/aarch64/arm64}"

AMC="${AMC:-$(command -v amc || true)}"
[ -n "$AMC" ] || die "amc not on PATH (or set AMC=/path/to/amc)"
PREFIX="$(cd "$(dirname "$AMC")/.." && pwd)"
AMC_RUNTIME="${AMC_RUNTIME:-$PREFIX/share/amalgame/runtime}"
LIBAMALGAME="${LIBAMALGAME:-$PREFIX/share/amalgame/lib/libamalgame.a}"
[ -d "$AMC_RUNTIME" ] || die "amc runtime not found at $AMC_RUNTIME (set AMC_RUNTIME)"
[ -f "$LIBAMALGAME" ] || die "libamalgame.a not found at $LIBAMALGAME (set LIBAMALGAME)"

[ -d packages ] || die "packages/ missing — run tools/vendor-packages.sh on the dev machine"
export AMALGAME_PACKAGES_DIR="$PWD/packages"

# Order matters: dependencies before dependants (tls needs crypto,
# net-http needs tls + async).
PKGS=(crypto@v0.8.0 async@v0.4.1 tls@v0.3.6 net-http@v0.30.0 threading@v0.1.0
      database-sqlite@v0.4.0 datetime@v0.3.0 service@v0.3.0 formats-xlsx@v0.1.0)

mkdir -p build
log "Packages ($PLAT, offline from ./packages)"
for p in "${PKGS[@]}"; do
    name="${p%@*}"; tag="${p#*@}"
    dir=$(ls -d "packages/github.com/amalgame-lang/amalgame-$name/${tag}_"* 2>/dev/null | head -1)
    [ -n "$dir" ] || die "packages/ has no amalgame-$name $tag"
    stamp="$dir/build/$PLAT/.logonoff-precompiled"
    [ -f "$stamp" ] && continue
    # amalgame-tls' ACME facade doesn't compile in this setup; Logonoff
    # only needs its header (net-http's TLS paths), so a failed facade is
    # tolerated — the link step is the real gate.
    "$AMC" package add "github.com/amalgame-lang/amalgame-$name@$tag" >"build/pkg-$name.log" 2>&1 \
        || die "amc package add $name@$tag (see build/pkg-$name.log)"
    # No stamp on a failed facade, so the next build retries it.
    if grep -q "FAILED" "build/pkg-$name.log"; then
        warn "$name: facade not precompiled (see build/pkg-$name.log)"
    else
        mkdir -p "$dir/build/$PLAT" && touch "$stamp"
    fi
    echo "  precompiled $name $tag"
done

# Dependency order: cgen is single-pass, a class must be emitted before
# code that touches its fields.
SOURCES=(src/platform.am src/store.am src/timecalc.am src/tracker.am src/web.am src/main.am)
OUT="build/logonoff"
mkdir -p build
log "Transpile (${SOURCES[*]})"
"$AMC" "${SOURCES[@]}" -o "$OUT" || die "amc failed"
[ -f "$OUT.c" ] || die "amc produced no $OUT.c"

# Include dirs + archives + system libs, from the lock file (musicall recipe).
PKG_INCLUDES=(); PKG_ARCHIVES=(); SYS_LIBS=()
while IFS='|' read -r name git tag rev; do
    [ -z "${name:-}" ] && continue
    PKG_DIR="$AMALGAME_PACKAGES_DIR/$git/${tag}_${rev}"
    [ -d "$PKG_DIR" ] || { warn "package dir missing for $name"; continue; }
    [ -d "$PKG_DIR/runtime" ] && PKG_INCLUDES+=(-I"$PKG_DIR/runtime")
    # Archives when the package has them, else its loose objects (vendored C).
    mapfile -t AS < <(find "$PKG_DIR/build/$PLAT" -maxdepth 1 -name '*.a' 2>/dev/null | sort)
    if [ "${#AS[@]}" -eq 0 ]; then
        mapfile -t AS < <(find "$PKG_DIR/build/$PLAT" -maxdepth 1 -name '*.o' 2>/dev/null | sort)
    fi
    PKG_ARCHIVES+=("${AS[@]}")
    while IFS= read -r lib; do [ -n "$lib" ] && SYS_LIBS+=("-l$lib"); done < <(awk '/^libs[[:space:]]*=/,/]/' "$PKG_DIR/amalgame.toml" | grep -oE '"[a-z0-9_+.-]+"' | tr -d '"' || true)
done < <(awk '
    /^\[\[package\]\]/ { if (name!="") print name "|" git "|" tag "|" rev; name=""; git=""; tag=""; rev=""; next }
    /^[[:space:]]*name[[:space:]]*=/ { match($0, /"[^"]*"/); name=substr($0,RSTART+1,RLENGTH-2) }
    /^[[:space:]]*git[[:space:]]*=/  { match($0, /"[^"]*"/); git=substr($0,RSTART+1,RLENGTH-2) }
    /^[[:space:]]*tag[[:space:]]*=/  { match($0, /"[^"]*"/); tag=substr($0,RSTART+1,RLENGTH-2) }
    /^[[:space:]]*rev[[:space:]]*=/  { match($0, /"[^"]*"/); rev=substr($0,RSTART+1,RLENGTH-2) }
    END { if (name!="") print name "|" git "|" tag "|" rev }' amalgame.lock)

# nghttp2 is optional (net-http falls back to a stub without its headers,
# and Logonoff doesn't use HTTP/2): drop it when the headers are absent.
if ! echo '#include <nghttp2/nghttp2.h>' | gcc -E -x c - >/dev/null 2>&1; then
    F=(); for l in "${SYS_LIBS[@]}"; do [ "$l" = "-lnghttp2" ] || F+=("$l"); done; SYS_LIBS=("${F[@]}")
fi

# Deduplicate system libs, keep order.
declare -A seen; LIBS=()
for l in "${SYS_LIBS[@]}"; do [ -n "${seen[$l]:-}" ] || { seen[$l]=1; LIBS+=("$l"); }; done

EXTRA=()
if [ "$WIN" = 1 ]; then
    EXTRA=(-lws2_32 -lbcrypt -lshell32 -luser32 -ladvapi32)
    # Version info + icon when windres is available.
    if command -v windres >/dev/null && [ -f packaging/logonoff.rc ]; then
        windres --include-dir packaging packaging/logonoff.rc -O coff -o build/logonoff-res.o && EXTRA=(build/logonoff-res.o "${EXTRA[@]}")
    fi
else
    EXTRA=(-ldl)
fi

log "Link → $EXE"
gcc -O2 -pthread -w -I"$AMC_RUNTIME" "${PKG_INCLUDES[@]}" "$OUT.c" \
    -Wl,--start-group "${PKG_ARCHIVES[@]}" "$LIBAMALGAME" -Wl,--end-group \
    -lgc -lm "${LIBS[@]}" "${EXTRA[@]}" -o "build/$EXE" || die "gcc failed"

log "Stage dist/"
rm -rf dist && mkdir -p dist
cp "build/$EXE" dist/
cp -r www dist/www
if [ "$WIN" = 1 ]; then
    cp packaging/install.cmd packaging/uninstall.cmd dist/
    # A service doesn't see the MSYS2 PATH: ship the MinGW DLLs next to the exe.
    copy_deps() {
        ldd "$1" 2>/dev/null | awk '/\/mingw64\/bin\// {print $3}' | while read -r dep; do
            base=$(basename "$dep")
            [ -f "dist/$base" ] || { cp "$dep" "dist/$base"; copy_deps "dist/$base"; }
        done
    }
    copy_deps "dist/$EXE"
fi
printf '\033[1;32m✓ dist/%s\033[0m\n' "$EXE"
