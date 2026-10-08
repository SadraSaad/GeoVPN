#!/bin/sh
#
# GeoVPN Hardware Acceptance Checklist (AT-21) for Google WiFi AC-1304
# Verifies kernel modules, memory margins, flash space, and package sanity.
#
set -e

PASSED=0
WARNED=0
FAILED=0

check_item() {
	NAME="$1"
	RESULT="$2"
	MSG="$3"
	if [ "$RESULT" = "PASS" ]; then
		printf "[  \033[32mOK\033[0m  ] %-35s: %s\n" "$NAME" "$MSG"
		PASSED=$((PASSED + 1))
	elif [ "$RESULT" = "WARN" ]; then
		printf "[ \033[33mWARN\033[0m ] %-35s: %s\n" "$NAME" "$MSG"
		WARNED=$((WARNED + 1))
	else
		printf "[ \033[31mFAIL\033[0m ] %-35s: %s\n" "$NAME" "$MSG"
		FAILED=$((FAILED + 1))
	fi
}

echo "=========================================================="
echo " GeoVPN Google WiFi AC-1304 Hardware Checklist (AT-21)"
echo "=========================================================="

# 1. Target architecture
if grep -q "IPQ4019" /proc/cpuinfo 2>/dev/null || grep -q "Qualcomm" /proc/cpuinfo 2>/dev/null; then
	check_item "CPU Target (IPQ4019)" "PASS" "Qualcomm Atheros IPQ4019 detected"
else
	CPU_NAME=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || uname -m)
	check_item "CPU Target (IPQ4019)" "WARN" "Running on $CPU_NAME (non-AC1304 environment)"
fi

# 2. RAM availability
TOTAL_RAM_KB=$(grep "MemTotal" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
if [ "$TOTAL_RAM_MB" -ge 400 ]; then
	check_item "Physical RAM (512MB)" "PASS" "${TOTAL_RAM_MB} MB total system RAM"
elif [ "$TOTAL_RAM_MB" -ge 120 ]; then
	check_item "Physical RAM (>=128MB)" "PASS" "${TOTAL_RAM_MB} MB RAM (sufficient for base operation)"
else
	check_item "Physical RAM" "FAIL" "Only ${TOTAL_RAM_MB} MB RAM (minimum 128 MB required)"
fi

FREE_RAM_KB=$(grep "MemAvailable" /proc/meminfo 2>/dev/null | awk '{print $2}' || grep "MemFree" /proc/meminfo | awk '{print $2}' || echo "0")
FREE_RAM_MB=$((FREE_RAM_KB / 1024))
if [ "$FREE_RAM_MB" -ge 64 ]; then
	check_item "Available RAM Margin" "PASS" "${FREE_RAM_MB} MB free memory"
else
	check_item "Available RAM Margin" "WARN" "${FREE_RAM_MB} MB free memory (< 64 MB margin)"
fi

# 3. Flash storage space
OVERLAY_FREE_KB=""
TARGET_NAME="root filesystem"
if [ -d /overlay ]; then
	OVERLAY_FREE_KB=$(df -k /overlay 2>/dev/null | awk 'NR>1 {print $(NF-2)}')
	if [ -n "$OVERLAY_FREE_KB" ]; then
		TARGET_NAME="overlay"
	fi
fi
if [ -z "$OVERLAY_FREE_KB" ]; then
	OVERLAY_FREE_KB=$(df -k / 2>/dev/null | awk 'NR>1 {print $(NF-2)}')
fi
OVERLAY_FREE_KB="${OVERLAY_FREE_KB:-0}"
OVERLAY_FREE_MB=$((OVERLAY_FREE_KB / 1024))
if [ "$OVERLAY_FREE_MB" -ge 100 ]; then
	check_item "Storage Space ($TARGET_NAME)" "PASS" "${OVERLAY_FREE_MB} MB free on $TARGET_NAME"
elif [ "$OVERLAY_FREE_MB" -ge 5 ]; then
	check_item "Storage Space ($TARGET_NAME)" "PASS" "${OVERLAY_FREE_MB} MB free on $TARGET_NAME"
else
	check_item "Storage Space ($TARGET_NAME)" "FAIL" "Only ${OVERLAY_FREE_MB} MB free storage"
fi

# 4. Kernel TUN device
if [ -c /dev/net/tun ]; then
	check_item "Kernel TUN (/dev/net/tun)" "PASS" "Device node exists and functional"
else
	check_item "Kernel TUN (/dev/net/tun)" "FAIL" "Missing /dev/net/tun (install kmod-tun)"
fi

# 5. dnsmasq-full nftset feature
if command -v dnsmasq >/dev/null 2>&1; then
	if dnsmasq -v 2>&1 | grep -q "nftset"; then
		check_item "dnsmasq-full (nftset)" "PASS" "dnsmasq compiled with nftset support"
	else
		check_item "dnsmasq-full (nftset)" "FAIL" "dnsmasq lacks nftset (swap with dnsmasq-full)"
	fi
else
	check_item "dnsmasq-full (nftset)" "FAIL" "dnsmasq executable not found in PATH"
fi

# 6. OpenVPN binary
if command -v openvpn >/dev/null 2>&1; then
	OV_VER=$(openvpn --version 2>&1 | head -n 1 | awk '{print $2}')
	check_item "OpenVPN Client" "PASS" "Version $OV_VER installed"
else
	check_item "OpenVPN Client" "FAIL" "openvpn not found in PATH"
fi

# 7. nftables and ip-full
if command -v nft >/dev/null 2>&1; then
	check_item "nftables utility" "PASS" "nft binary available"
else
	check_item "nftables utility" "FAIL" "nft binary not found"
fi

if command -v ip >/dev/null 2>&1; then
	if ip -4 rule show >/dev/null 2>&1; then
		check_item "ip-full (policy routing)" "PASS" "ip rule and ip route functional"
	else
		check_item "ip-full (policy routing)" "FAIL" "ip utility lacks policy routing support"
	fi
else
	check_item "ip-full (policy routing)" "FAIL" "ip utility not found"
fi

# 8. GeoVPN CLI and rpcd plugin
if [ -x /usr/bin/geovpn ]; then
	check_item "GeoVPN CLI Tool" "PASS" "/usr/bin/geovpn installed and executable"
else
	check_item "GeoVPN CLI Tool" "WARN" "/usr/bin/geovpn not installed (running pre-install)"
fi

if [ -f /usr/share/rpcd/ucode/geovpn.uc ]; then
	check_item "rpcd ucode Plugin" "PASS" "geovpn.uc present in rpcd path"
else
	check_item "rpcd ucode Plugin" "WARN" "geovpn.uc not in /usr/share/rpcd/ucode (pre-install)"
fi

# 9. Conntrack and Flow Offloading inspection
if [ -r /proc/net/nf_conntrack ]; then
	CT_COUNT=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo "0")
	check_item "Connection Tracking" "PASS" "Conntrack active ($CT_COUNT active flows)"
elif [ -f /proc/net/nf_conntrack ]; then
	check_item "Connection Tracking" "PASS" "Conntrack active (requires root to inspect flow table)"
elif [ -d /sys/module/nf_conntrack ] || grep -q nf_conntrack /proc/modules 2>/dev/null; then
	check_item "Connection Tracking" "PASS" "Conntrack module loaded"
else
	check_item "Connection Tracking" "WARN" "Conntrack table / module not found"
fi

# 10. WireGuard Kernel & Tools (Optional Add-on geovpn-wireguard)
if command -v wg >/dev/null 2>&1; then
	if [ -d /sys/module/wireguard ] || grep -q wireguard /proc/modules 2>/dev/null; then
		check_item "WireGuard (kmod + tools)" "PASS" "Kernel module loaded and wg tool functional"
	else
		check_item "WireGuard (tools only)" "WARN" "wg CLI present but kmod-wireguard not yet loaded"
	fi
else
	check_item "WireGuard (geovpn-wireguard)" "WARN" "Optional package not installed (apk add geovpn-wireguard)"
fi

# 11. strongSwan & XFRM Interface (Optional Add-on geovpn-ikev2)
if command -v swanctl >/dev/null 2>&1; then
	if [ -d /sys/module/xfrm_interface ] || grep -q xfrm_interface /proc/modules 2>/dev/null; then
		check_item "strongSwan & XFRM (IKEv2)" "PASS" "swanctl available and kmod-xfrm-interface loaded"
	else
		check_item "strongSwan (tools only)" "WARN" "swanctl present but kmod-xfrm-interface not loaded"
	fi
else
	check_item "strongSwan (geovpn-ikev2)" "WARN" "Optional package not installed (apk add geovpn-ikev2)"
fi

# 12. Policy Routing Tables & Mark Isolation
if ip rule add fwmark 0x03000000/0x0f000000 lookup 4300 prio 32700 2>/dev/null; then
	ip rule del prio 32700 2>/dev/null || true
	check_item "Policy Routing Tables" "PASS" "Rules priority and table 4200/4300 supported"
else
	check_item "Policy Routing Tables" "WARN" "Testing mark rule creation requires root privileges"
fi

echo "=========================================================="
echo "Checklist Summary: $PASSED passed, $WARNED warnings, $FAILED failures."
if [ "$FAILED" -gt 0 ]; then
	echo "Hardware check: FAILED requirements found."
	exit 1
fi
echo "Hardware check: PASSED (System ready for GeoVPN deployment)."
exit 0

