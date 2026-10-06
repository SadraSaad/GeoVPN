# Changelog

All notable changes to the GeoVPN project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
