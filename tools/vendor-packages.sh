#!/usr/bin/env bash
# vendor-packages.sh — fill ./packages/ with every Amalgame package the
# build needs, in amc's cache layout (github.com/<org>/<name>/<tag>_<rev8>).
#
# build.sh points AMALGAME_PACKAGES_DIR at ./packages, so `amc package add`
# finds each <tag>_* directory, skips the git clone and only precompiles:
# the Windows build works offline and picks up package changes that are
# not tagged on GitHub yet.
#
# Sources:
#   - packages modified for Logonoff: the local working tree (sibling
#     clone in ~/Développement), under a local tag and a fixed fake rev;
#   - the others: the copy already in ~/.amalgame/packages.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="${DEV_DIR:-$HOME/Développement}"
CACHE="${AMC_CACHE:-$HOME/.amalgame/packages}/github.com/amalgame-lang"
OUT="packages/github.com/amalgame-lang"
LOCAL_REV="10ca1000"

rm -rf packages
mkdir -p "$OUT"

# name|tag  — from the local working tree
LOCAL=(
  "amalgame-service|v0.3.0"
  "amalgame-datetime|v0.3.0"
  "amalgame-net-http|v0.30.0"
)
# name|tag  — from the amc cache
CACHED=(
  "amalgame-database-sqlite|v0.4.0"
  "amalgame-threading|v0.1.0"
  "amalgame-async|v0.4.1"
  "amalgame-tls|v0.3.6"
  "amalgame-crypto|v0.8.0"
)

copy_tree() {  # src dst — no VCS, no per-platform build output
  mkdir -p "$2"
  tar -C "$1" --exclude=.git --exclude=build --exclude=.claude --exclude=bench -cf - . | tar -C "$2" -xf -
}

for e in "${LOCAL[@]}"; do
  IFS='|' read -r name tag <<<"$e"
  [ -d "$DEV/$name" ] || { echo "missing $DEV/$name" >&2; exit 1; }
  copy_tree "$DEV/$name" "$OUT/$name/${tag}_${LOCAL_REV}"
  echo "local   $name $tag"
done
for e in "${CACHED[@]}"; do
  IFS='|' read -r name tag <<<"$e"
  src=$(ls -d "$CACHE/$name/${tag}_"* 2>/dev/null | head -1)
  [ -n "$src" ] || { echo "missing $name@$tag in $CACHE (amc package add it once)" >&2; exit 1; }
  copy_tree "$src" "$OUT/$name/$(basename "$src")"
  echo "cached  $name $tag ($(basename "$src"))"
done

# Pin inter-package dependencies to the vendored tags. A short form like
# `amalgame-crypto = ">=0.3.0"` makes `amc package add` resolve the name
# through the online packages-index whenever the dependency has no
# runtime/ dir (crypto has none) — which fails offline or behind a TLS
# intercepting proxy. The table form (git + tag) resolves from the cache.
python3 - "$OUT" "${LOCAL[@]}" "${CACHED[@]}" <<'PY'
import os, re, sys
out, specs = sys.argv[1], sys.argv[2:]
tags = dict(s.split("|") for s in specs)
for name in os.listdir(out):
    for ver in os.listdir(os.path.join(out, name)):
        path = os.path.join(out, name, ver, "amalgame.toml")
        text = open(path, encoding="utf-8").read()
        def pin(m):
            dep = m.group(1)
            if dep not in tags:
                return m.group(0)
            return ('[dependencies.%s]\ngit = "github.com/amalgame-lang/%s"\ntag = "%s"\n'
                    % (dep, dep, tags[dep]))
        head, sep, tail = text.partition("[dependencies]\n")
        if not sep:
            continue
        body_end = re.search(r"^\[", tail, re.M)
        body = tail[:body_end.start()] if body_end else tail
        rest = tail[body_end.start():] if body_end else ""
        pinned = re.sub(r'^(amalgame-[a-z0-9-]+)\s*=\s*"[^"]*"\s*\n', pin, body, flags=re.M)
        if pinned != body:
            # Table entries must follow every bare key of [dependencies].
            bare = "".join(l for l in pinned.splitlines(True) if not l.startswith(("[dependencies.", "git =", "tag =")))
            tables = "".join(l for l in pinned.splitlines(True) if l.startswith(("[dependencies.", "git =", "tag =")))
            open(path, "w", encoding="utf-8").write(head + sep + bare + "\n" + tables + rest)
            print("pinned deps  " + name + " " + ver)
PY

