#!/bin/sh
#
# Create and sign an apk repository feed for GeoVPN
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$REPO_ROOT/tools/bin:$PATH"

PKG_DIR="${1:-$REPO_ROOT/out}"
FEED_DIR="${2:-$REPO_ROOT/feed/25.12}"
KEY_PATH="${APK_SIGN_KEY:-$REPO_ROOT/keys/geovpn.pem}"

# Ensure absolute paths before changing directory
case "$PKG_DIR" in /*) ;; *) PKG_DIR="$REPO_ROOT/$PKG_DIR" ;; esac
case "$FEED_DIR" in /*) ;; *) FEED_DIR="$REPO_ROOT/$FEED_DIR" ;; esac
case "$KEY_PATH" in /*) ;; *) KEY_PATH="$REPO_ROOT/$KEY_PATH" ;; esac

echo "==> Creating GeoVPN apk repository..."
mkdir -p "$FEED_DIR"

if [ ! -d "$PKG_DIR" ]; then
	echo "ERROR: Package directory $PKG_DIR not found."
	exit 1
fi

echo "--> Copying .apk files..."
cp -f "$PKG_DIR"/*.apk "$FEED_DIR/" 2>/dev/null || true

cd "$FEED_DIR"

echo "--> Checking available packages in $FEED_DIR..."
APK_COUNT=$(ls -1 ./*.apk 2>/dev/null | wc -l || echo 0)
if [ "$APK_COUNT" -eq 0 ]; then
	echo "NOTICE: No .apk files found in $FEED_DIR. Preparing directory."
else
	echo "--> Found $APK_COUNT package(s):"
	ls -1 ./*.apk 2>/dev/null || true
fi

echo "--> Generating package checksums (SHA256SUMS)..."
if [ "$APK_COUNT" -gt 0 ]; then
	sha256sum ./*.apk > SHA256SUMS 2>/dev/null || true
fi

echo "--> Generating package index (packages.adb)..."
if command -v apk >/dev/null 2>&1 && apk mkndx --help >/dev/null 2>&1; then
	if [ "$APK_COUNT" -gt 0 ]; then
		if [ -f "$KEY_PATH" ]; then
			apk mkndx --output packages.adb ./*.apk 2>/dev/null || apk mkndx -o packages.adb ./*.apk 2>/dev/null || true
			echo "--> Signing package index..."
			apk adbsign --sign-key "$KEY_PATH" packages.adb 2>/dev/null || true
		else
			echo "NOTICE: No signing key found at $KEY_PATH. Generating unsigned index."
			apk mkndx --output packages.adb ./*.apk 2>/dev/null || apk mkndx -o packages.adb ./*.apk 2>/dev/null || true
		fi
	fi
else
	echo "NOTICE: apk mkndx not available in local environment. SHA256SUMS index generated."
fi

echo "==> Feed ready at $FEED_DIR."
ls -la "$FEED_DIR"
