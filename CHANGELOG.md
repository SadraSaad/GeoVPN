# Changelog

All notable changes to the GeoVPN project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-08

### Added
- **Multi-Protocol Architecture**: Extensible driver abstraction (`drivers/common.uc`, `drivers/openvpn.uc`, `drivers/wireguard.uc`, `drivers/ikev2.uc`) with unified `geovpn0` device and table 4200 policy routing.
- **Kernel WireGuard Driver**: Direct Linux WireGuard client integration (`geovpn-wireguard`) using kernel `kmod-wireguard` and `wireguard-tools`.
- **Route-Based IKEv2 / IPsec Driver**: strongSwan route-based IPsec client integration (`geovpn-ikev2`) via Linux XFRM virtual interfaces (`if_id 4200`/`4300`) and EAP-MSCHAPv2 authentication.
- **Isolated Test Engine**: Fail-closed pre-connection testing framework (`geovpn-test` init, table 4300, `gvt0` device) measuring handshakes, latencies, and HTTP targets without touching active VPN or LAN traffic.
- **Auto-Connect & Health Failover**: Dynamic profile ranking, connect gate enforcement (`require|warn|off`), automated health monitoring, and flapping-protected failover.
- **Provider & Batch Importers**: Windscribe OpenVPN and WireGuard presets, Android strongSwan `.sswan` JSON parser, smart-paste multi-line importer, shared credential sets, and batch file import.
- **Packaging Hierarchy**:
  - `geovpn-core` (1.1.0): core service, policy routing, driver skeleton, test engine, migration.
  - `geovpn-wireguard` (1.1.0): WireGuard kernel add-on package.
  - `geovpn-ikev2` (1.1.0): optional strongSwan / IKEv2 add-on package.
  - `geovpn` (1.1.0): standard meta-package (core + OpenVPN + LuCI + seed).
  - `geovpn-full` (1.1.0): full meta-package (core + OpenVPN + WireGuard + IKEv2 + LuCI + seed).
  - `luci-app-geovpn` (1.1.0): comprehensive web UI with test panel, auto-connect, importer, and 100% complete Persian translations.
- **Sysupgrade Retention**: Preserves `/etc/config/geovpn`, profiles, credentials, backups, keys, and custom catalogs in `keep.d/geovpn`.
- **Automatic Migration**: Safe `91-geovpn-migrate` with rollback capability from v1.0 to v1.1 profile schemas.

## [1.0.0] - 2026-10-06

### Added
- Core OpenVPN client lifecycle management with procd supervisor (`geovpn-core`).
- Policy-based routing via nftables (`table inet geovpn`) and fwmark table 4200.
- Selective GeoIP CIDR routing for IPv4 and IPv6.
- DNS-driven GeoSite routing using `dnsmasq-full` nftset integration (`server=/domain/...` + `nftset=/domain/...`).
- Custom domain and CIDR rules with priority ordering.
- Per-LAN client routing policies by MAC, IP, and CIDR.
- DNS leak prevention: routing-aligned DNS upstreams, optional DNS hijack (port 53), DoT blocking (port 853), DoH IP blocking, and canary domain NXDOMAIN.
- IPv6 leak protection with `auto`, `block`, `vpn`, and `direct` modes.
- Fail-safe kill switch preventing unencrypted egress when tunnel is down.
- Fail-safe undo journaling rolling back failed operations without locking out LAN or SSH/LuCI access.
- Atomic, verified data-pack updater (`geovpn-update`) with usign signature verification and fallback.
- Headless command-line interface (`geovpn` CLI).
- LuCI web interface (`luci-app-geovpn`): Connections, Split Tunneling, Settings, Logs & Diagnostics.
- English and complete Persian (`fa`) translations with RTL-safe layout.
- Data pack compiler (`data-pack/build_pack.py`) compiling ipverse and domain-list-community sources.
