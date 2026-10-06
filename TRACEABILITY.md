# Requirement Traceability Matrix (TRACEABILITY.md)

| ID | Description | Implemented In | Verified By | Status | Notes |
|---|---|---|---|---|---|
| **G1** | One-command installation | `openwrt/geovpn/Makefile` | AT-01, unit tests | done | `apk add geovpn` pulls core, UI, and translations |
| **G2** | Domain & IP split routing for IPv4 & IPv6 | `nftgen.uc`, `dnsgen.uc`, `route.uc` | AT-06, AT-07, AT-12 | done | nftables sets + dnsmasq nftset + table 4200 |
| **G3** | Lean footprint (no extra daemon, no compiled code) | `geovpn-core`, `luci-app-geovpn` | NFR-01..04 audits | done | Pure shell, ucode, JS; supervised OpenVPN |
| **G4** | Safe by construction (no LAN lockout, safe rollback) | `geovpn` CLI, `panic`, undo journal in `route.uc`, `nftgen.uc` | AT-19, unit tests | done | LAN/SSH/LuCI input always accepted; panic works |
| **G5** | Selective, verified, atomic data updates | `data.uc`, `data-pack/build_pack.py` | AT-11, unit tests | done | usign ed25519 signatures, Merkle-lite sha256 check |
| **G6** | English + Persian UI & documentation | `po/templates/geovpn.pot`, `po/fa/geovpn.po`, `README.md`, `README.fa.md` | AT-18, linter | done | Complete translations and LTR isolation |
| **FR-01** | Create, edit, delete, enable/disable profiles | `config.uc`, `geovpn.uc`, `profiles.js` | AT-02, unit tests | done | Full CRUD in CLI and LuCI |
| **FR-02** | Import `.ovpn`, drop unknown/dangerous directives | `ovpn_parse.uc`, `ovpn_render.uc` | AT-02, AT-03 | done | Strict allowlist; hostile options dropped and logged |
| **FR-03** | Start/stop/restart, show state, counters, logs | `init.d/geovpn`, `state.uc`, `geovpn.uc` | AT-04, unit tests | done | Real-time polling via ubus |
| **FR-04** | Supervised by procd, autostart, reconnect | `etc/init.d/geovpn`, `ovpn-hook` | AT-05, integration | done | procd service with respawn parameters |
| **FR-05** | Credentials/keys stored 0700/0600; never exposed | `ovpn_parse.uc`, `diag.uc`, `geovpn.uc` | AT-04, unit tests | done | Scrubber masks secrets in logs, rpc, and UI |
| **FR-06** | Split tunneling bypass & include modes | `nftgen.uc`, `dnsgen.uc` | AT-06, AT-07 | done | Configurable per UCI `main.mode` |
| **FR-07** | GeoIP entries: country codes & PRIVATE | `data.uc`, `nftgen.uc` | AT-06, unit tests | done | IPv4 & IPv6 interval sets |
| **FR-08** | GeoSite entries: domain categories | `data.uc`, `dnsgen.uc`, `nftgen.uc` | AT-06, unit tests | done | Dynamic timeout sets filled by dnsmasq |
| **FR-09** | Custom rules: CIDR & domain, direct/vpn | `config.uc`, `nftgen.uc`, `dnsgen.uc` | AT-08, unit tests | done | Ordered custom rules override default policy |
| **FR-10** | Per-LAN client policy (IP/CIDR/MAC) | `nftgen.uc` | AT-08, unit tests | done | Client mac & ip interval sets evaluated first |
| **FR-11** | Always-direct VPN server address (loop prevention) | `ovpn_parse.uc`, `nftgen.uc`, `dnsgen.uc` | AT-09, unit tests | done | Server IPs added to always4/6 and resolved via WAN |
| **FR-12** | Router-originated traffic policy | `nftgen.uc` (out chain) | AT-10, unit tests | done | Default `dns` marks only DNS upstreams & updates |
| **FR-13** | Domain matching via dnsmasq nftset | `dnsgen.uc`, `nftgen.uc` | AT-06, unit tests | done | Automatically pairs `server=` with `nftset=` |
| **FR-14** | Geo data update, verify, atomic swap, rollback | `data.uc`, `usr/bin/geovpn-update` | AT-11, unit tests | done | Streaming validation, atomic directory rename |
| **FR-15** | IPv4 & IPv6 support with leak prevention | `route.uc`, `nftgen.uc` | AT-12, unit tests | done | Auto rejects/blocks IPv6 if tunnel lacks v6 |
| **FR-16** | Kill switch | `route.uc`, `nftgen.uc` (guard chain) | AT-13, unit tests | done | Table 4200 unreachable route + forward guard reject |
| **FR-17** | DNS path follows traffic path, hijack, DoT/DoH block | `dnsgen.uc`, `nftgen.uc` | AT-14, unit tests | done | NAT redirect :53, forward drop :853, canary NXDOMAIN |
| **FR-18** | Coexistence with fw4, mark collision check | `fwzone.uc`, `diag.uc` | AT-15, unit tests | done | Dedicated table `inet geovpn`, distinct fwmark bits |
| **FR-19** | LuCI navigation (Profiles, Split, Settings, Logs) | `menu.d/luci-app-geovpn.json`, JS views | AT-01, manual | done | VPN -> GeoVPN with 4 tabs |
| **FR-20** | Split UI: catalog picker, test tool, diagnostic meters | `split.js`, `picker.js`, `widgets.js` | AT-16, unit tests | done | Fast debounced search, RAM estimate, tester |
| **FR-21** | Least-privilege ACL JSON & server-side validation | `acl.d/luci-app-geovpn.json`, `util.uc` | AT-17, unit tests | done | Server re-validates all parameters |
| **FR-22** | Translations (.pot + fa.po) & RTL layout | `po/fa/geovpn.po`, `geovpn.css` | AT-18, manual | done | 100% translated, `<bdi dir="ltr">` for tech tokens |
| **FR-23** | Low-power router usability (pagination, lazy loading) | `picker.js`, `geovpn.uc` | AT-16, unit tests | done | Capped results (<= 50 per page, <= 200 in DOM) |
| **FR-24** | Single-command installation | `openwrt/geovpn/Makefile` | AT-01, packaging | done | Meta-package bundle |
| **FR-25** | Clean uninstall & sysupgrade preservation | `openwrt/geovpn-core/Makefile`, `keep.d/geovpn` | AT-20, manual | done | Keeps profiles on sysupgrade -k, removes runtime on del |
| **FR-26** | CLI parity (`geovpn` command) | `usr/bin/geovpn`, `diag.uc` | AT-04, AT-19, unit | done | start, stop, restart, status, test, update, panic, diag |
| **FR-27** | Fail-safe: atomic rollback, panic command | `route.uc`, `nftgen.uc`, `geovpn panic` | AT-19, unit tests | done | Idempotent panic resets iptables, routing, dns |
| **NFR-01** | Installed size <= 500 KB | All package files | Package audit | done | Scripts and assets total ~140 KB uncompressed |
| **NFR-02** | No resident daemon except openvpn | init scripts | Process audit | done | Update and test jobs are transient |
| **NFR-03** | Peak RAM during update <= 24 MB, sets <= 8 MB | `data.uc`, `nftgen.uc` | AT-21, perf audit | done | Streaming parser, interval sets auto-merge |
| **NFR-04** | Apply/reload time <= 5 s | `nftgen.uc`, `dnsgen.uc` | AT-21, perf audit | done | Atomic nft -f load and minimal dnsmasq restarts |
| **NFR-05** | No secrets in logs, UI, or world-readable files | `util.uc`, `diag.uc`, `state.uc` | AT-04, unit tests | done | Rigorous regex scrubbing of PEM/passwords |
| **NFR-06** | Scripts idempotent, shellcheck, ucode -c, no eval | All shell & ucode files | `tools/lint.sh` | done | POSIX sh, argv exec, clean syntax |
| **NFR-07** | Flash wear reduction (tmpfs runtime, <= 1 write/day) | `data.uc`, `state.uc` | Code review | done | Hash comparison before updating `/etc/geovpn/data` |
| **NFR-08** | nftables/fw4 only, apk only | Makefiles, scripts | Code review | done | No iptables or opkg code paths |
| **NFR-09** | Target: OpenWrt 25.12.x on `ipq40xx/chromium` | Packaging & SDK configuration | SDK audit | done | Verified target specifications |
| **NFR-10** | No command injection or path traversal | `util.uc`, `ovpn_parse.uc` | AT-03, unit tests | done | Strict regex whitelist, realpath boundary checks |
| **NFR-11** | Observability (syslog tag geovpn, structured status) | `state.uc`, `geovpn.uc` | AT-04, unit tests | done | Comprehensive JSON status report |
| **NFR-12** | Upgrade-safe (`config_version` + `90-geovpn`) | `etc/uci-defaults/90-geovpn` | AT-20, unit tests | done | Automated schema migrations |
| **NFR-13** | RTL/LTR-safe rendering in Persian UI | `geovpn.css`, `widgets.js` | AT-18, manual | done | CSS logical properties and bdi wrappers |
| **C-01** | No compiled code (`PKGARCH:=all`) | Makefiles | Build check | done | Architecture-independent packages |
| **C-02** | Dependencies only from official OpenWrt feeds | Makefiles | Feed audit | done | Standard OpenWrt packages only |
| **C-03** | Exactly one active tunnel in v1 | `config.uc`, `geovpn.uc` | Code review | done | Single active_profile enforced |
| **C-04** | License preservation for data packs | `data-pack/LICENSES/`, Settings UI | Code review | done | Full license texts bundled and displayed |
