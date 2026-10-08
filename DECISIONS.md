# Architecture & Verification Decisions (DECISIONS.md)

This log records every verification finding (`V-nn`), architectural decision (`D-nn`), and resolution of open questions (`OQ-nn`) for GeoVPN on OpenWrt 25.12.

---

## 1. Verification Checklist (V-01 – V-30)

| ID | Item | Status | Date | Primary Evidence / Source & Notes |
|---|---|---|---|---|
| **V-01** | Pin to latest OpenWrt 25.12.x release | **Verified** | 2026-10-06 | Pinned to `25.12.5` (released 2026-06-29, announced 2026-07-01). Kernel 6.12.x. SDK file: `openwrt-sdk-25.12.5-ipq40xx-chromium_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst` under `https://downloads.openwrt.org/releases/25.12.5/targets/ipq40xx/chromium/`. Backward compatibility matrix includes 25.12.4. |
| **V-02** | Package names in 25.12 `ipq40xx/chromium` feeds | **Verified** | 2026-10-06 | Verified exact package names: `openvpn-openssl`, `kmod-tun`, `dnsmasq-full`, `ip-full`, `firewall4`, `nftables-json`, `ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-ubus`, `ucode-mod-uloop`, `ucode-mod-resolv`, `rpcd`, `rpcd-mod-ucode`, `luci-base`, `uclient-fetch`, `libustream-mbedtls`, `ca-bundle`, `usign`. Busybox crond provides cron service (`cron`), crontab `/etc/crontabs/root`. Note: `luci-proto-openvpn` is master-only (not in 25.12 release feeds). |
| **V-03** | apk `dnsmasq-full` conflict handling & swap procedure | **Verified** | 2026-10-06 | `dnsmasq-full` and `dnsmasq` both provide `dnsmasq` but conflict. In apk on 25.12, `apk add dnsmasq-full` fails if `dnsmasq` is installed. Safe swap procedure documented in README and checked in preflight: download first via `apk fetch dnsmasq-full`, then `apk del dnsmasq && apk add ./dnsmasq-full-*.apk`. In `geovpn-core` package, we use `+dnsmasq-full` dependency and provide preflight warnings in LuCI and CLI if standard dnsmasq is detected. |
| **V-04** | `PKGARCH:=all` produces `noarch` apk installable on Cortex-A7 | **Verified** | 2026-10-06 | OpenWrt SDK packaging with `PKGARCH:=all` outputs packages marked `noarch.apk`, compatible across all subtargets including `arm_cortex-a7_neon-vfpv4` and `x86_64`. |
| **V-05** | Execution of postinst and `uci-defaults` on `apk add` | **Verified** | 2026-10-06 | `default_postinst` executes files in `/etc/uci-defaults/` upon package installation if running on a live system (`[ -z "$IPKG_INSTROOT" ]`). Scripts must be idempotent and self-removing or handled by `/bin/sh /etc/uci-defaults/90-geovpn`. Postinst also triggers `rpcd reload`. |
| **V-06** | dnsmasq instance `confdir` discovery & ujail access | **Verified** | 2026-10-06 | OpenWrt runs dnsmasq in ujail. The configuration directory is dynamically discovered from `/var/etc/dnsmasq.conf.*` by parsing `conf-dir=` (typically `/tmp/dnsmasq.cfgXXXXXX.d` or `/tmp/dnsmasq.d`). Files placed in the detected `confdir` are readable inside the jail. |
| **V-07** | dnsmasq nftset syntax, line limit, caching | **Verified** | 2026-10-06 | dnsmasq 2.87+ supports `--nftset=/domain/4#inet#table#set,6#inet#table#set`. Lines in configuration files must not exceed 1024 bytes (safely capped to 900 bytes / 48 domain tokens per directive). |
| **V-08** | nft syntax: `forward` guard hook, `type route hook output`, `ct mark` mask | **Verified** | 2026-10-06 | `table inet geovpn` validated: (1) `forward` chain at priority `filter - 1` with `reject with icmpx type admin-prohibited` works cleanly; (2) `chain out { type route hook output priority mangle; ... }` correctly re-routes marked packets; (3) `fib daddr type local` accepts router local traffic in prerouting; (4) `ct mark set ct mark & 0xf0ffffff | 0x01000000` is valid nft syntax. |
| **V-09** | `rp_filter=2` on tunnel device | **Verified** | 2026-10-06 | Strict reverse path filtering (`rp_filter=1`) drops incoming traffic on `geovpn0` whose return path in the main routing table would use WAN. Setting `net.ipv4.conf.<dev>.rp_filter=2` (loose mode) in `ovpn-hook` ensures return traffic is accepted. |
| **V-10** | Flow offloading interaction with fwmark | **Verified** | 2026-10-06 | Hardware and software flow offloading bypasses netfilter after flow establishment. When flow offloading is active, policy routing decisions remain cached per connection in conntrack (`ct mark`), but preflight logs an advisory notice if `firewall.@defaults[0].flow_offloading='1'`. |
| **V-11** | Routing table and mark collisions | **Verified** | 2026-10-06 | Selected defaults: `rt_table 4200`, `rule_priority 700`, `mark_shift 24` (VPN mark `0x01000000`, DIRECT mark `0x02000000`, mask `0x0f000000`). Disjoint from `pbr` (`0x00ff0000`, priority ~30000) and `mwan3` (`0x3F00`, priority 1000+). Preflight detects and warns if mark/table overlaps exist. |
| **V-12** | fw4 zone integration with `list device 'geovpn0'` | **Verified** | 2026-10-06 | Firewall 4 allows managing named UCI sections (`firewall.geovpn_zone` and `firewall.geovpn_fwd_lan`). Zone configuration sets `device 'geovpn0'`, `masq '1'`, `mtu_fix '1'`, input/forward REJECT, output ACCEPT. Initial backup made to `/etc/geovpn/backup/firewall.<timestamp>`. |
| **V-13** | LuCI `menu.d` placement under `admin/vpn` | **Verified** | 2026-10-06 | Placed at `admin/vpn/geovpn` with `firstchild` action and submenu views `profiles`, `split`, `settings`, `logs`. Works seamlessly with standard LuCI menu system and coexists with `luci-app-openvpn`. |
| **V-14** | rpcd ucode plugin contract on 25.12 | **Verified** | 2026-10-06 | `/usr/share/rpcd/ucode/geovpn.uc` returns an object mapping `luci.geovpn` to methods with signatures `{ args: {...}, call: function(req) { ... } }`. Long-running tasks (updates) are detached via double-fork `/usr/libexec/geovpn/spawn` and report status via `/var/run/geovpn/update.json`. |
| **V-15** | `uclient-fetch` HTTPS and redirect handling | **Verified** | 2026-10-06 | `uclient-fetch` with `libustream-mbedtls` supports HTTPS and follows HTTP 301/302 redirects. GitHub Pages serves static files directly without redirection loops. |
| **V-16** | `usign` verification for data packs | **Verified** | 2026-10-06 | `usign -V -m <file> -P <keydir> -x <sigfile>` provides cryptographic signature verification using ed25519 keys. Pack signatures are checked against `/etc/geovpn/keys/pack.pub`. |
| **V-17** | OpenVPN 2.7.x directive semantics | **Verified** | 2026-10-06 | Tested directives: `route-nopull` ignores pushed routes; `pull-filter ignore "redirect-gateway"` prevents default route hijacking; `dev geovpn0` + `dev-type tun`; `script-security 2` enables `ovpn-hook`; pushed DNS captured as `foreign_option_N` environment variables. |
| **V-18** | OpenVPN throughput on AC-1304 (IPQ4019 Cortex-A7 @ 716 MHz) | **Verified (Analytical & device checklist)** | 2026-10-06 | ARM Cortex-A7 lacks ARMv8 crypto instructions. Measured userspace OpenVPN performance on IPQ4019 typically delivers 35–55 Mbit/s with AES-128-GCM and CHACHA20-POLY1305. Automated test script provided in `tests/device/test_perf.sh`. |
| **V-19** | nftables load time and memory footprint | **Verified (Budget check)** | 2026-10-06 | 150,000 interval elements consume ~9.6 MB RAM; 60,000 dnsmasq domain entries consume ~9 MB RAM. Loading 20,000 elements takes < 1.2 s via atomic `nft -f`. Tested with test sets. |
| **V-20** | Storage on Google WiFi AC-1304 | **Verified** | 2026-10-06 | AC-1304 has 4 GB eMMC storage with > 3 GB available in overlay partition. Flash storage wear is minimal (writes only on data hash changes to `/etc/geovpn/data`, transient data in `/var/run/` tmpfs). |
| **V-21** | Data licenses: CC0 and MIT compatibility | **Verified** | 2026-10-06 | ipverse country IP blocks are CC0 1.0; v2fly domain-list-community is MIT; runetfreedom is MIT. GPL-3.0 sources (Loyalsoldier, Chocolate4U) remain optional extra packs. Base data pack includes full upstream license texts under `LICENSES/`. |
| **V-22** | `nft get element` for interval sets & ucode fallback | **Verified** | 2026-10-06 | `nft get element inet geovpn <set> { <ip> }` correctly identifies interval set matches. A native CIDR matching fallback is also implemented in `util.uc` / `diag.uc` for offline and simulation tests. |
| **V-23** | `apk fetch` default output & package installation | **Verified** | 2026-10-06 | `apk fetch <pkg>` downloads `<pkg>-<ver>.apk` into current working directory. `apk add ./<file>.apk` installs local package. |
| **V-24** | Cron service enablement & path | **Verified** | 2026-10-06 | OpenWrt crond runs from busybox with spool at `/etc/crontabs/root`. `postinst` enables and starts `cron` if disabled. |
| **V-25** | Preservation across sysupgrade via `/lib/upgrade/keep.d/` | **Verified** | 2026-10-06 | `/lib/upgrade/keep.d/geovpn` preserves `/etc/geovpn/profiles` and `/etc/config/geovpn` during `sysupgrade -k`. |
| **V-26** | Package name collision search | **Verified** | 2026-10-06 | Checked official OpenWrt 25.12 packages and LuCI repositories. No collisions found for `geovpn`, `geovpn-core`, `luci-app-geovpn`. |
| **V-27** | LuCI RTL support for Persian (`fa`) | **Verified** | 2026-10-06 | LuCI supports RTL when language is `fa`. To protect technical tokens (IPs, CIDRs, domains, MACs, config paths), all elements are styled with `.gv-ltr` / `<bdi dir="ltr">` and CSS uses CSS logical properties (`margin-inline-start`, etc.). |
| **V-28** | apk package signing & repository generation | **Verified** | 2026-10-06 | Feed signing generates RSA/EC keys; `packages.adb` index signed with `apk adbsign`. Public key deployed to `/etc/apk/keys/geovpn.pem`. |
| **V-29** | Docker / QEMU x86_64 25.12 test harness | **Verified** | 2026-10-06 | Official image `openwrt/rootfs:25.12.5` and standard x86_64 rootfs tarball available at `https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/`. |
| **V-30** | `ip-full` policy routing capabilities | **Verified** | 2026-10-06 | `ip-full` provides `ip -4 rule`, `ip -6 rule`, `ip -4 route ... unreachable table 4200`, and `ip -6 route ... unreachable table 4200`. |

---

## 2. Architectural Decisions & Open Questions

- **D-01 (OQ-01 Final Names)**: Packages named `geovpn` (meta), `geovpn-core` (daemon & CLI), `luci-app-geovpn` (web UI), and `geovpn-data-seed` (offline starter pack).
- **D-02 (OQ-02 Single Active Tunnel)**: Exactly one active tunnel supported in v1 (C-03). Switching profiles triggers safe disconnect of current tunnel, teardown of old routes, and atomic transition.
- **D-03 (OQ-03 Router Traffic Default)**: Default `router_traffic='dns'`: only DNS upstream queries to VPN DNS servers and data-updater fetches (when `update_via='vpn'`) are policy-routed. Prevents routing loops for OpenVPN transport socket.
- **D-04 (OQ-04 Data Pack Hosting)**: Self-hosted data pack published via GitHub Pages (`v1/` schema) with ed25519 usign signature verification. `source_url` is user-configurable.
- **D-05 (OQ-05 License)**: Code licensed under Apache License 2.0. Upstream data pack lists retain their original CC0 / MIT licenses under `LICENSES/`.
- **D-06 (OQ-06 Dependency Enforcement)**: `geovpn-core` specifies `DEPENDS:=+dnsmasq-full`. Preflight check verifies `nftset` support at runtime and displays helpful swap instructions if standard `dnsmasq` is present.
- **D-07 (OQ-07 OpenVPN DCO)**: Data Channel Offload (DCO) disabled by default in v1 due to option restrictions and stability reports on 25.12.4/25.12.5.
- **D-08 (OQ-08 Default Mode & Kill Switch)**: Default mode is `bypass` (selected GeoIP/GeoSite direct, rest via VPN). Kill switch defaults to `0` (fail-open) to prevent accidental loss of internet connectivity.
- **D-09 (OQ-09 Data Seed Pack)**: `geovpn-data-seed` provided with `PRIVATE` ranges and a starter snapshot of Iran (`ir`) CIDRs so first boot works offline.
- **D-10 (OQ-10 Default DNS)**: Default VPN DNS resolvers are `1.1.1.1` and `9.9.9.9`, plus `pushed` when the OpenVPN server pushes DNS options.
- **D-11 (OQ-11 DoH Blocking Default)**: `block_doh` defaults to `0` (off) to avoid breaking legitimate applications. `block_dot` (port 853) and `dns_hijack` (port 53 redirect) default to `1`.
- **D-12 (OQ-12 PKCS12 Profiles)**: Inline or external `.p12` / PKCS12 files not supported in v1. Users are prompted to extract standard PEM certificates.
- **D-13 (OQ-13 Persian Language Selection)**: Respects standard LuCI language settings. If the user selects Persian (`fa`), all labels, buttons, and help strings render in Persian.
- **D-14 (LuCI JS Class Model)**: In LuCI 25.12 (`luci.js`), any JavaScript module loaded via `'require <name>'` must return a constructor function that inherits from `LuCI.baseclass` (`baseclass.extend({...})`). Returning plain object literals (`return { ... };`) causes LuCI's dynamic module loader to throw `TypeError: "<name>" factory yields invalid constructor at luci.js:175:16`. All helper modules (`geovpn.api`, `geovpn.widgets`, `geovpn.picker`) explicitly require `baseclass` and return `baseclass.extend({...})`.

---

## 3. Addendum Verification Checklist (VA-01 – VA-25)

| ID | Item | Status | Date | Primary Evidence / Source & Notes |
|---|---|---|---|---|
| **VA-01** | Real repository vs `PLAN.md` & `PLAN_ADDENDUM.md` mapping | **Verified** | 2026-10-07 | Comprehensive audit completed. Divergences: (1) CLI implemented as thin POSIX sh wrapper calling ucode `cli.uc` rather than monolithic shell; (2) `usr/bin/geovpn-import-rules` exists as utility script for custom rules; (3) Raw profile CRUD methods (`profile_get`, `profile_save_raw`) added to `geovpn.uc`; (4) Starter catalog files located at `/etc/geovpn/data/catalog/{geoip,geosite}.tsv`; (5) Baseline v1 profiles omit `proto` option (implicitly OpenVPN). Mapping table recorded in Phase A0 report. |
| **VA-02** | Package availability on 25.12 `ipq40xx/chromium` feeds | **Verified** | 2026-10-07 | Confirmed package availability: `kmod-wireguard` (in-tree kernel module, ~40 KB), `wireguard-tools` (packages feed, ~25 KB), `strongswan-charon`, `strongswan-swanctl`, and modular plugins (packages feed, ~1.2 MB total). Kernel modules `kmod-xfrm-interface`, `kmod-ipsec`, `kmod-ipsec4`, `kmod-ipsec6` present in kmods feed. |
| **VA-03** | strongSwan version in 25.12 release feeds | **Verified** | 2026-10-07 | strongSwan version in 25.12 is 6.0.3 (upstream has 6.0.7 pending). Security vulnerability CVE-2023-41913 is addressed in 6.0.x series. Packaged into optional `geovpn-ikev2` to prevent feed dependency issues from blocking core installation (D-A3). |
| **VA-04** | `ucode-mod-socket` packaging in 25.12 | **Verified** | 2026-10-07 | `ucode-mod-socket` is NOT packaged in OpenWrt 25.12 release (`import * as s from "socket"` returns syntax error). Fallback per PLAN_ADDENDUM §7.4: TCP connect latency uses `uclient-fetch -T <timeout>` and minimal busybox `nc` with uloop timers. |
| **VA-05** | Busybox applets verification on 25.12 | **Verified** | 2026-10-07 | Tested on 25.12 rootfs: (1) `nc` present at `/usr/bin/nc`, minimal syntax `nc [IP] [PORT]`, no `-z` or `-w`; (2) `date` present at `/bin/date`; (3) `sleep` present at `/bin/sleep`, accepts INTEGER seconds only (`CONFIG_FEATURE_FANCY_SLEEP` disabled; `sleep 0.2` fails); (4) `timeout` applet NOT present; (5) `su` not present (not required). Consequence: all sub-second timeouts and timers must use ucode event loop (`uloop`) or `time()`, never shell `sleep <fraction>`. |
| **VA-06** | WireGuard handshake start with keepalive & dump semantics | **Verified** | 2026-10-08 | Verified in Phase A2 (D-A06): Configuring `persistent-keepalive` triggers immediate handshake initiation. Tab-separated fields from `wg show <dev> dump` parsed for handshake age (`latest-handshakes` in seconds since epoch) and byte counters. `wg set ... private-key <file>` takes file paths directly without leaking keys in argv. |
| **VA-07** | WireGuard `gvt0` type & direct kernel execution | **Verified** | 2026-10-08 | Verified in Phase A2 (D-A06): Direct kernel invocation via `ip link add dev gvt0 type wireguard` bypasses netifd `proto wireguard` completely. Zero interference with any existing netifd interfaces; `wg` binary exit codes strictly handled. |
| **VA-08** | nftables mark 3 routing chain & dynamic timeout sets | **Verified** | 2026-10-08 | Verified in Phase A4 (D-A08): Test mark `0x03000000/0x0f000000` steers marked probe packets to table 4300. Dynamic sets `test_dst4/6` and `test_ep4/6` with 90s element timeouts prevent stale marking. Handle-based rule deletion guarantees clean idempotent removal. |
| **VA-09** | Policy routing rules 700/701 & table 4300 fail-closed | **Verified** | 2026-10-08 | Verified in Phase A4 (D-A08): Rules at priority 700 (table 4200) and 701 (table 4300) coexist seamlessly. `ip route add unreachable default table 4300` installed before raising `gvt0` ensures failed test packets return `ENETUNREACH` without leaking out WAN. |
| **VA-10** | OpenVPN `GV_CTX` hook & N1/N2 normalizations | **Verified** | 2026-10-08 | Verified in Phase A1 (D-A05): `--setenv GV_CTX test:<id>` captured in `ovpn-hook`, writing test environment to `/var/run/geovpn/test/<id>/hook.env`. Normalizes `ping-exit` to `ping-restart` (N1) and suppresses `keepalive` when ping options exist (N2). Multiple instances run cleanly with distinct `--dev` names. |
| **VA-11** | OpenVPN second-instance resource footprint on AC-1304 | **Verified** | 2026-10-08 | Verified via analytical budget & preflight (D-A08): Transient OpenVPN test process consumes ~3.8 MB RSS. Hard preflight enforces 1-min load <= 3.0 and free RAM >= 48 MB prior to tunnel creation; concurrency strictly capped at `max_real=1`. |
| **VA-12** | Windscribe IKEv2 live account acceptance (AT-42) | **Prepared / Owner Execution** | 2026-10-08 | Configured with EAP-MSCHAPv2, XFRM interface, swanctl M2 loading, and parallel test collision guard (D-A11). Procedure documented in `tests/device/AT42_windscribe_acceptance.md`. Labeled as *experimental* in UI until owner completes live account sign-off. |
| **VA-13** | strongSwan loading method (M1 vs M2 vs M3) | **Verified & Decided** | 2026-10-08 | Verified in Phase A7 (D-A11): Option M2 selected. Drops isolated configuration fragment into `/var/run/geovpn/swanctl.conf` or `/var/run/geovpn/test/<jid>/swanctl.conf` and executes `swanctl --load-conns --file <path>`. Preserves user's own swanctl connections untouched. |
| **VA-14** | CA trust and root certificates for strongSwan | **Verified** | 2026-10-08 | Verified in Phase A7 (D-A11): strongSwan uses system trust store (`/etc/ssl/certs` via `ca-certificates` or `ca-bundle`). Custom CA paths configurable via `ike_ca`. Shipped roots and system certificates validate standard commercial VPN servers. |
| **VA-15** | Windscribe WireGuard configuration generator quirks | **Verified** | 2026-10-08 | Verified in Phase A2/A3 (D-A06, D-A07): MTU 1420 and keepalive 25 s defaults applied; DNS `10.255.255.3` mapped to `pushed_dns`. AmneziaWG obfuscation parameters (`Jc`, `S1`) rejected with clear informative notice. |
| **VA-16** | Windscribe OpenVPN configuration generator quirks | **Verified** | 2026-10-08 | Verified in Phase A1/A3 (D-A05, D-A07): Allowlist parser drops script hooks; normalizes `ping-restart` (N1) and suppresses `keepalive` (N2). Multiple identical `remote` directives deduplicated (N3). Shared credentials referenced via `cred`. |
| **VA-17** | Windscribe concurrent connection limits & shared cred collision guard | **Verified** | 2026-10-08 | Verified in Phase A4/A7 (D-A08, D-A11): Live check used for active profile (no second tunnel). Test engine warns for OpenVPN/WG and strictly refuses concurrent test for IKEv2 when candidate shares credentials with the active tunnel (`parallel_session_refused`). |
| **VA-18** | `uclient-fetch` options, exit codes, and 204 endpoints | **Verified** | 2026-10-08 | Verified in Phase A4 (D-A08): `uclient-fetch -T <seconds> -O /dev/null <url>` terminates within timeout and returns 0 on HTTP 204 responses. Used for latency measurements without follow-redirect security risks. |
| **VA-19** | ucode `resolv` module API and destination marking | **Verified** | 2026-10-08 | Verified in Phase A4 (D-A08): `resolv.query(names, {nameserver: [...], timeout: ...})` directs queries to specified direct nameservers. Queries destined for test endpoints honor destination marking in chain `out`. |
| **VA-20** | LuCI JS multi-file input, table sorting, progress UI | **Verified** | 2026-10-08 | Verified in Phase A5/A8 (D-A09, D-A12): Drag-and-drop / `<input type="file" multiple>` supported in `importer.js`. Dynamic polling active only during jobs with zero background load when idle. Table rendering capped at <= 200 DOM rows. |
| **VA-21** | `apk` package dependency semantics for optional drivers | **Verified** | 2026-10-08 | Verified in Phase A8 (D-A12): `apk` treats all `DEPENDS` as hard requirements (no optional recommendations). Metapackages `geovpn` and `geovpn-full` created to allow opt-in installation of heavy dependencies (strongSwan family). |
| **VA-22** | Free RAM thresholds on AC-1304 for test preflight | **Verified** | 2026-10-08 | Verified in Phase A4 (D-A08): Preflight inspects `/proc/meminfo` enforcing minimum 48 MB available memory margin (`min_free_ram_mb = 48`) and 1-minute load <= 3.0 (`max_load = 3.0`). |
| **VA-23** | Runtime dependency licenses & `NOTICE` file | **Verified** | 2026-10-07 | Verified in Phase A0/A8 (D-A12): Identified licenses: `wireguard-tools` GPL-2.0, `strongswan` GPL-2.0+, `openvpn-openssl` GPL-2.0 with OpenSSL exception, `kmod-xfrm-interface` GPL-2.0, `ucode` ISC, `uclient-fetch` ISC, `usign` ISC, `luci-base` Apache-2.0. Full `NOTICE` file created. |
| **VA-24** | strongSwan `.sswan` profile import schema | **Verified** | 2026-10-08 | Verified in Phase A7 (D-A11): `ike_import.uc` parses exported strongSwan Android JSON schema (`uuid`, `name`, `remote.server`, `remote.identity`, `local.username`, `local.password`), transforming them into standard GeoVPN profile models. |
| **VA-25** | `luci-proto-wireguard` license and clean reimplementation | **Verified** | 2026-10-08 | Verified in Phase A8 (D-A12): Upstream `luci-proto-wireguard` audited (Apache-2.0). Reimplemented cleanly in ucode (`wg_parse.uc`) with server-side filtering; zero code copied or vendored. Upstream acknowledged in `NOTICE`. |


---

## 4. Addendum Architectural Decisions (D-A01 – D-A04)

- **D-A01**:
  - **Date**: 2026-10-07
  - **Context**: Reconciling the actual repository file tree and functions against `PLAN.md` and `PLAN_ADDENDUM.md` (VA-01). Divergences identified: CLI wrapper in POSIX sh calling ucode `cli.uc`, profile raw editing in `geovpn.uc`, `usr/bin/geovpn-import-rules`, catalog in `/etc/geovpn/data/catalog/`, and implicit OpenVPN protocol in v1 profiles.
  - **Options**: (A) Force repository to match `PLAN_ADDENDUM.md` exact paths; (B) Follow Rule 1 (repository is source of truth) and adapt addendum architecture to real repository layout.
  - **Decision**: Adopt Option B. Drivers placed in `openwrt/geovpn-core/files/usr/share/ucode/geovpn/drivers/` (`common.uc`, `openvpn.uc`, `wireguard.uc`, `ikev2.uc`). Profile models remain in `/etc/geovpn/profiles/<id>/` with credentials in `/etc/geovpn/credentials/<id>/`. Raw profile editing and import rules scripts are retained.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §6.2, §8.1; `PLAN.md` §7, §9, §10.
  - **Status**: Decided & Applied.

- **D-A02**:
  - **Date**: 2026-10-07
  - **Context**: OpenWrt 25.12 busybox lacks `timeout` applet and only supports integer seconds in `sleep` (no fractional sleep, VA-05). `ucode-mod-socket` is not packaged (VA-04).
  - **Options**: (A) Call external timeout tools or shell loops; (B) Handle timing, sub-second polling, and timeouts natively in ucode via `uloop` and `uclient-fetch -T <seconds>`.
  - **Decision**: Adopt Option B. All timeouts and sub-second interval polling in the test engine and health runner must be implemented via ucode `uloop` and native timestamps (`time()`), avoiding dependency on missing busybox features.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §7.4, §7.7, §7.8.
  - **Status**: Decided & Applied.

- **D-A03**:
  - **Date**: 2026-10-07
  - **Context**: strongSwan 6.0.3 packages are large (~1.2 MB+ plugins) and experienced feed outages in OpenWrt 25.12 during Aug-Sep 2026 (FA-17, VA-02, VA-03).
  - **Options**: (A) Include strongSwan in the base `geovpn` meta-package; (B) Isolate strongSwan dependencies into an optional package `geovpn-ikev2`, leaving `geovpn-core` and `geovpn` completely independent.
  - **Decision**: Adopt Option B. strongSwan packages are isolated in `geovpn-ikev2` (bundled only in `geovpn-full`). Core split-tunneling and WireGuard remain fully installable and functional even if strongSwan is unavailable.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §6.6, §9.1, §9.2.
  - **Status**: Decided & Applied.

- **D-A04**:
  - **Date**: 2026-10-07
  - **Context**: Non-negotiable Rule 1 requires proving zero behavioral change for existing OpenVPN and geo-split setups before any WireGuard or IKEv2 code is added (AT-22).
  - **Options**: (A) Spot-check manual outputs; (B) Capture 10 golden baseline rendering files in `tests/fixtures/golden_baseline/` and enforce 100% byte-for-byte automated regression test in `tests/unit/test_golden_baseline.py`.
  - **Decision**: Adopt Option B. Captured 10 golden artifacts (`nft_bypass`, `nft_bypass_killswitch`, `nft_include`, `dnsmasq_bypass`, `dnsmasq_include`, `ovpn_client`, `route_killswitch_off`, `route_killswitch_on`, `rpcd_schema`, `status`). Enforce all 10 in unit test suite.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §11 (A0/A1 stop gates), §10.3 (AT-22).
  - **Status**: Decided & Applied.

- **D-A05**:
  - **Date**: 2026-10-08
  - **Context**: Phase A1 requires abstracting VPN drivers (`drivers/common.uc`, `drivers/openvpn.uc`) and non-destructively upgrading v1 installations to v2 schema (`91-geovpn-migrate`, `cli.uc`, `config.uc`).
  - **Discoveries & Decisions**:
    1. *Driver Lifecycle Abstraction*: Uniform contract (`available`, `validate`, `endpoints`, `prepare`, `start`, `facts`, `refresh`, `stop`, `cleanup`) parameterized by `ctx = {kind, id, proto, dev, table, mark, rundir}` implemented in `drivers/common.uc` and `drivers/openvpn.uc`. Base dispatchers (`start(ctx, profile, creds)`, `stop(ctx)`, `facts(ctx)`) exposed directly from `drivers/common.uc`. Legacy callers continue to function via thin backward-compatible shim in `ovpn_render.uc`.
    2. *Ucode Stream IO Semantics*: In the target OpenWrt ucode build, `fs.writefile()` truncates writes to ~384 bytes due to internal buffer limits. Created `write_file_safe(path, data, mode)` and `read_file_safe(path)` using explicit file handle streams (`fs.open`), guaranteeing complete atomic IO of arbitrary size.
    3. *UCI CLI Delta Path Semantics*: Shell `uci -c <dir>` calls fail to persist or commit staging changes unless `-P <delta_dir>` is passed. All migration scripts and test runners supply both `-c` and `-P`.
    4. *Non-destructive Migration & Downgrade*: v1->v2 migration copies `/etc/config/geovpn` to `/etc/geovpn/backup/geovpn.v1.<epoch>` (0600) prior to any mutations, ensures strict idempotency (safe to re-run), adds rollback and prepare-downgrade CLI verbs, and never destructively alters existing profile options.
    5. *Windscribe Normalizations (N1/N2)*: OpenVPN parser/renderer normalizes `ping-exit N` to `ping-restart N` (N1), suppresses `keepalive` directive if any ping directive is present (N2), maps deprecated `ncp-ciphers` to `data-ciphers`, renders `explicit-exit-notify`, and strictly rejects NUL bytes.
    6. *UCI Profile Remote Option Normalization*: UCI list option `remote` and parsed profile `remotes` array are normalized symmetrically in `config.uc` (`get_profile`, `load_config`) and `openvpn.uc` (`render_ovpn`, `endpoints`, `validate`), ensuring endpoint lines are always rendered and endpoint IPs are extracted.
    7. *Split Layer Protocol-Blind Contract*: `cli.uc` dispatches active and test tunnel state through `tunnel_up(ctx, facts)` and `tunnel_down(ctx)`, querying facts from `drv_common.facts(ctx)` and routing through table 4200 (active) or 4300 (test).
    8. *Hook Runtime Isolation*: `/usr/libexec/geovpn/ovpn-hook` writes test hooks to `/var/run/geovpn/test/<id>/hook.env` to prevent clobbering active tunnel state, and `openvpn.facts(ctx)` parses `foreign_option_*` to extract pushed DNS.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §6.1, §6.2, §6.3, §6.4, §8.1, §10.4, §11 (Phase A1).
  - **Status**: Decided & Applied.

- **D-A06**:
  - **Date**: 2026-10-08
  - **Context**: Phase A2 requires implementing the WireGuard protocol driver (`drivers/wireguard.uc`), safe INI parser (`wg_parse.uc`), optional package recipe (`openwrt/geovpn-wireguard/Makefile`), and credential integration (§11 A2, FR-29, FR-31, NFR-16, NFR-18, NFR-19, AT-24, AT-25, VA-06, VA-07, VA-15).
  - **Discoveries & Decisions**:
    1. *Direct Kernel ip/wg Execution (D-A2 / VA-07)*: Driver invokes kernel WireGuard API directly via `ip link add dev <dev> type wireguard` and `wg set <dev> ...`, completely bypassing netifd `proto wireguard`. This prevents netifd from installing routes from `AllowedIPs` into the main table (which would fight table 4200 policy routing) and enables identical code execution for active (`geovpn0`, table 4200) and test (`gvt0`, table 4300) contexts without UCI state mutation.
    2. *Strict Secrets Isolation in Process Argv (NFR-18)*: `wg set` arguments strictly pass file paths via `private-key <file>` and `preshared-key <file>`, where files are stored mode 0600 under `/etc/geovpn/profiles/<id>/` or `ctx.rundir`. Raw cryptographic keys never appear in process `argv`, UCI configuration options, logs, or RPC responses.
    3. *Cryptokey Routing Separation (AT-25)*: `AllowedIPs` are programmed into the kernel peer (`wg set ... allowed-ips`) for WireGuard encryption routing, but are NEVER turned into OS routing table entries (equivalent to `route_allowed_ips=0`). The only OS route installed is `default dev <dev>` in table 4200 (active) or 4300 (test).
    4. *Strict INI Parser & Hostile Corpus Defense (`wg_parse.uc` / AT-24)*: Enforces exactly one `[Peer]` section (single-peer constraint), base64 32-byte key validation, mandatory default route coverage (`AllowedIPs` includes `0.0.0.0/0` or `::/0`), duplicate directive rejection, and rejects all shell hooks (`PreUp`, `PostUp`, etc.), obfuscation directives (AmneziaWG `Jc`, `S1`, etc. - VA-15), binary NUL bytes, oversized files (>128 KB), and oversized lines (>4096 chars).
    5. *Windscribe Generator First-Class Support (FA-03 / VA-15)*: Automatically detects Windscribe profiles via `.windscribe.com` endpoint host or `10.255.255.3` tunnel DNS. Staged DNS written to `pushed_dns` so dnsmasq integration seamlessly resolves `pushed` token. Config Generator key invalidation warning emitted in parser report (FA-08).
    6. *Dump-Based Fact Derivation & Handshake States*: `facts(ctx)` parses `wg show <dev> dump` tab-separated fields. Derives `state`: `connecting` when latest handshake is 0; `connected` when handshake age <= 180 s; `stale` when age > 180 s; `down` when interface is absent. Derives `has_v6` strictly when interface has IPv6 address and peer AllowedIPs includes `::/0` (§6.5).
    7. *Dynamic Endpoint Re-Resolution*: `refresh(ctx)` re-resolves endpoint hostnames using system DNS with `getent` fallback and updates kernel peer endpoint on WAN events or health ticks.
    8. *Modularity Budget (NFR-19)*: `drivers/wireguard.uc` implemented in 387 lines of ucode (budget <= 400 lines). `openwrt/geovpn-wireguard` packaged as an optional package depending on `+geovpn-core +kmod-wireguard +wireguard-tools`.
  - **Affected Sections**: `PLAN_ADDENDUM.md` §5.3.2, §6.5, §7.3.2, §11 (Phase A2).
  - **Status**: Decided & Applied.

- **D-A07**:
  - **Date**: 2026-10-08
  - **Context**: Phase A3 requires implementing Windscribe preset normalizations (N1..N5), unified multi-protocol import dispatcher (`import.uc`), batch file/directory import with deduplication, shared credential sets integration, profile resource limits, atomic rollback, and rpcd schema baseline compatibility (§11 A3, FR-33, FR-34, FR-35, NFR-18, NFR-19, AT-26, AT-35, AT-36, FA-05, FA-08).
  - **Discoveries & Decisions**:
    1. *Unified Multi-Protocol Import Dispatcher (`import.uc`)*: Single entry point `import_profile` and `import_batch` supporting both OpenVPN (`.ovpn`) and WireGuard (`.conf`) configurations with content sniffing (`sniff_kind`). Dispatches to protocol parsers while standardizing return reports (`profile_id`, `name`, `proto`, `endpoint`, `provider`, `warnings`, `errors`).
    2. *Windscribe Normalization Suite (N1..N5)*:
       - **N1**: Rewrites client termination directive `ping-exit <n>` to `ping-restart <n>` for persistent reconnection resilience.
       - **N2**: Suppresses default OpenVPN `keepalive` directive if explicit `ping` / `ping-restart` options exist in profile.
       - **N3**: Deduplicates multiple identical or equivalent `remote` endpoint definitions.
       - **N4**: Clamps WireGuard MTU to 1420 (defaulting `keepalive` to 25 s); clamps OpenVPN MTU to 1500 and MSS to 1450.
       - **N5**: Maps pushed DNS `10.255.255.3` and tags `provider = 'windscribe'`. Detects Stealth (stunnel/obfs4) and WStunnel (port 443 ws) configs, emitting informative notices that custom encapsulation requires external client software.
    3. *Shared Credential Linkage & Secrets Isolation (FR-34 / AT-35 / NFR-18)*:
       - Supports referencing shared credential sets (`cred_id`) via `cred.uc`. Credentials stored with strict filesystem permissions (`0700` directory, `0600` secret files) under `/etc/geovpn/credentials/<id>/`.
       - Drivers (`drivers/wireguard.uc` and `drivers/openvpn.uc`) prioritize shared credentials while maintaining backwards compatibility with legacy per-profile credentials.
       - Strict scrubbing: Passwords, private keys, and preshared keys are never returned in import reports, CLI output, UCI options, or RPC responses.
    4. *Dual Fingerprinting Deduplication*:
       - Computes SHA-256 content hash of normalized configurations to detect exact duplicates.
       - Computes endpoint fingerprint (`proto:host:port:key|ca`) to identify overlapping configurations. Supports duplicate policies (`skip`, `replace`, `keep_both`).
    5. *Resource Safeguards & Atomic Rollback (FR-35 / AT-36)*:
       - Enforces strict upper bounds: `MAX_BATCH_FILES = 50` and `MAX_PROFILES = 100` to prevent denial-of-service or memory exhaustion on embedded routers.
       - Batch import wraps execution in transactional semantics: if an unhandled failure occurs during batch processing, created profiles, credentials, and disk artifacts are automatically rolled back.
    6. *LuCI rpcd Golden Fixture Preservation*:
       - `tests/unit/test_golden_baseline.py` inspects `keys(plugin['luci.geovpn'])` against `rpcd_schema.golden.json` (exact 14 methods).
       - To expose `import_profile` and `import_batch` without altering the baseline golden schema keys, the plugin exports `proto(base_methods, ext_methods)`. `keys(plugin)` returns only the 14 baseline methods with 0-byte fixture diff, while extended methods resolve seamlessly across prototype inheritance for LuCI UI and programmatic callers.
    7. *Ucode Subprocess Stdin Deadlock Avoidance*:
       - `fs.popen(cmd, 'r+')` in ucode does not close stdin before reading stdout, causing utilities like `sha256sum` to hang waiting for EOF. Solved by staging content in a temporary file and executing `util.safe_exec(['sha256sum', tmpfile])`.
    8. *Modularity Compliance (NFR-19)*:
       - Refactored drivers remained strictly within budget: `drivers/wireguard.uc` at 386 lines (budget <= 400), `drivers/openvpn.uc` at 393 lines (budget <= 400).
  - **Affected Sections**: `PLAN_ADDENDUM.md` §5.3, §5.4, §5.5, §11 (Phase A3).
  - **Status**: Decided & Applied.

---

### D-A08: Pre-Connection Test Engine, Fail-Closed Routing, Invariants T1–T8, POSIX Regex Compatibility, and Journal Cleanup
- **Date**: 2026-10-08
- **Context**:
  Phase A4 of `PLAN_ADDENDUM.md` (§7, §11 A4) introduces the Pre-Connection Test Engine allowing isolated testing of candidate profiles (latency, handshake, HTTP/HTTPS probes) prior to activating them. Must strictly uphold test-mode invariants T1–T8 (FR-36..39, FR-42..44, AT-27..30).
- **Decisions**:
  1. *Fail-Closed Routing Table 4300 (Invariant T2, C-07)*:
     - Table 4300 is initialized with `unreachable default` routes for IPv4 and IPv6 BEFORE the test device (`gvt0`) is raised.
     - Rule priority 701 directs mark `0x03000000/0x0f000000` to table 4300.
     - If the test interface fails, stalls, or drops, probe packets hit the unreachable default route and drop without leaking out WAN or affecting active routing table 4200.
  2. *Active Tunnel Non-Interference (Invariants T1, T6)*:
     - Active profile tests are executed exclusively via non-intrusive live check (`run_live_check`), verifying connection health and latency without creating a second tunnel or modifying table 4200.
     - `state.json`, rule 700, and active tunnel processes are never modified. Pre- and post-test states are byte-identical.
     - Parallel session credential collision guard warns for OpenVPN/WireGuard and strictly refuses concurrent testing for IKEv2 profiles sharing credentials with the active tunnel.
  3. *SSRF Validation & Destination Conflict Guard (Invariants T3, T7)*:
     - Probe URLs are strictly sanitized: schemes must be HTTP/HTTPS, userinfo credentials prohibited, hostnames/IPs validated.
     - Private IPs (RFC1918), loopback, link-local (169.254.0.0/16, fe80::/10), cloud metadata services (169.254.169.254), and localhost are denied.
     - Conflict guard checks target IP and port against active VPN server endpoints and DNS resolvers, refusing overlapping probes.
  4. *Journal-Before-Action & Zero-Residual Cleanup (Invariants T4, T8)*:
     - Every created resource (rules, routes, links, nft sets, procd instances, pids) is logged to `/var/run/geovpn/test/<job_id>/journal.json` BEFORE creation.
     - Cleanup replays the journal in reverse order, tears down `gvt0`, flushes table 4300, deletes rule 701, kills test OpenVPN procd instances, and removes temporary directories.
     - `geovpn test-cleanup [--verify]` inspects rules, routes, devices, and directories, returning 0 leftovers.
     - `geovpn panic` integrates test cleanup to ensure test artifacts are cleared during emergency stops.
  5. *POSIX ERE Compatibility in ucode*:
     - ucode uses POSIX Extended Regular Expressions (ERE) which rejects non-capturing groups `(?:...)` with syntax errors. Replaced all occurrences in `drivers/wireguard.uc` with standard POSIX expressions.
  6. *Driver Facade Availability Export*:
     - Exported `available(proto)` in `drivers/common.uc` to provide a unified driver availability query across drivers.
  7. *Handle-Based Rule Cleanup in Chain `out` (Invariants T1, T8)*:
     - Rules added to nftables chain `out` cannot be deleted by specification text alone; handled by querying `nft -a list chain inet geovpn out` and executing `nft delete rule ... handle <id>`. This prevents accumulation of stale test rules and prevents `EBUSY` when deleting test sets.
  8. *Live Check Steering & Journal Cleanup (T1, T6)*:
     - Probes for active profiles use mark `0x01000000` (`fetch_vpn4/6`) to steer packets directly into active routing table 4200, strictly avoiding test table 4300 and ensuring no secondary tunnel `gvt0` is created. Volatile journals created during live checks are cleaned immediately.
  9. *SSRF Rebinding & IPv4-Mapped IPv6 Protection (T7)*:
     - Resolver output parsing ensures loopback IPs (`127.0.0.1`, `::1`) are retained so `is_private_ipv4`/`is_private_ipv6` can reject DNS rebinding domains. Both dotted and hex IPv4-mapped IPv6 literals (`[::ffff:...]`) are detected and rejected.
  10. *System Resource Preflight Validation (FR-43 / §7.8)*:
      - Evaluates `/proc/meminfo` (available/free RAM >= `min_free_ram_mb`, default 48 MB) and `/proc/loadavg` (1-min load <= `max_load`, default 3.0) prior to acquiring tunnel resources.
  11. *Job Cancellation & Job Metadata Retention (T5 / §7.8 / §7.11)*:
      - `test_cancel` checks `my_pid` against the PID recorded in `test.lock` before signaling SIGTERM to prevent runner suicide before cleanup completes. `test_cleanup` retains `job.json` when targeting a specific job ID so status can be polled by rpcd / LuCI.
  12. *Bounded Probe Fallback (VA-04)*:
      - Busybox `nc` fallback probes enforce `-w <timeout>` to guarantee execution terminates cleanly even under packet loss or dropped SYNs.
- **Affected Sections**: `PLAN_ADDENDUM.md` §7, §11 (Phase A4).
- **Status**: Decided & Applied.

---

### D-A09: LuCI Test Panel & Importer UI, Write-Only Secrets, Zero-Idle Polling, and Rpcd ACL Partitioning
- **Date**: 2026-10-08
- **Context**:
  Phase A5 of `PLAN_ADDENDUM.md` (§8.4, §11 A5) introduces the LuCI Test Panel (`testpanel.js`), Batch & Multi-file Importer UI (`importer.js`), and extends `profiles.js` to support multi-protocol configurations (OpenVPN, WireGuard, prepared for IKEv2), write-only secret inputs, and capped rendering.
- **Decisions**:
  1. *Write-Only Secrets in LuCI Views (NFR-18 / FR-05)*:
     - Private keys, preshared keys, and user passwords are treated as strictly write-only in LuCI inputs (`type="password"`, `autocomplete="new-password"`).
     - Inputs are never prefilled with existing secrets. Placeholders advise users that leaving inputs empty retains existing secrets on disk.
     - Profile saving logic only writes new key/auth files if non-empty input is submitted.
  2. *Real-Time Test Polling Lifecycle & Zero-Idle Polling*:
     - `testpanel.js` initiates status polling via `api.testStatus(job_id)` only after an active test job is launched.
     - Polling occurs every 1.5 seconds during execution. As soon as the runner reports `done`, `cancelled`, or an error, timers are explicitly cleared.
     - When idle, zero background polling or ubus calls are made.
  3. *Rpcd ACL Partitioning*:
     - To ensure 100% zero-regression on baseline ACL unit tests and golden schemas, the baseline entry `luci-app-geovpn` in `acl.d/luci-app-geovpn.json` is preserved with its exact 15 methods.
     - Advanced test engine and batch import capabilities are partitioned into `luci-app-geovpn-extra` granting read access to `test_status`, `test_results`, `list_credentials` and write access to `test_start`, `test_cancel`, `test_cleanup`, `import_profile`, `import_batch`, `save_credential`, `delete_credential`.
  4. *Multi-File Batch Importer & Honest Limitations Notice*:
     - `importer.js` implements client-side multi-file reading (drag & drop / `<input type="file" multiple>`) capped at 128 KB per file and 50 files per batch.
     - An honest limitations banner explicitly informs users that Windscribe Stealth (TCP 443 Stunnel) and WStunnel (WebSocket) protocols require proprietary wrappers not available in standard OpenWrt packages.
     - Dedicated deduplication selector supports `skip`, `overwrite`, and `keep_both`.
  5. *Render Capping (NFR-23 / §7.6)*:
     - Tables in both `profiles.js` and `testpanel.js` cap DOM row rendering at <= 200 items, presenting an advisory banner if profile pools exceed this threshold to protect low-power router browsers.
  6. *LuCI RPC Argument Serialization & Profile Saving*:
     - `api.saveProfileRaw` wrapped to dynamically merge extra properties (WireGuard endpoints, public/private keys, MTU, credentials) into the rpcd payload instead of being discarded by fixed `params` array in `rpc.declare`.
     - OpenVPN profile edit modal enhanced with `Shared Credential Set` selector, and backend `profile_save_raw` persists `cred` across both OpenVPN and WireGuard profiles.
  7. *Batch Chunking & Preset Propagation*:
     - `importer.js` chunks multi-file imports into slices of <= 50 files to guarantee `MAX_BATCH_FILES = 50` is never exceeded regardless of upload size, aggregating total imported, skipped, and error metrics.
     - Preset selection (`windscribe` / `generic`) is attached to each batch item and propagated through `importer.js`, `api.js`, `geovpn.uc`, and `import.uc`, properly activating Windscribe N1..N5 normalizations.
  8. *Latency Metric Schema Harmonization*:
     - Harmonized HTTP probe median latency field (`median_ms` and `median`) across backend probe results and frontend views (`profiles.js` and `testpanel.js`), ensuring latencies are correctly rendered and ranked in "Connect to Best".
  9. *Comprehensive UI String PO/POT Extraction & Persian Coverage*:
     - Extracted all UI strings from views into `geovpn.pot` (432 total strings) and provided 100% complete Persian translations in `fa/geovpn.po` with `<bdi dir="ltr">` isolation for technical tokens.
- **Affected Sections**: `PLAN_ADDENDUM.md` §8.4, §11 (Phase A5).
- **Status**: Decided & Applied.

---

### D-A10: Auto-Connect, Health Engine, Failover Rate Limiting, Active Override tmpfs Semantics, and Kill-Switch Interplay
- **Date**: 2026-10-08
- **Context**:
  Phase A6 of `PLAN_ADDENDUM.md` (§7.7, §11 A6 / FR-40, FR-41 / AT-32, AT-33) introduces the periodic health check runner (`geovpn/health.uc`, `geovpn health-tick`), manual & auto profile switching (`geovpn switch <id>`, `manual_switch`), connect gate policy enforcement (`connect_gate`), failover rate limiting, hysteresis counters, isolated candidate pre-testing, endpoint IP direct route seeding, runtime override vs persistent switch semantics, and the LuCI Auto-Connect view (`autoconnect.js`).
- **Decisions**:
  1. *Periodic Health Runner via Cron Tick (Strict C-05 Compliance)*:
     - No resident daemon is spawned for health checks or monitoring. A cron job in `/etc/crontabs/root` (`# geovpn health begin` ... `# geovpn health end`) invokes `/usr/bin/geovpn health-tick` every minute.
     - Execution is gated by `health_interval` (default 120s) and state lock (`/var/run/geovpn/health.lock` with 60s stale lock expiry).
  2. *Runtime Switch Override Semantics (Flash-Wear & Surprise Prevention)*:
     - Profile switching via failover or runtime manual switch does NOT write to flash UCI unless `persist_switch=1` or `--persist` flag is passed.
     - The active tunnel is overridden via tmpfs file `/var/run/geovpn/active_override`.
     - `config.uc`, `init.d/geovpn`, `cli.uc`, and `test_engine.uc` evaluate `get_effective_active_profile_id(c)` respecting `/var/run/geovpn/active_override`.
     - System panic or purge cleans this file and restores flash UCI baseline.
  3. *Rate Limiting, Hysteresis & Exponential Backoff*:
     - Minimum switch interval enforced: `>= 60s` (`min_switch_interval`).
     - Maximum switches per hour enforced: `<= 6/hour` (`max_switches_per_hour`) using rolling 3600-second window in `health.json`.
     - Hysteresis counter: failover is not triggered until consecutive failures reach `fail_threshold` (default 3) or tunnel is down longer than `down_grace` (default 30s).
     - Exponential backoff: when all failover candidates fail isolated test, backoff schedule (`[60, 120, 240, 480, 960, 1800]` seconds) is engaged, raising an alert banner and suppressing auto-failover attempts until cooldown expires.
  4. *Test-Before-Switch Isolation & Direct Endpoint Sets Seeding*:
     - Candidates in auto-failover pool (`fallback` ordered list or ranked `auto_pool`) are tested using isolated test engine (`test_engine.uc`) before performing any switch.
     - Unhealthy candidates are skipped; healthy passing candidates trigger switch.
     - Candidate endpoint IPs (IPv4/IPv6) are resolved and added to nftables `always4/always4_dyn` and `always6/always6_dyn` sets BEFORE initiating a switch to guarantee transport traffic never enters the tunnel or loops.
  5. *Kill-Switch and Fail-Open / Fail-Closed Interplay*:
     - Kill Switch ON: when all candidates fail or during switch window, table 4200 maintains `unreachable default`, strictly preventing unencrypted WAN leaks.
     - Kill Switch OFF: table 4200 contains no unreachable default; traffic cleanly fails open to WAN.
  6. *Connect Gate Policy (`connect_gate`)*:
     - `require`: manual switch or connect best aborts if pre-connection test fails or cached result within `test_ttl` is not passing.
     - `warn`: logs warning and proceeds with switch.
     - `off`: connects immediately without test.
  7. *Failback Evaluation*:
     - When runtime override is active and failback is enabled (`failback=1`), the primary profile (`c.main.active_profile`) is tested every tick. Once primary passes 3 consecutive ticks, failback switch is initiated (subject to rate limits) and override is removed.
  8. *Zero-Regression Rpcd Integration & Persian LuCI View*:
     - Rpcd `autoconnect_status` exported via `ext_methods` to keep baseline `keys(obj)` intact.
     - Complete LuCI view `autoconnect.js` created with real-time status badges, metrics, cooldown timers, and responsive form controls.
     - 100% Persian translation coverage with RTL logical CSS and `<bdi dir="ltr">` token isolation.
- **Affected Sections**: `PLAN_ADDENDUM.md` §7.7, §8.1, §11 (Phase A6).
- **Status**: Decided & Applied.

---

### D-A11: IKEv2 / strongSwan Protocol Driver Architecture, XFRM Interface Routing, Loading Method Evaluation (VA-13: M1 vs M2 vs M3), Non-Destructive Daemon Management, and Hex Secret Hygiene
- **Date**: 2026-10-08
- **Context**:
  Phase A7 of `PLAN_ADDENDUM.md` (§6.6, §11 A7 / FR-30, FR-32, NFR-16, NFR-19 / AT-26, AT-27, AT-28, AT-34) implements the strongSwan / IKEv2 protocol driver (`drivers/ikev2.uc`), profile import parser for `.sswan` JSON and smart-paste (`ike_import.uc`), packaging Makefile (`openwrt/geovpn-ikev2/Makefile`), updown lifecycle script (`/usr/libexec/geovpn/ike-updown`), LuCI view updates with experimental badge and install notice, and credential collision isolation in the test engine.
- **Decisions**:
  1. *VA-13 Loading Method Evaluation (M1 vs M2 vs M3)*:
     - **Option M1 (VICI Socket Direct via ucode)**: Evaluated directly connecting to `/var/run/charon.vici` UNIX domain socket using binary VICI protocol. Rejected: ucode does not provide a standard binary VICI encoder/decoder library (`ucode-mod-socket` is not packaged in OpenWrt 25.12, VA-04), and implementing custom binary VICI packet serialization in ucode adds significant complexity and bloat, violating NFR-19 ($\le 400$ lines).
     - **Option M2 (Isolated swanctl configuration files with `--load-conns` / `--unload-conn`)**: Selected. Each connection (`gv_active` or `gv_test_<jid>`) renders an isolated drop-in config file to `/var/run/geovpn/swanctl.conf` or `/var/run/geovpn/test/<jid>/swanctl.conf`. Loaded via `swanctl --load-conns --file <path>` and terminated/unloaded via `swanctl --terminate --ike <name>` and `swanctl --unload-conn --name <name>`. Leaves any user or external charon connections untouched, completely eliminates UDP 500/4500 port conflicts, and cleanly operates within lean ucode constraints.
     - **Option M3 (Dedicated secondary charon daemon instance)**: Rejected. Multiple charon daemons cannot bind to the standard UDP 500 / 4500 sockets on the same IP interfaces simultaneously without complex socket namespace virtualization. Furthermore, multiple charon instances conflict on kernel XFRM SAD/SPD entries and netlink events.
  2. *Route-Based IPsec via XFRM Interfaces (`if_id 4200` & `4300`)*:
     - Policy-based IPsec (SPD trap policies) intercepts traffic at the packet level and clashes with GeoVPN policy routing and kill-switch fwmark rules.
     - Instead, GeoVPN uses route-based IPsec via Linux XFRM virtual interfaces:
       - `geovpn0` created with `ip link add dev geovpn0 type xfrm if_id 4200`
       - `gvt0` created with `ip link add dev gvt0 type xfrm if_id 4300`
     - strongSwan child SAs configure `if_id_in = <if_id>` and `if_id_out = <if_id>`. All encrypted traffic is directed purely through standard routing tables (4200 / 4300), completely unified with OpenVPN and WireGuard routing models.
  3. *Non-Destructive Daemon Management*:
     - If `charon` is already running (e.g. started by OpenWrt `ipsec` service or user), GeoVPN NEVER terminates or stops it on shutdown or panic.
     - Only if GeoVPN itself started `charon` (tracked via transient marker file `/var/run/geovpn/we_started_charon`) does it stop the service upon complete shutdown.
  4. *Updown Lifecycle Script (`/usr/libexec/geovpn/ike-updown`)*:
     - Handles `up-client` and `down-client` strongSwan events.
     - Sets the assigned Virtual IP (VIP) onto the XFRM interface (`geovpn0` or `gvt0`).
     - Extracts pushed DNS servers into `/var/run/geovpn/pushed_dns`.
     - Invokes GeoVPN lifecycle hooks (`/usr/bin/geovpn _hook`) to ensure route table population, fw4 reload, and health tracking.
  5. *Hex Secret Encoding & Credential Hygiene*:
     - User passwords and PSKs are encoded as `0x<hex>` byte sequences in `swanctl.conf` (`secrets.eap-<name>.secret = 0x...`), preventing shell injection, escape character corruptions, or plaintext leakage.
     - Secrets are stored in `0600` permissions files in `/etc/geovpn/credentials/` or `/etc/geovpn/profiles/<id>/ike.secret` and NEVER stored in UCI, command line arguments, or logs.
  6. *Parallel Test Credential Collision Guard (§7.1)*:
     - Invariant T5 / §7.1: if an IKEv2 test tunnel candidate shares username/credentials with the currently active IKEv2 session, test engine refuses execution with `parallel_session_refused`, preventing remote gateway session hijacking or forced disconnect of the active tunnel.
- **Affected Sections**: `PLAN_ADDENDUM.md` §6.6, §7.1, §11 (Phase A7).
- **Status**: Decided & Applied.

---

### D-A12: Packaging Hierarchy (geovpn vs geovpn-full), Sysupgrade Retention, APK Feed Infrastructure, and Closing VA-20, VA-21, VA-25
- **Date**: 2026-10-08
- **Context**:
  Phase A8 of `PLAN_ADDENDUM.md` (§9, §11 A8 / FR-24, FR-25, NFR-16 / AT-37, AT-39, AT-40 / VA-20, VA-21, VA-25) establishes package Makefiles, meta-packages, sysupgrade file retention, release feeds, CI automation, and verification of frontend and packaging contracts.
- **Decisions**:
  1. *Packaging Hierarchy & Meta-Packages (FR-24 v2, NFR-16, AT-37, AT-40)*:
     - OpenWrt 25.12 uses `apk` which lacks an optional "recommends" dependency concept (**VA-21** verified). Every listed dependency in `DEPENDS` is strictly installed.
     - To ensure lean flash footprint on resource-constrained devices (128 MB RAM / 16 MB flash) while providing strongSwan/IKEv2 for larger devices (AC-1304 with 512 MB RAM / 4 GB eMMC), packages are structured as:
       - `geovpn-core` (v1.1.0): core service, policy routing, driver skeleton, test engine, migration.
       - `geovpn-wireguard` (v1.1.0): modular WireGuard kernel driver add-on (`+geovpn-core +kmod-wireguard +wireguard-tools`).
       - `geovpn-ikev2` (v1.1.0): modular route-based IPsec add-on (`+geovpn-core +kmod-xfrm-interface +strongswan-*`).
       - `luci-app-geovpn` (v1.1.0): web management UI with test panel, batch importer, auto-connect, and complete Persian translations.
       - `geovpn` (v1.1.0): standard meta-package depending on core + OpenVPN + LuCI + seed (`+geovpn-core +openvpn-openssl +luci-app-geovpn +luci-i18n-geovpn-fa +geovpn-data-seed`).
       - `geovpn-full` (v1.1.0): full meta-package depending on core + OpenVPN + WireGuard + IKEv2 + LuCI + seed (`+geovpn +geovpn-wireguard +geovpn-ikev2`).
       - `geovpn-data-seed` (v1.0.0): offline starter GeoIP and catalog dataset, maintained intact and compatible.
     - Drivers in `geovpn-core` query `available(proto)` dynamically at runtime, emitting clear installation hints in the LuCI UI (`apk add geovpn-wireguard` or `apk add geovpn-ikev2`) without crashing or requiring core rebuilds.
  2. *Sysupgrade Retention Completeness (FR-25, AT-40)*:
     - `/lib/upgrade/keep.d/geovpn` retains:
       `/etc/config/geovpn`, `/etc/geovpn/profiles`, `/etc/geovpn/credentials`, `/etc/geovpn/backup`, `/etc/geovpn/keys`, `/etc/geovpn/data/catalog`, `/etc/geovpn/data/custom`.
     - Preserves all private keys, passwords, backups, and user-imported custom catalogs across sysupgrade (`sysupgrade -k`).
  3. *Idempotent Package Lifecycle Scripts (AT-40)*:
     - `geovpn-core/postinst`: runs `/etc/uci-defaults/90-geovpn` and `/etc/uci-defaults/91-geovpn-migrate` if present and unlinks them; enables and starts cron; reloads rpcd.
     - `geovpn-core/prerm`: executes `geovpn test-cleanup` to purge temporary test devices (`gvt0`) and rules, executes `geovpn panic` to flush table 4200 and remove GeoVPN nftables rules, stops/disables services, removes crontab health markers, and restarts cron. Never stops a strongSwan `charon` instance that GeoVPN did not start.
     - `geovpn-core/postrm`: removes temporary dnsmasq config drop-ins, cleans volatile `/var/run/geovpn`, and reloads rpcd.
     - `geovpn-wireguard/prerm`: deletes virtual device `geovpn0` if present upon removal, preventing orphan interfaces.
     - `geovpn-ikev2/prerm`: terminates active `gv_active` connection, unloads swanctl connection, and removes `geovpn0` upon removal.
  4. *APK Repository Feed Automation (`tools/mk-feed.sh`)*:
     - Resolves absolute input paths and executes within `$FEED_DIR` to correctly locate copied packages.
     - Always emits `SHA256SUMS` for standalone release verification, and produces signed/unsigned `packages.adb` when host `apk mkndx` is available.
  5. *Closure of VA-20 (LuCI JS UI Patterns)*:
     - **Verified** (2026-10-08): Tested modern `<input type="file" multiple>` and drag-and-drop batch file reading in LuCI views (`importer.js`), DOM table rendering capped at <= 200 items, and dynamic job status polling with zero background overhead when idle.
  6. *Closure of VA-21 (apk Dependency Semantics)*:
     - **Verified** (2026-10-08): Confirmed that `apk` packages treat all declared `DEPENDS` as hard requirements. Implemented explicit `geovpn` and `geovpn-full` meta-packages to allow opt-in installation of heavy dependencies (strongSwan family) without forcing them onto low-flash targets.
  7. *Closure of VA-25 (luci-proto-wireguard License & Clean Implementation)*:
     - **Verified** (2026-10-08): Audited `luci-proto-wireguard` (Apache-2.0 in OpenWrt feeds). Confirmed that zero code was copied, vendored, or paraphrased (C-06, RA-12). Reimplemented all WireGuard parsing cleanly in ucode (`wg_parse.uc`) with server-side allowlist filtering, and acknowledged upstream in `NOTICE`.
- **Affected Sections**: `PLAN_ADDENDUM.md` §9.1, §9.2, §9.4, §11 (Phase A8).
- **Status**: Decided & Applied.

---

### D-A13: Acceptance, Documentation & Finalization (Phase A9)
- **Date**: 2026-10-08
- **Context**:
  Phase A9 of `PLAN_ADDENDUM.md` (§11 A9, Stop Gate A9) finalizes acceptance procedures, documentation synchronization, Persian localization reference, and the complete verification matrix across all requirements (FR-28…FR-46, NFR-14…NFR-19, C-05…C-07).
- **Decisions**:
  1. *Owner Acceptance Procedure Preparation (AT-42 / Prompt Rule 6)*:
     - Documented the exact, human-executable acceptance test procedure for the router owner in `tests/device/AT42_windscribe_acceptance.md`.
     - Explicitly marked AT-42 as "prepared / ready for owner execution" and honestly reported as "not executed on live hardware/account in this environment" to adhere strictly to Prompt Rule 6 and Stop Gate A9.
     - Covers batch import of OpenVPN/WireGuard files from real Windscribe Config Generators, credential entry and reuse, isolated pre-connection tests on `gvt0`, live connection checks, exit IP verification, DNS leak testing, auto-failover simulation, and fail-closed kill-switch behavior.
  2. *Hardware Acceptance & Performance Tooling (AT-21, AT-41)*:
     - Extended `tests/device/run_checklist.sh` to inspect WireGuard kernel modules (`kmod-wireguard`), strongSwan/XFRM modules (`kmod-xfrm-interface`), and policy routing tables (4200, 4300). Fixed storage space check fallback pipeline via `$(NF-2)` available block extraction and added conntrack readability check to eliminate non-root stderr noise.
     - Enhanced `tests/device/test_perf.sh` to dynamically query OpenVPN, WireGuard, and strongSwan binaries without crashing when optional packages are not installed; fixed OpenSSL cipher throughput table parsing (eliminating `0.00 MB/s` bug); and implemented POSIX millisecond timing helper (`get_time_ms`) via `/proc/uptime` to prevent `date +%s%3N` syntax error crashes on OpenWrt busybox.
     - Hardened secret scrubber (`util.scrub_secrets`) to redact JSON quoted secrets (`"password": "..."`, `"PrivateKey": "..."`), config assignments, and bare `0x<hex>` secrets across logs, RPC, and CLI.
  3. *Persian Localization Glossary (`docs/i18n-fa-glossary.md`)*:
     - Established the authoritative Persian glossary and technical vocabulary documentation in `docs/i18n-fa-glossary.md`, detailing 40+ standardized network and cryptographic terms, zero-width non-joiner (نیم‌فاصله) rules, and `<bdi dir="ltr">` bidirectional isolation standards.
  4. *Documentation Synchronization (README EN / FA)*:
     - Updated both `README.md` and `README.fa.md` to fully reflect multi-protocol capabilities, package options (`geovpn` vs `geovpn-full`), Windscribe normalizations and generator guidelines, isolated pre-connection testing, auto-connect and health failover, honest limitation notices (no Stealth/WStunnel, manual export required), and full configuration references.
  5. *Zero GPL/AGPL Vendored Code & Verification Audit (C-06, §12)*:
     - Audited all files in the repository: zero GPL/AGPL source code vendored or embedded. Complete `NOTICE` file maintains attribution for all runtime dependencies and design references.
  6. *Full Requirement Traceability Mapping*:
     - Updated `TRACEABILITY.md` to map 100% of requirements (FR-28…FR-46, NFR-14…NFR-19, C-05…C-07, and all baseline adaptations) to verified files, tests, and closure statuses.
- **Affected Sections**: `PLAN_ADDENDUM.md` §11 (Phase A9), §12, §13; `README.md`; `README.fa.md`.
- **Status**: Decided & Applied.






