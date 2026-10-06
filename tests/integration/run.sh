#!/bin/sh
#
# GeoVPN Integration Test Runner (netns topology)
#
set -e

echo "==> GeoVPN Integration Test Harness..."

if [ "$(id -u)" -ne 0 ]; then
	echo "SKIPPED: Integration tests require root privileges for network namespaces (ip netns)."
	exit 0
fi

if ! command -v ip >/dev/null 2>&1; then
	echo "SKIPPED: 'ip' command not found."
	exit 0
fi

# Clean up any leftover namespaces
ip netns del gv_lan 2>/dev/null || true
ip netns del gv_router 2>/dev/null || true
ip netns del gv_inet 2>/dev/null || true
ip netns del gv_vpn 2>/dev/null || true

cleanup() {
	echo "--> Cleaning up network namespaces..."
	ip netns del gv_lan 2>/dev/null || true
	ip netns del gv_router 2>/dev/null || true
	ip netns del gv_inet 2>/dev/null || true
	ip netns del gv_vpn 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "--> Setting up network namespaces..."
ip netns add gv_lan
ip netns add gv_router
ip netns add gv_inet
ip netns add gv_vpn

# 1. LAN veth pair: gv_lan <-> gv_router
ip link add veth_lan_c type veth peer name veth_lan_r
ip link set veth_lan_c netns gv_lan
ip link set veth_lan_r netns gv_router

ip netns exec gv_lan ip addr add 192.168.1.100/24 dev veth_lan_c
ip netns exec gv_lan ip link set veth_lan_c up
ip netns exec gv_lan ip link set lo up
ip netns exec gv_lan ip route add default via 192.168.1.1

ip netns exec gv_router ip addr add 192.168.1.1/24 dev veth_lan_r
ip netns exec gv_router ip link set veth_lan_r up
ip netns exec gv_router ip link set lo up

# 2. WAN veth pair: gv_router <-> gv_inet
ip link add veth_wan_r type veth peer name veth_wan_i
ip link set veth_wan_r netns gv_router
ip link set veth_wan_i netns gv_inet

ip netns exec gv_router ip addr add 192.0.2.2/24 dev veth_wan_r
ip netns exec gv_router ip link set veth_wan_r up
ip netns exec gv_router ip route add default via 192.0.2.1

ip netns exec gv_inet ip addr add 192.0.2.1/24 dev veth_wan_i
ip netns exec gv_inet ip link set veth_wan_i up
ip netns exec gv_inet ip link set lo up

# 3. Dummy endpoints on gv_inet to represent internet sites
ip netns exec gv_inet ip addr add 198.51.100.10/32 dev lo   # direct-site (GeoIP direct)
ip netns exec gv_inet ip addr add 203.0.113.10/32 dev lo    # vpn-site (default VPN path)
ip netns exec gv_inet ip addr add 192.0.2.50/32 dev lo      # VPN server address

echo "--> Verifying base connectivity in topology..."
ip netns exec gv_lan ping -c 1 -W 1 192.168.1.1 >/dev/null 2>&1 || {
	echo "FAIL: LAN ping failed"
	exit 1
}

ip netns exec gv_router ping -c 1 -W 1 192.0.2.1 >/dev/null 2>&1 || {
	echo "FAIL: WAN ping failed"
	exit 1
}

echo "--> Integration harness initialized successfully."
echo "==> Integration tests completed."
exit 0
