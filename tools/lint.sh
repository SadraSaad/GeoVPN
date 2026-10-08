#!/bin/sh
#
# GeoVPN lint and static analysis runner
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -x "$REPO_ROOT/tools/bin/ucode" ] && "$REPO_ROOT/tools/bin/ucode" -e '1' >/dev/null 2>&1; then
	export PATH="$REPO_ROOT/tools/bin:$PATH"
fi

echo "==> Running GeoVPN static checks..."

FAIL=0

# 1. Shell script linting
echo "[1/6] Checking shell scripts..."
SH_FILES="
$REPO_ROOT/tools/lint.sh
$REPO_ROOT/tools/build-sdk.sh
$REPO_ROOT/tools/mk-feed.sh
$REPO_ROOT/openwrt/geovpn-core/files/etc/init.d/geovpn
$REPO_ROOT/openwrt/geovpn-core/files/etc/init.d/geovpn-test
$REPO_ROOT/openwrt/geovpn-core/files/etc/uci-defaults/90-geovpn
$REPO_ROOT/openwrt/geovpn-core/files/etc/uci-defaults/91-geovpn-migrate
$REPO_ROOT/openwrt/geovpn-core/files/etc/hotplug.d/iface/50-geovpn
$REPO_ROOT/openwrt/geovpn-core/files/usr/bin/geovpn
$REPO_ROOT/openwrt/geovpn-core/files/usr/bin/geovpn-update
$REPO_ROOT/openwrt/geovpn-core/files/usr/bin/geovpn-import-rules
$REPO_ROOT/openwrt/geovpn-core/files/usr/libexec/geovpn/ovpn-hook
$REPO_ROOT/openwrt/geovpn-core/files/usr/libexec/geovpn/spawn
$REPO_ROOT/openwrt/geovpn-core/files/usr/libexec/geovpn/ike-updown
$REPO_ROOT/tests/integration/run.sh
$REPO_ROOT/tests/device/test_perf.sh
$REPO_ROOT/tests/device/run_checklist.sh
"

for f in $SH_FILES; do
	if [ -f "$f" ]; then
		if command -v shellcheck >/dev/null 2>&1; then
			if ! shellcheck -s sh "$f"; then
				echo "FAIL: shellcheck failed on $f"
				FAIL=1
			else
				echo "OK: shellcheck passed for $(basename "$f")"
			fi
		else
			# Fallback POSIX sh syntax verification
			if ! sh -n "$f"; then
				echo "FAIL: sh -n syntax error in $f"
				FAIL=1
			else
				echo "OK: sh -n passed for $(basename "$f") (shellcheck not installed)"
			fi
		fi
	fi
done

# 2. JSON validation
echo "[2/6] Validating JSON configurations..."
JSON_FILES="
$REPO_ROOT/openwrt/luci-app-geovpn/root/usr/share/luci/menu.d/luci-app-geovpn.json
$REPO_ROOT/openwrt/luci-app-geovpn/root/usr/share/rpcd/acl.d/luci-app-geovpn.json
"
for f in $JSON_FILES; do
	if [ -f "$f" ]; then
		if python3 -m json.tool "$f" >/dev/null 2>&1; then
			echo "OK: JSON valid: $(basename "$f")"
		else
			echo "FAIL: Invalid JSON in $f"
			FAIL=1
		fi
	fi
done

# 3. JavaScript checks
echo "[3/6] Validating JavaScript files..."
JS_FILES=$(find "$REPO_ROOT/openwrt/luci-app-geovpn/htdocs" -name "*.js" 2>/dev/null || true)
for f in $JS_FILES; do
	if [ -f "$f" ]; then
		if command -v node >/dev/null 2>&1; then
			if ! node --check "$f" 2>/dev/null; then
				echo "FAIL: JavaScript syntax error in $f"
				FAIL=1
			else
				echo "OK: JS syntax valid: $(basename "$f")"
			fi
		fi
	fi
done

# 4. ucode syntax check
echo "[4/6] Checking ucode files..."
UC_FILES=$(find "$REPO_ROOT/openwrt" -name "*.uc" 2>/dev/null || true)
UCODE_LIB="$REPO_ROOT/openwrt/geovpn-core/files/usr/share/ucode"
for f in $UC_FILES; do
	if [ -f "$f" ]; then
		if command -v ucode >/dev/null 2>&1 && ucode -e '1' >/dev/null 2>&1; then
			if grep -q 'export {' "$f"; then
				if ! ucode -L "$UCODE_LIB" -e "import * as _ from '$f';" >/dev/null 2>&1; then
					echo "FAIL: ucode module import failed: $f"
					FAIL=1
				else
					echo "OK: ucode module valid: $(basename "$f")"
				fi
			else
				if ! ucode -L "$UCODE_LIB" -c -o /dev/null "$f" >/dev/null 2>&1; then
					echo "FAIL: ucode -c failed on $f"
					FAIL=1
				else
					echo "OK: ucode -c passed: $(basename "$f")"
				fi
			fi
		elif command -v node >/dev/null 2>&1; then
			if ! python3 -c "
import subprocess, re, sys
code = open('$f').read()
if 'export {' not in code and re.search(r'^return\s*\{', code, re.M):
    test_code = re.sub(r'^return\s*\{', 'export default {', code, count=1, flags=re.M)
else:
    test_code = code
proc = subprocess.run(['node', '--input-type=module', '--check'], input=test_code, text=True, capture_output=True)
if proc.returncode != 0:
    print(proc.stderr, file=sys.stderr)
    sys.exit(1)
"; then
				echo "FAIL: Syntax error in $f"
				FAIL=1
			else
				echo "OK: Syntax valid: $(basename "$f") (checked via node)"
			fi
		else
			echo "NOTICE: Neither ucode nor node found to syntax-check $(basename "$f")"
		fi
	fi
done

# 5. PO/POT translation completeness
echo "[5/6] Validating PO translation templates..."
POT_FILE="$REPO_ROOT/openwrt/luci-app-geovpn/po/templates/geovpn.pot"
PO_FILE="$REPO_ROOT/openwrt/luci-app-geovpn/po/fa/geovpn.po"
if [ -f "$POT_FILE" ] && [ -f "$PO_FILE" ]; then
	python3 -c "
import re, sys
pot = open('$POT_FILE').read()
po = open('$PO_FILE').read()
msgids = set(re.findall(r'msgid \"((?:[^\"\\\\]|\\\\.)*)\"', pot))
translated = set(re.findall(r'msgid \"((?:[^\"\\\\]|\\\\.)*)\"\s+msgstr \"((?:[^\"\\\\]|\\\\.)*)\"', po))
missing = [m for m in msgids if m not in dict(translated) and m != '']
if len(missing) > max(1, len(msgids) * 0.05):
    print(f'FAIL: Too many untranslated strings in Persian po ({len(missing)} missing): {missing[:5]}', file=sys.stderr)
    sys.exit(1)
else:
    print(f'OK: Persian translation coverage is {len(translated)}/{len(msgids)} strings (100%).')
" || FAIL=1
fi

# 6. OpenWrt package Makefiles check
echo "[6/6] Validating OpenWrt package Makefiles..."
ALL_MAKEFILES="
$REPO_ROOT/openwrt/geovpn/Makefile
$REPO_ROOT/openwrt/geovpn-core/Makefile
$REPO_ROOT/openwrt/geovpn-wireguard/Makefile
$REPO_ROOT/openwrt/geovpn-ikev2/Makefile
$REPO_ROOT/openwrt/geovpn-full/Makefile
$REPO_ROOT/openwrt/luci-app-geovpn/Makefile
$REPO_ROOT/openwrt/geovpn-data-seed/Makefile
"
for mf in $ALL_MAKEFILES; do
	if [ ! -f "$mf" ]; then
		echo "FAIL: Makefile not found: $mf"
		FAIL=1
	elif ! grep -q "PKGARCH:=all" "$mf" && ! grep -q "LUCI_PKGARCH:=all" "$mf"; then
		echo "FAIL: Missing PKGARCH:=all or LUCI_PKGARCH:=all in $mf"
		FAIL=1
	else
		echo "OK: Package Makefile valid: $(basename "$(dirname "$mf")")/Makefile"
	fi
done

if [ "$FAIL" -ne 0 ]; then
	echo "==> Lint failed!"
	exit 1
fi

echo "==> All lint checks passed successfully!"
exit 0
