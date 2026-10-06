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

echo "==> Creating GeoVPN apk repository..."
mkdir -p "$FEED_DIR"

if [ ! -d "$PKG_DIR" ]; then
	echo "ERROR: Package directory $PKG_DIR not found."
	exit 1
fi

echo "--> Copying .apk files..."
cp -f "$PKG_DIR"/*.apk "$FEED_DIR/" 2>/dev/null || true

cd "$FEED_DIR"

echo "--> Generating package index (packages.adb)..."
if command -v apk >/dev/null 2>&1; then
	if [ -f "$KEY_PATH" ]; then
		apk mkndx --output packages.adb ./*.apk
		echo "--> Signing package index..."
		apk adbsign --sign-key "$KEY_PATH" packages.adb
	else
		echo "NOTICE: No signing key found at $KEY_PATH. Generating unsigned index."
		apk mkndx --output packages.adb ./*.apk
	fi
else
	echo "NOTICE: apk tool not found locally. Generating SHA256SUMS."
	sha256sum ./*.apk > SHA256SUMS 2>/dev/null || true
fi

echo "==> Feed ready at $FEED_DIR."
ls -la "$FEED_DIR"
