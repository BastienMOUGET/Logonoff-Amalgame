#!/bin/bash
# amalgame-formats-xlsx — test runner. Requires amc 0.8.40+, python3;
# LibreOffice (soffice) optional: when present, formulas are evaluated.
set -u
AMC="${1:-${AMC:-$(command -v amc)}}"
[ -x "$AMC" ] || { echo "ERROR: amc not found" >&2; exit 2; }
AMC="$(cd "$(dirname "$AMC")" && pwd)/$(basename "$AMC")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -n "${AMC_RUNTIME:-}" ]; then :
elif [ -d "$(dirname "$AMC")/../share/amalgame/runtime" ]; then AMC_RUNTIME="$(cd "$(dirname "$AMC")/../share/amalgame/runtime" && pwd)"
elif [ -d "$(dirname "$AMC")/runtime" ]; then AMC_RUNTIME="$(dirname "$AMC")/runtime"
else echo "ERROR: amc runtime/ not found" >&2; exit 2; fi
LIBAM="$(dirname "$AMC_RUNTIME")/lib/libamalgame.a"

B="$(mktemp -d -t afxlsx-XXXXXX)"
trap 'rm -rf "$B"' EXIT
PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# Fake package cache so `import Amalgame.Formats.Xlsx` resolves here.
CACHE="$B/cache/github.com/amalgame-lang/amalgame-formats-xlsx"
mkdir -p "$CACHE" "$B/proj"
ln -s "$PKG_ROOT" "$CACHE/v0.1.0_deadbeef"
printf '[[package]]\nname = "amalgame-formats-xlsx"\ngit  = "github.com/amalgame-lang/amalgame-formats-xlsx"\ntag  = "v0.1.0"\nrev  = "deadbeefcafebabe0000000000000000000000ab"\n' > "$B/proj/amalgame.lock"
export AMALGAME_PACKAGES_DIR="$B/cache"

echo "── facade"
"$AMC" --lib --quiet "$PKG_ROOT/facade.am" -o "$B/Xlsx-facade" >/dev/null 2>&1 || { ko "facade transpile"; exit 1; }
gcc -O2 -Wall -Wno-unused -I"$AMC_RUNTIME" -c "$B/Xlsx-facade.c" -o "$B/Xlsx-facade.o" 2> "$B/cc.log" || { cat "$B/cc.log"; ko "facade compile"; exit 1; }
ar rcs "$B/libamalgame-pkg-Xlsx.a" "$B/Xlsx-facade.o"
ok "facade builds"

echo "── test program"
cp "$SCRIPT_DIR/xlsx_test.am" "$B/proj/test.am"
(cd "$B/proj" && "$AMC" -o test test.am --quiet >/dev/null 2>&1) || { ko "test transpile"; exit 1; }
EXTRA=""; [ -f "$LIBAM" ] && EXTRA="$LIBAM"
gcc -O2 -w -I"$AMC_RUNTIME" "$B/proj/test.c" "$B/libamalgame-pkg-Xlsx.a" $EXTRA -lgc -lm -lpthread -o "$B/proj/test" || { ko "test link"; exit 1; }
OUT="$("$B/proj/test" "$B/out.xlsx")"
echo "$OUT" | sed 's/^/  /'
PASS=$((PASS + $(echo "$OUT" | grep -c '\[PASS\]')))
FAIL=$((FAIL + $(echo "$OUT" | grep -c '\[FAIL\]')))

echo "── container (python zipfile + XML parser)"
if python3 -I - "$B/out.xlsx" <<'PY'
import sys, zipfile, xml.dom.minidom
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None
names = z.namelist()
for need in ["[Content_Types].xml", "xl/workbook.xml", "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"]:
    assert need in names, need
for n in names:
    xml.dom.minidom.parseString(z.read(n))
s1 = z.read("xl/worksheets/sheet1.xml").decode("utf-8")
assert "IMP-114 « Réunion » &amp; co" in s1
assert '<pane ySplit="1"' in s1 and '<autoFilter ref="A1:D3"/>' in s1
assert '<f>SUM(C2:C3)</f>' in s1
PY
then ok "valid zip + well-formed XML"; else ko "valid zip + well-formed XML"; fi

if command -v soffice >/dev/null 2>&1; then
    echo "── LibreOffice (formulas evaluated)"
    (cd "$B" && timeout 120 soffice --headless --convert-to csv:"Text - txt - csv (StarCalc)":44,34,76,1,,0,false,true,false,false,false,-1 out.xlsx >/dev/null 2>&1)
    CSV="$(cat "$B"/out*.csv 2>/dev/null)"
    echo "$CSV" | sed 's/^/  /'
    if echo "$CSV" | grep -q "Total,26:30" && echo "$CSV" | grep -q "IMP-114.*,14:00" && echo "$CSV" | grep -q "26/10/2026"; then
        ok "LibreOffice opens it, SUM over [h]:mm = 26:30"
    else
        ko "LibreOffice evaluation"
    fi
fi

echo ""
echo "PASS: $PASS | FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
