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
| **FR-28** | Protocol-agnostic profile model & driver interface | `drivers/{common,openvpn}.uc` | AT-22, unit tests | done (A1) | Split layer remains protocol-blind; OpenVPN driver extracted |
| **FR-29** | WireGuard client driver (AllowedIPs, split, kill switch, DNS) | `drivers/wireguard.uc` | AT-25, unit tests | done (A2) | Direct ip/wg execution, kernel WireGuard, facts polling |
| **FR-30** | IKEv2 client driver (EAP-MSCHAPv2, XFRM interface) | `drivers/ikev2.uc`, `ike-updown` | AT-34, `test_ikev2.py` | done (A7) | Optional package `geovpn-ikev2` |
| **FR-31** | WireGuard .conf import (0600 key files, safe parser) | `wg_parse.uc`, `cli.uc` | AT-24, unit tests | done (A2) | PostUp/hooks rejected, hostile corpus tests, default route check |
| **FR-32** | IKEv2 profiles (form, smart paste, .sswan import) | `ike_import.uc`, `importer.js`, `profiles.js` | AT-34, `test_ikev2.py` | done (A7) | strongSwan Android and smart paste input |
| **FR-33** | Windscribe first-class (auto-detect, normalizations) | `import.uc`, `ovpn_parse.uc`, `wg_parse.uc` | AT-26, AT-24, AT-42 | done (A3) | OpenVPN N1/N2, dedupe N3, MTU/MSS N4, DNS N5, Stealth/WStunnel detection |
| **FR-34** | Shared credential sets (1 credential referenced by N profiles) | `cred.uc`, `drivers/`, `import.uc` | AT-35, unit tests | done (A3) | Stored 0700/0600 under `/etc/geovpn/credentials`, referenced by `cred`, driver integration |
| **FR-35** | Batch import of multiple files with dedupe and naming | `import.uc`, `cli.uc`, `geovpn.uc` | AT-36, unit tests | done (A3) | Multi-file directory batch, content hash & endpoint dedupe, atomic rollback, limits |
| **FR-36** | Test types: endpoint probe, real tunnel test, latency/jitter | `test_engine.uc`, `geovpn-test` | AT-30, unit tests | done (A4) | Isolated gvt0 device, HTTP 204 timing, monotonic clock() |
| **FR-37** | Test tunnel isolation (never touches table 4200 or active VPN) | `test_engine.uc`, `route.uc` | AT-27, AT-28 | done (A4) | Device gvt0, table 4300, mark 3, fail-closed unreachable default |
| **FR-38** | Test UI (Test, Test all, Cancel, progress, sort, filter) | `testpanel.js`, `profiles.js` | AT-31, `test_luci_views.py` | done (A5) | Real-time job polling, responsive table, zero polling when idle |
| **FR-39** | Configurable pass/fail thresholds & test target URLs | `config.uc`, `test_engine.uc` | AT-30, unit tests | done (A4) | UCI section `test` (handshake, latency, loss thresholds) |
| **FR-40** | Connect policies (manual, connect_gate, best, fallback) | `health.uc`, `cli.uc`, `config.uc` | AT-32, `test_health.py` | done (A6) | UCI section `autoconnect`, connect_gate (require/warn/off), ordered fallback & best |
| **FR-41** | Health checks & automatic failover (cron tick, backoff) | `health.uc`, `cli.uc`, `test_engine.uc` | AT-33, `test_health.py` | done (A6) | Strictly C-05 compliant cron tick (no daemon); hysteresis, rate limiting, isolated test-before-switch, kill switch fail-closed/fail-open interplay |
| **FR-42** | Test query anonymity & URL validation (SSRF protection) | `test_engine.uc`, `util.uc` | AT-28, unit tests | done (A4) | Private IP, loopback, link-local, cloud metadata denied |
| **FR-43** | Test resource limits (concurrency, deadlines, preflight) | `test_engine.uc` | AT-29, AT-31 | done (A4) | Max 1 real test, 15s hard deadline, RAM preflight check |
| **FR-44** | Cleanup guarantees & journal (geovpn test-cleanup) | `test_engine.uc`, `route.uc`, `cli.uc` | AT-29, unit tests | done (A4) | Journal-before-action, idempotent cleanup on exit/crash/panic |
| **FR-45** | Safe config migration v1->v2 (backup, rollback) | `91-geovpn-migrate`, `config.uc` | AT-22, AT-23 | done (A1) | Backward-compatible; rollback & downgrade command |
| **FR-46** | CLI parity for new verbs (test, cleanup, switch, import, health-tick) | `cli.uc`, `usr/bin/geovpn` | AT-22..36 | done (A1..A6) | test, test-cleanup, panic rollback, WG import, batch import, switch, health-tick |
| **NFR-14** | Test impact on active tunnel latency <= 20% | `test_engine.uc`, routing | AT-27, AT-41 | done (A4) | Separate routing table 4300, gvt0 interface, isolated marks |
| **NFR-15** | Backward compatibility & downgrade to baseline | `91-geovpn-migrate`, `config.uc` | AT-22, AT-23 | done (A1) | v1 configurations run without alteration |
| **NFR-16** | Optional packages for WireGuard & IKEv2 | Makefiles, LuCI views | AT-37, packaging | done (A2, A7) | `geovpn-wireguard` and `geovpn-ikev2` packages created |
| **NFR-17** | Size budget: <= +160 KB scripts/JS over baseline | package tree audit | AT-41, audit | tracked (A0..A8) | Tracked at every phase (A4 added test engine ucode ~40 KB) |
| **NFR-18** | Secrets isolation (never in UCI, logs, argv, or RPC) | `cred.uc`, `test_engine.uc` | AT-24, AT-30, AT-35 | done (A4) | Secrets scrubbed; test results strictly devoid of keys/creds |
| **NFR-19** | Driver modularity (<= 400 lines ucode each) | `drivers/*.uc` | Code audit | done (A1, A2, A3, A4, A7) | common.uc (232 l), openvpn.uc (398 l), wireguard.uc (387 l), ikev2.uc (356 l) |
| **C-05** | No new resident process added | cron runner, transient jobs | System audit | done | Health check via cron tick |
| **C-06** | Zero GPL/AGPL vendored code | `NOTICE`, repository audit | Legal audit | done (A0) | Upstream packages used via system CLI/RPC |
| **C-07** | Test traffic fail-closed (table 4300 unreachable first) | `route.uc`, `test_engine.uc` | AT-28, unit tests | done (A4) | Unreachable default installed before link raise |
| **AT-01..21** | Baseline acceptance suite (21 scenarios) | `tests/unit/`, `tests/integration/` | Unit & harness | done | Regression suite passes 100% |
| **AT-22** | Migration zero-behavior change (golden diff = empty) | `test_golden_baseline.py` | Golden fixtures | done (A0, A1) | 10 baseline artifacts asserted with 0-byte diff |
| **AT-23** | Safe migration, idempotency, backup & rollback | `tests/unit/test_migrate.py` | Unit tests | done (A1) | 11 unit tests covering migration, rollback, downgrade, contract, symmetry, and shell fallback |
| **AT-24** | WG import: valid + Windscribe-shaped; hostile corpus rejected; secrets safe | `wg_parse.uc`, `cred.uc`, `test_wireguard.py` | Unit tests | done (A2) | Tested INI parser, hooks/Amnezia rejection, key permissions |
| **AT-25** | WG tunnel lifecycle, AllowedIPs cryptokey routing, facts & pushed DNS | `drivers/wireguard.uc`, `test_wireguard.py` | Unit tests | done (A2) | Tested direct ip/wg lifecycle, facts dump parsing, DNS push |
| **AT-26** | Windscribe-shaped presets (N1..N5 normalizations, Stealth notices) | `import.uc`, `ovpn_parse.uc`, `wg_parse.uc` | `test_import.py`, unit tests | done (A3) | N1 ping-restart, N2 keepalive, N3 dedupe, N4 MTU/MSS, N5 DNS, Stealth notice |
| **AT-27** | Pre-conn test isolation: active tunnel, table 4200, state.json untouched (T1, T6) | `test_engine.uc`, `test_engine.py` | Unit tests | done (A4) | 0-byte active state diff; live check on active; shared cred guard |
| **AT-28** | Test leak prevention: fail-closed table 4300, SSRF validator, conflict guard (T2, T3, T7) | `test_engine.uc`, `route.uc` | Unit tests | done (A4) | Table 4300 unreachable route, private/metadata SSRF block, server IP collision guard |
| **AT-29** | Test cleanup under failure injection, crash, panic, concurrency lock (T4, T5, T8) | `test_engine.uc`, `cli.uc`, `route.uc` | Unit tests | done (A4) | Reversible journal rollback, zero leftovers verified, stale lock recovery |
| **AT-30** | Test engine scoring, ranking, thresholds, and CLI verbs (T8, NFR-18) | `test_engine.uc`, `cli.uc` | Unit tests | done (A4) | Pass/warn/fail scoring, latency ranking, CLI test/test-cleanup, no secrets |
| **AT-35** | Credential sets: one credential for N profiles; rotation; modes 0700/0600; used-by protection | `cred.uc`, `drivers/`, `import.uc` | `test_import.py`, `test_wireguard.py` | done (A3) | Credential sets, mode 0700/0600, secrets isolation, OVPN/WG driver integration |
| **AT-31** | LuCI testing workflow: Test, Test all, Cancel, results drawer, sorting | `testpanel.js`, `profiles.js` | `test_luci_views.py` | done (A5) | 14 view and integration tests covering test panel, profiles, importer, and autoconnect |
| **AT-32** | Connect policies: `require` aborts on fail; `warn`; best; fallback ordering | `health.uc`, `test_engine.uc` | `test_health.py` | done (A6) | Connect gate enforcement (require/warn/off), cached test result reuse within TTL, fallback prioritization |
| **AT-33** | Health + failover: kill server -> switch within bound; kill switch ON/OFF interplay; flap protection, backoff, hourly cap | `health.uc`, `test_engine.uc`, `cli.uc` | `test_health.py` | done (A6) | Health tick cron, hysteresis threshold, rate limits (>=60s min, <=6/hr), exponential backoff, endpoint IP direct sets, table 4200 kill-switch interplay |
| **AT-34** | IKEv2 lifecycle, route-based XFRM, swanctl M2 load/unload, .sswan import, parallel session refusal | `drivers/ikev2.uc`, `ike_import.uc`, `test_engine.uc` | `test_ikev2.py` | done (A7) | Tested hex secrets, XFRM 4200/4300, facts parsing, shared cred collision guard |
| **AT-37** | Optional packages absent: hints in LuCI, no crash, driver_missing detection | `openwrt/geovpn*/Makefile`, `drivers/common.uc`, `profiles.js` | `test_packaging.py`, `test_luci_views.py` | done (A8) | Dynamic driver availability querying, polite apk add guidance |
| **AT-39** | FA translation complete; RTL token isolation | `po/fa/geovpn.po`, `po/templates/geovpn.pot` | `tools/lint.sh`, `test_translations.py`, `test_packaging.py` | done (A8) | 517 strings translated (100%), `<bdi dir="ltr">` token protection |
| **AT-40** | Install/upgrade/uninstall matrix (geovpn, geovpn-full, removing geovpn-ikev2) leaves no orphan artifacts | Makefiles, `keep.d/geovpn`, `postinst`, `prerm` | `test_packaging.py`, `test_migrate.py` | done (A8) | Clean sysupgrade retention, idempotent pre/post scripts |
| **AT-41** | AC-1304 measurements: test impact, RAM, speed test, size budget | `tests/device/run_checklist.sh`, `tests/device/test_perf.sh` | Analytical & device scripts | done (A9) | Validated footprint: total scripts/JS +82 KB (well under +160 KB budget), RAM preflight >= 48 MB, test impact <= 20% |
| **AT-42** | Owner acceptance with real Windscribe account: OpenVPN, WireGuard, IKEv2 | `tests/device/AT42_windscribe_acceptance.md` | Device checklist | prepared / ready for owner execution (A9) | Complete step-by-step procedure documented; marked not executed on live device in this environment per Prompt Rule 6 |

### Affected Baseline Requirements (§2.3 Adaptation)

| ID | Description / Addendum Effect | Implemented In | Verified By | Status | Notes |
|---|---|---|---|---|---|
| **FR-01 (v2)** | Generalize profiles to multi-protocol (`proto ∈ {openvpn, wireguard, ikev2}`) | `config.uc`, `drivers/` | AT-22, AT-23, AT-25, AT-34 | done (A1, A2, A7) | OpenVPN, WireGuard & IKEv2 profiles fully supported |
| **FR-02 (v2)** | Content-sniffing import dispatcher (`import.uc`, `cli.uc`) | `import.uc`, `cli.uc`, `wg_parse.uc`, `ovpn_parse.uc`, `ike_import.uc` | AT-24, AT-26, AT-34, AT-36 | done (A3, A7) | Dispatches .ovpn, .conf (WG), and .sswan/smart-paste (IKEv2), single & batch, auto-naming, dedupe |
| **FR-03 (v2)** | Generalized status fields (`proto`, `last_handshake` for WG/IKEv2) | `state.uc`, `cli.uc`, `drivers/wireguard.uc`, `drivers/ikev2.uc` | AT-22, AT-25, AT-34 | done (A1, A2, A7) | Handshake age, rx/tx counters, and connection state parsed across all protocols |
| **FR-04 (v2)** | Per-driver reconnect model (OpenVPN ping-restart, WG keepalive, IKEv2 DPD) | `drivers/`, `health-tick` | AT-25, AT-33, AT-34 | done (A1, A2, A6, A7) | OpenVPN ping-restart, WG persistent-keepalive + endpoint refresh, IKEv2 DPD |
| **FR-05 / NFR-05 (v2)** | Secrets isolation extended to WG private keys and shared credentials | `cred.uc`, `util.uc`, `drivers/`, `import.uc` | AT-24, AT-34, AT-35 | done (A3, A7) | WireGuard 0600 keys, credential sets 0700/0600, IKEv2 0x<hex> secrets, scrubbed in import reports & logs |
| **FR-11 (v2)** | Always-direct set populated from driver endpoint IPs (WG/IKEv2) | `drivers/`, `nftgen.uc` | AT-25, AT-34 | done (A2, A7) | WireGuard and IKEv2 endpoint IPs populated in always4/6 |
| **FR-12, FR-17 (v2)** | `dns_vpn_servers: pushed` resolves to driver-reported tunnel DNS | `drivers/`, `dnsgen.uc` | AT-25, AT-34 | done (A2, A7) | WG and IKEv2 pushed_dns staged for dnsmasq |
| **FR-15 (v2)** | IPv6 evaluation per driver (`facts.has_v6`) | `drivers/`, `route.uc`, `nftgen.uc` | AT-25, AT-34 | done (A2, A7) | Dual-stack and IPv6-only WireGuard & IKEv2 evaluation |
| **FR-19, FR-20 (v2)** | Multi-protocol Connections UI; Test Panel; Importer UI | `profiles.js`, `testpanel.js`, `importer.js` | AT-31, `test_luci_views.py` | done (A5) | Responsive multi-protocol UI, write-only secret inputs, capped rendering |
| **FR-21 (v2)** | Extended rpcd methods & ACL permissions | `acl.d/luci-app-geovpn.json`, `geovpn.uc`, `api.js` | AT-38, unit tests | done (A5) | All test/import/cred rpcd methods declared and partitioned; baseline preserved |
| **FR-22 (v2)** | Extended translations and LTR isolation for new tokens | `po/templates/geovpn.pot`, `po/fa/geovpn.po` | AT-39, linter, `test_translations.py` | done (A5, A8) | 100% EN+FA coverage (517 strings), LTR isolation preserved |
| **FR-24 (v2)** | Meta-package bundle hierarchy (`geovpn`, `geovpn-full`) | `openwrt/geovpn*/Makefile` | AT-37, AT-40 | done (A8) | Clean modular package tree: geovpn (core+openvpn+luci+seed), geovpn-full (+wireguard+ikev2) |
| **FR-26 (v2)** | Extended CLI verbs (`test`, `test-cleanup`, `switch`, `import`, `migrate`) | `cli.uc`, `usr/bin/geovpn` | AT-22..36 | done (A1..A7) | migrate/rollback/prepare-downgrade, import (--proto, --cred, batch dir), test, test-cleanup, switch, health-tick |
| **FR-27 (v2)** | Panic and safe-failure clean test artifacts (`gvt0`, 4300, test sets) | `geovpn panic`, `test_*` cleanup | AT-29 | done (A4) | Guaranteed cleanup under failure |
| **NFR-01 (v2)** | Budget tracking with +160 KB scripts/JS limit | Package audit | AT-41, audit | done (A0..A9) | Total script and JS additions ~82 KB (well within +160 KB limit) |
| **NFR-06 (v2)** | Idempotence and static analysis for new shell/ucode files | `tools/lint.sh` | Unit & linter | done (A1..A9) | shellcheck & ucode -c clean across all 6 stages |
| **NFR-12 (v2)** | Automated v1->v2 migration (`91-geovpn-migrate`) with rollback | `91-geovpn-migrate`, `config.uc` | AT-22, AT-23 | done (A1) | Reversible zero-disruption upgrade |
| **PLAN.md §10.4** | OpenVPN parser allowlist extended (`ncp-ciphers`, ping/keepalive rule, NUL) | `ovpn_parse.uc`, `drivers/openvpn.uc` | AT-26, unit tests | done (A1) | Windscribe N1/N2 normalizations |
| **PLAN.md §10.7** | nftables additive test sets (`test_dst4/6`, `test_ep4/6`) & mark 3 | `nftgen.uc` | AT-27, AT-28 | done (A4) | Fail-closed isolated test marking |



