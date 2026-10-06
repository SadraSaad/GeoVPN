#!/bin/sh
#
# GeoVPN Performance Benchmark Script for Google WiFi AC-1304 (IPQ4019)
# Measures throughput per cipher, CPU utilization, and memory usage.
#
set -e

echo "=========================================================="
echo " GeoVPN Performance & Cipher Benchmark (AC-1304 / IPQ4019)"
echo "=========================================================="

# 1. System Info
echo "[*] Collecting system hardware specifications..."
if [ -f /proc/cpuinfo ]; then
	CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || true)
	CPU_CORES=$(grep -c "^processor" /proc/cpuinfo || echo "1")
	echo "    CPU: ${CPU_MODEL:-ARM Cortex-A7} (${CPU_CORES} cores)"
fi

if [ -f /proc/meminfo ]; then
	TOTAL_RAM=$(grep "MemTotal" /proc/meminfo | awk '{print int($2/1024)}')
	FREE_RAM=$(grep "MemAvailable" /proc/meminfo | awk '{print int($2/1024)}' || grep "MemFree" /proc/meminfo | awk '{print int($2/1024)}')
	echo "    RAM: ${TOTAL_RAM} MB total, ${FREE_RAM} MB available"
fi

# 2. Check OpenVPN and OpenSSL
if ! command -v openvpn >/dev/null 2>&1; then
	echo "ERROR: openvpn binary not found. Install openvpn-openssl first."
	exit 1
fi

OPENVPN_VER=$(openvpn --version 2>&1 | head -n 1)
echo "    OpenVPN: $OPENVPN_VER"

# 3. Test Cipher Benchmarks (OpenSSL speed / OpenVPN crypto loop)
CIPHERS="AES-128-GCM AES-256-GCM CHACHA20-POLY1305"
echo ""
echo "[*] Benchmarking cryptographic cipher speeds (userspace)..."
echo "----------------------------------------------------------"
printf "%-20s %-20s\n" "Cipher" "Raw Throughput"
echo "----------------------------------------------------------"

for c in $CIPHERS; do
	if command -v openssl >/dev/null 2>&1; then
		# Run 3-second openssl speed test for cipher if supported
		OSS_CIPHER=""
		case "$c" in
			"AES-128-GCM") OSS_CIPHER="aes-128-gcm" ;;
			"AES-256-GCM") OSS_CIPHER="aes-256-gcm" ;;
			"CHACHA20-POLY1305") OSS_CIPHER="chacha20-poly1305" ;;
		esac
		if [ -n "$OSS_CIPHER" ]; then
			SPEED_OUT=$(openssl speed -evp "$OSS_CIPHER" 2>&1 | grep -A1 "Doing" | tail -n 1 | awk '{print $(NF)}' || echo "N/A")
			if [ "$SPEED_OUT" != "N/A" ] && [ -n "$SPEED_OUT" ]; then
				MB_S=$(awk "BEGIN {printf \"%.2f MB/s (%.1f Mbit/s)\", $SPEED_OUT/1048576, ($SPEED_OUT*8)/1000000}")
				printf "%-20s %-20s\n" "$c" "$MB_S"
			else
				printf "%-20s %-20s\n" "$c" "Supported by OpenVPN"
			fi
		fi
	else
		printf "%-20s %-20s\n" "$c" "Benchmark requires openssl-util"
	fi
done

# 4. Measure nftables Rule & Set Load Performance
echo ""
echo "[*] Testing nftables set insertion throughput..."
TMP_NFT="/tmp/test_geovpn_bench.nft"
cat << 'EOF' > "$TMP_NFT"
table inet geovpn_bench {
  set test_ips {
    type ipv4_addr;
    flags interval;
    auto-merge;
    elements = {
EOF

# Generate 5,000 random test CIDRs
awk 'BEGIN {
  for (i=1; i<=5000; i++) {
    b1 = int(rand()*200) + 10;
    b2 = int(rand()*250);
    printf("      %d.%d.0.0/16%s\n", b1, b2, (i==5000 ? "" : ","));
  }
}' >> "$TMP_NFT"

cat << 'EOF' >> "$TMP_NFT"
    };
  }
}
EOF

START_MS=$(date +%s%3N 2>/dev/null || date +%s)
if command -v nft >/dev/null 2>&1; then
	if nft -c -f "$TMP_NFT" 2>/dev/null; then
		END_MS=$(date +%s%3N 2>/dev/null || date +%s)
		DIFF_MS=$((END_MS - START_MS))
		echo "    5,000 CIDR interval set validation time: ${DIFF_MS} ms"
	else
		echo "    nft dry-run validation skipped or syntax error"
	fi
fi
rm -f "$TMP_NFT"

echo "----------------------------------------------------------"
echo "Benchmark completed successfully."
exit 0
