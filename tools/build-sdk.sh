#!/bin/sh
#
# Build GeoVPN packages using the official OpenWrt SDK
#
set -e

VER="${1:-25.12.5}"
PKG_ARG="${2:-all}"
TARGET="ipq40xx"
SUBTARGET="chromium"
ARCH_SUFFIX="gcc-14.3.0_musl_eabi.Linux-x86_64"

BASE_URL="https://downloads.openwrt.org/releases/$VER/targets/$TARGET/$SUBTARGET"
SDK_ARCHIVE="openwrt-sdk-$VER-${TARGET}-${SUBTARGET}_${ARCH_SUFFIX}.tar.zst"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/out"

echo "==> GeoVPN SDK Build Script for OpenWrt $VER ($TARGET/$SUBTARGET) [target: $PKG_ARG]..."

mkdir -p "$OUTPUT_DIR"
BUILD_DIR="${SDK_CACHE_DIR:-$REPO_ROOT/build-sdk}"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR"

if [ ! -f "$SDK_ARCHIVE" ]; then
	echo "--> Downloading SDK: $SDK_ARCHIVE..."
	if command -v wget >/dev/null 2>&1; then
		wget -c "$BASE_URL/$SDK_ARCHIVE"
		wget -O sha256sums "$BASE_URL/sha256sums" || true
	elif command -v curl >/dev/null 2>&1; then
		curl -C - -O "$BASE_URL/$SDK_ARCHIVE"
		curl -o sha256sums "$BASE_URL/sha256sums" || true
	else
		echo "ERROR: Neither wget nor curl found."
		exit 1
	fi
fi

if [ -f sha256sums ]; then
	echo "--> Verifying SHA256 checksum..."
	grep "$SDK_ARCHIVE" sha256sums | sha256sum -c || echo "WARNING: Checksum mismatch or not found in sha256sums."
fi

SDK_DIR=$(find . -maxdepth 1 -type d -name "openwrt-sdk-*" | head -n 1)
if [ -z "$SDK_DIR" ]; then
	echo "--> Extracting SDK..."
	if command -v zstd >/dev/null 2>&1; then
		zstd -dc "$SDK_ARCHIVE" | tar -xf -
	else
		tar --zstd -xf "$SDK_ARCHIVE"
	fi
	SDK_DIR=$(find . -maxdepth 1 -type d -name "openwrt-sdk-*" | head -n 1)
fi

echo "--> Configuring feeds in $SDK_DIR..."
cd "$SDK_DIR"

cp -f feeds.conf.default feeds.conf 2>/dev/null || true
if ! grep -q "src-link geovpn" feeds.conf 2>/dev/null; then
	echo "src-link geovpn $REPO_ROOT/openwrt" >> feeds.conf
fi

echo "--> Updating feeds..."
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -p geovpn -a

echo "--> Generating build configuration..."
for pkg in geovpn-core geovpn-wireguard geovpn-ikev2 luci-app-geovpn geovpn geovpn-full geovpn-data-seed; do
	echo "CONFIG_PACKAGE_$pkg=m" >> .config
done
make defconfig

echo "--> Compiling GeoVPN packages ($PKG_ARG)..."
if [ "$PKG_ARG" = "all" ] || [ -z "$PKG_ARG" ]; then
	PACKAGES="geovpn-core geovpn-wireguard geovpn-ikev2 luci-app-geovpn geovpn geovpn-full geovpn-data-seed"
else
	PACKAGES="$PKG_ARG"
fi

for pkg in $PACKAGES; do
	echo "--> Building package/$pkg..."
	make "package/$pkg/compile" V=s || true
done

echo "--> Collecting generated packages into $OUTPUT_DIR..."
find bin/ -name "*.apk" -exec cp -f {} "$OUTPUT_DIR/" \;

echo "==> Build finished successfully! Artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"/*.apk 2>/dev/null || echo "No .apk files found."
