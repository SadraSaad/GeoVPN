#!/bin/sh
#
# GeoVPN lint and static analysis runner
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Running GeoVPN static checks..."

FAIL=0

# 1. Shell script linting
echo "[1/5] Checking shell scripts..."
SH_FILES="
$REPO_ROOT/tools/lint.sh
$REPO_ROOT/tools/build-sdk.sh
$REPO_ROOT/tools/mk-feed.sh
$REPO_ROOT/openwrt/geovpn-core/files/etc/init.d/geovpn
$REPO_ROOT/openwrt/geovpn-core/files/etc/uci-defaults/90-geovpn
$REPO_ROOT/openwrt/geovpn-core/files/etc/hotplug.d/iface/50-geovpn
$REPO_ROOT/openwrt/geovpn-core/files/usr/bin/geovpn
$REPO_ROOT/openwrt/geovpn-core/files/usr/bin/geovpn-update
$REPO_ROOT/openwrt/geovpn-core/files/usr/libexec/geovpn/ovpn-hook
$REPO_ROOT/openwrt/geovpn-core/files/usr/libexec/geovpn/spawn
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
echo "[2/5] Validating JSON configurations..."
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
echo "[3/5] Validating JavaScript files..."
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
echo "[4/5] Checking ucode files..."
UC_FILES=$(find "$REPO_ROOT" -name "*.uc" 2>/dev/null || true)
for f in $UC_FILES; do
	if [ -f "$f" ]; then
		if command -v ucode >/dev/null 2>&1; then
			if ! ucode -c "$f"; then
				echo "FAIL: ucode -c failed on $f"
				FAIL=1
			else
				echo "OK: ucode -c passed: $(basename "$f")"
			fi
		else
			# Fallback: check basic parenthesis/bracket/brace balance and non-empty
			python3 -c "
import sys
content = open('$f').read()
stack = []
pairs = {')': '(', ']': '[', '}': '{'}
in_str = None
escape = False
for idx, ch in enumerate(content):
    if escape:
        escape = False
        continue
    if ch == '\\\\':
        escape = True
        continue
    if in_str:
        if ch == in_str:
            in_str = None
        continue
    if ch in ('\"', \"'\"):
        in_str = ch
        continue
    if ch in '([{':
        stack.append((ch, idx))
    elif ch in ')]}':
        if not stack or stack[-1][0] != pairs[ch]:
            print(f'Mismatched bracket {ch} at index {idx} in $f', file=sys.stderr)
            sys.exit(1)
        stack.pop()
if stack:
    print(f'Unclosed {stack[-1][0]} at index {stack[-1][1]} in $f', file=sys.stderr)
    sys.exit(1)
" || { echo "FAIL: Structural syntax check failed for $f"; FAIL=1; }
			echo "OK: Structural syntax check passed: $(basename "$f") (ucode binary not installed)"
		fi
	fi
done

# 5. PO/POT translation completeness
echo "[5/5] Validating PO translation templates..."
POT_FILE="$REPO_ROOT/openwrt/luci-app-geovpn/po/templates/geovpn.pot"
PO_FILE="$REPO_ROOT/openwrt/luci-app-geovpn/po/fa/geovpn.po"
if [ -f "$POT_FILE" ] && [ -f "$PO_FILE" ]; then
	python3 -c "
import re, sys
pot = open('$POT_FILE').read()
po = open('$PO_FILE').read()
msgids = set(re.findall(r'msgid \"([^\"]+)\"', pot))
translated = set(re.findall(r'msgid \"([^\"]+)\"\s+msgstr \"([^\"]+)\"', po))
missing = [m for m in msgids if m not in dict(translated) and m != '']
if len(missing) > max(1, len(msgids) * 0.05):
    print(f'FAIL: Too many untranslated strings in Persian po ({len(missing)} missing): {missing[:5]}', file=sys.stderr)
    sys.exit(1)
else:
    print(f'OK: Persian translation coverage is {len(translated)}/{len(msgids)} strings.')
" || FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
	echo "==> Lint failed!"
	exit 1
fi

echo "==> All lint checks passed successfully!"
exit 0
