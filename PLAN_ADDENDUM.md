# GeoVPN — PLAN_ADDENDUM.md
## Multi-protocol tunnels (OpenVPN + WireGuard + IKEv2), Windscribe-first import, pre-connection testing, auto-connect/failover

**Addendum v1.0 · written 2026-10-07 · baseline: `PLAN.md` v1.0 (GeoVPN, OpenWrt 25.12, Google WiFi AC-1304)**

**Baseline note (read first).** The implemented repository was *not* supplied to the author of this addendum. Everything here is anchored to the **file tree, option names, IDs and designs in `PLAN.md`** (§7 layout, §9 UCI, §10 backend, §11 LuCI). The implementing agent's first task (phase A0) is a *reconciliation pass*: diff the real repository against `PLAN.md`, record every divergence in `DECISIONS.md`, and map each file named below to its real counterpart. Where the repository is the more recent truth, the repository wins and this addendum is adapted, not the other way round.

**Tags** (same as the baseline): **[V]** verified against a source linked in §3.1 on 2026-10-07 · **[R]** recommendation/decision · **[A]** assumption → has a `VA-nn` entry in §3.2. New IDs continue the baseline numbering: `FR-28…`, `NFR-14…`, `C-05…`, `AT-22…`, and addendum-only prefixes `FA-` (facts), `VA-` (verification), `RA-` (risks), `OQA-` (open questions).

---

## 1. Executive Summary & Scope

### 1.1 What changes
1. **Profiles become protocol-agnostic.** A profile has `proto ∈ {openvpn, wireguard, ikev2}`. Every protocol is implemented by a small **driver** that brings up *one network device with a fixed name* (`geovpn0`, unchanged from the baseline) and reports a few facts (local addresses, tunnel DNS, whether IPv6 works, endpoint IPs). The split-tunneling layer (nft table, `ip rule`, table 4200, fw4 zone, dnsmasq, kill switch, IPv6 rules) **does not learn about protocols at all** (FR-28).
2. **WireGuard** (kernel module + `wg`/`ip`, driven directly — not through netifd) and **IKEv2** (strongSwan `swanctl` + a *route-based XFRM interface*, as an **optional package**) join OpenVPN (FR-29…FR-32).
3. **Windscribe Config Generator output is a first-class target** for all three protocols: shared credential sets, normalizations (e.g. `ncp-ciphers`, `ping-exit`), WireGuard `.conf` import, IKEv2 hostname/user/password form with smart paste, batch import (FR-33…FR-35).
4. **Pre-connection testing** (FR-36…FR-44): per-profile probes and a **real isolated tunnel test** on a second device `gvt0` with its own routing table 4300 and its own packet mark, fail-closed, self-expiring, with a journal-based cleanup that runs on every exit path. No network namespaces, no resident daemon.
5. **Auto-connect policies** (best-after-test, connect-only-if-pass, ordered fallback) and **cron-tick health checks with failover** (FR-40, FR-41), explicitly specified against the kill switch and the geo split.
6. **Config migration** v1 → v2 that never touches a working OpenVPN + split setup (FR-45, NFR-15).

### 1.2 What stays the same
Everything in `PLAN.md` §5–§6 and §10.7–§10.10: the `inet geovpn` table and its precedence order, fwmark/mask `0x0f000000` (VPN=1, DIRECT=2), table 4200 / rule priority 700, the fw4 zone `geovpn` with `list device 'geovpn0'`, dnsmasq `nftset` + `server=/d/ip` DNS paths, GeoIP/GeoSite data pack, kill switch semantics, IPv6 handling, the rpcd/ACL/menu structure, the procd/cron/hotplug model. The only nft change is **additive** (test sets + a TEST mark value `3`, §8.3).

### 1.3 Key decisions (detail and justification in the referenced sections)
| ID | Decision | § |
|---|---|---|
| D-A1 | Drivers are **context-parameterized** (`ctx = {kind: active|test, dev, table, mark, rundir}`) so the *same* code brings up the active tunnel (`geovpn0`/4200) and a test tunnel (`gvt0`/4300). | 6.2 |
| D-A2 | WireGuard: depend on `kmod-wireguard` + `wireguard-tools`; **do not** use netifd `proto wireguard` or `luci-proto-wireguard` at runtime; call `ip`/`wg` from the driver. AllowedIPs are programmed into the kernel but **never turned into routes** (equivalent of `route_allowed_ips=0`). | 6.5 |
| D-A3 | IKEv2: strongSwan `swanctl` (vici) + **XFRM interface** (`if_id`), one CHILD_SA, full-tunnel TS; shipped as optional `geovpn-ikev2`, **not** in the default meta-package, because strongSwan packages disappeared from the 25.12 feeds for ~10 days in Aug–Sep 2026 [V: FA-17]. | 6.6, 9 |
| D-A4 | Test isolation = second device + table 4300 + TEST mark + **destination-set marking** (`test_dst4/6`, 90 s element timeout) + `unreachable default` in table 4300 (fail-closed). No `ip netns`. | 7.2 |
| D-A5 | No new resident process: health checks run from a **1-minute cron tick**; test jobs run as detached short-lived runners. | 7.7 |
| D-A6 | No engine swap (sing-box/mihomo rejected): neither supports OpenVPN or IKEv2 [V: FA-22]. | 4.4 |
| D-A7 | **No vendored third-party code.** Upstream projects are used as runtime dependencies (packages) or as design references only. | 4.3 |

### 1.4 Honest limitations up front
- Windscribe **Stealth / WStunnel** are Windscribe-app protocols; the three router config generators do not produce them → **unsupported** (§5.6).
- Windscribe app features (firewall, app split tunneling, auto-rotation) do not exist in router configs; GeoVPN's own kill switch/split replace them.
- **UDP endpoints cannot be probed without completing a handshake** (WireGuard, OpenVPN-UDP with `tls-auth`/`tls-crypt`, IKEv2): their "reachability" is only learned from the real tunnel test (§7.1).
- IKEv2 isolated testing shares the user's single `charon`; it is a **Tier-2** feature with documented restrictions (§7.3.3).
- Windscribe IKEv2 specifics (EAP-MSCHAPv2, CA chain, remote ID) rest on **secondary/old sources** and must be validated with a real account (VA-12…VA-14).

---

## 2. New and Changed Requirements

### 2.1 New functional requirements
| ID | Requirement |
|---|---|
| FR-28 | Protocol-agnostic profile model (`proto` option) and driver interface; split layer unchanged and protocol-blind. |
| FR-29 | WireGuard client driver (single peer, full-tunnel AllowedIPs), integrated with split tunneling, kill switch, DNS, IPv4/IPv6. |
| FR-30 | IKEv2 client driver (EAP-MSCHAPv2 username/password required; certificate/PSK optional), integrated as above; optional package. |
| FR-31 | WireGuard `.conf` import (paste/upload), safe parsing, keys stored as 0600 files; hooks (`PostUp` etc.) rejected. |
| FR-32 | IKEv2 profiles: manual form + smart-paste (hostname/username/password) + optional strongSwan Android `.sswan` import; document that no universal file format exists. |
| FR-33 | Windscribe first-class: auto-detect, normalizations, validation hints, working out-of-the-box imports for OpenVPN, WireGuard, IKEv2; honest limitation notices. |
| FR-34 | Credential sets: one username/password entered once and referenced by many profiles (OpenVPN, IKEv2). |
| FR-35 | Batch import of many files in one action with per-file report, dedupe and name derivation. |
| FR-36 | Test types: endpoint probe (TCP where applicable), real tunnel test (handshake/connect time + URL test latency/jitter/loss), optional throughput estimate; capability matrix per protocol shown in UI. |
| FR-37 | Real tunnel test runs in isolation: never alters the active tunnel, LAN traffic, or routing table 4200; fail-closed; no leak outside the test path. |
| FR-38 | UI: per-profile **Test**, **Test all**, **Test selected**, **Cancel**; progress; per-profile result (status, latency, handshake/connect ms, URL test, timestamp); sort by latency; filter. |
| FR-39 | Configurable pass/fail thresholds and test targets (URLs), with defaults. |
| FR-40 | Connect policies: *manual*, *connect only if test passes* (`connect_gate`), *connect best after test*, *ordered fallback list*. |
| FR-41 | Optional periodic health checks and automatic failover with thresholds, backoff, rate limits and failback; explicit interplay with kill switch and geo split. |
| FR-42 | Test queries carry no identity, use only the intended path, and URLs are validated (no credentials in URL, no private/loopback targets). |
| FR-43 | Resource limits: concurrency, per-test and per-job deadlines, resource preflight, cancellation. |
| FR-44 | Cleanup guarantees: no orphaned process, interface, route, rule, nft element, swanctl connection or file after success, failure, cancel, crash or reboot; `geovpn test-cleanup`. |
| FR-45 | Safe config migration v1→v2 with backup, idempotence and rollback; baseline configs keep working unmodified. |
| FR-46 | CLI parity: `geovpn test [--all|<id>] [--json]`, `geovpn test-cleanup`, `geovpn switch <id>`, `geovpn import <file>` (auto-detect). |

### 2.2 New non-functional requirements and constraints
| ID | Requirement |
|---|---|
| NFR-14 | A test must not raise active-tunnel latency by > 20 % or drop packets on the active path (measured in AT-27). |
| NFR-15 | Backward compatibility: an unmodified baseline `/etc/config/geovpn` works after upgrade with identical behavior; downgrade to baseline is possible for OpenVPN-only setups. |
| NFR-16 | WireGuard and IKEv2 support must be **optional at install time** (`geovpn-wireguard`, `geovpn-ikev2`); the UI degrades with an actionable hint when a driver's dependencies are missing. |
| NFR-17 | Added size: `geovpn-core` + `luci-app-geovpn` ≤ **+160 KB** over the baseline (scripts/JS only); optional packages' dependency sizes are measured and reported (§9.3). |
| NFR-18 | WireGuard private/preshared keys and IKEv2/OpenVPN secrets never appear in UCI, logs, rpc output, process arguments, or world-readable files. |
| NFR-19 | Each driver ≤ 400 lines of ucode and exposes only the interface of §6.2. |
| C-05 | **No resident process** added by this addendum (NFR-02 of the baseline stays valid). |
| C-06 | No code copied from GPL/AGPL projects into an Apache-2.0 codebase (§4.3). |
| C-07 | Test traffic must be fail-closed: if the test tunnel is not up, test-marked packets are rejected by routing (`unreachable`), never forwarded via WAN or the active tunnel. |

### 2.3 Baseline requirements affected
| Baseline ID | Effect |
|---|---|
| FR-01 | "OpenVPN profiles" → profiles of any supported protocol. |
| FR-02 | `.ovpn` import becomes one importer in a content-sniffing import dispatcher. |
| FR-03 | Status fields generalized (`proto`, `last_handshake` for WG/IKEv2). |
| FR-04 | Reconnect model per driver: OpenVPN (`ping-restart` + procd), WireGuard (kernel keepalive + cron-tick endpoint refresh), IKEv2 (charon DPD/`start_action`). |
| FR-05 / NFR-05 | Extended to WG keys and IKEv2 secrets (NFR-18). |
| FR-11 | Always-direct set filled from **driver-reported endpoint IPs** (WG endpoint, IKEv2 host) as well as OpenVPN `remote`. |
| FR-12, FR-17 | `dns_vpn_servers: pushed` token = "driver-reported tunnel DNS" (WG `DNS=`, IKEv2 config payload, OpenVPN push). |
| FR-15 | IPv6 evaluation per driver (`has_v6`). |
| FR-19, FR-20 | Connections tab multi-protocol; Settings gains *Testing* and *Auto-connect* groups. |
| FR-21 | ACL gains the new methods. FR-22: new strings in EN+FA. |
| FR-24 | Meta-package `geovpn` now also pulls `geovpn-wireguard`; `geovpn-full` adds `geovpn-ikev2`. |
| FR-26 | New CLI verbs. FR-27 | Safe-failure also covers test artifacts. |
| NFR-01 | Budget revised (NFR-17). NFR-06 | Applies to new scripts. NFR-12 | Migration v1→v2. |
| `PLAN.md` §10.4 | Allowlist extended (`ncp-ciphers` mapping; NUL rejection; ping/keepalive conflict rule). |
| `PLAN.md` §10.7 | nft: test sets, TEST mark rules (additive). |

---

## 3. Research Findings & Verified Facts

### 3.1 Verified facts (sources)
**Windscribe**
| # | Fact | Tag | Source |
|---|---|---|---|
| FA-01 | Windscribe offers three **router config generators**: OpenVPN, IKEv2, WireGuard; they require a Pro plan or Build-a-Plan (Build-a-Plan limits locations). | [V] | https://windscribe.com/knowledge-base/articles/how-to-use-windscribe-on-a-router-openvpn-and-wireguard · Windscribe features page |
| FA-02 | **OpenVPN generator**: choose location (or Static IP), protocol UDP/TCP, port (443 suggested), OpenVPN version; downloads a `.ovpn`; credentials are **separate "OpenVPN credentials"** (via *Get Credentials*), not the account login, and are the same across the generated profiles. | [V] | same KB article |
| FA-03 | **WireGuard generator**: choose location, port (443 suggested), key pair (new or existing); the downloaded `.conf` carries the **private key, server public key, preshared key, endpoint host:port, AllowedIPs (must be kept complete), interface address(es) (IPv4 and optionally IPv6), DNS**; a router guide recommends MTU 1420 and PersistentKeepalive 25; configs are location-specific; WireGuard is UDP only. DNS is typically **10.255.255.3** (inside the tunnel). | [V] | same KB article · https://windscribe.com/knowledge-base/articles/manual-wireguard-router-setup-guide-dd-wrt |
| FA-04 | **IKEv2 "config"** is only: server **hostname + username + password** (no certificate/key files to download). | [V] | https://windscribe.com/knowledge-base/articles/how-can-i-use-ikev2-on-my-router |
| FA-05 | Community-posted Windscribe `.ovpn` content (2022–2024): `remote <host> <port>`, `verify-x509-name <host> name`, bare `auth-user-pass`, `cipher AES-256-GCM`, `ncp-ciphers AES-256-GCM:AES-256-CBC:AES-128-GCM`, `auth SHA512`, `remote-cert-tls server`, `persist-key`, `key-direction 1` + `<tls-auth>`, `ping 10`, **`ping-exit 60`**, `resolv-retry infinite`, `nobind`, `<ca>`. Server push: `redirect-gateway def1`, `dhcp-option DNS 10.255.255.3`, `topology subnet`, `ping 5`, `ping-restart 60`, `cipher AES-256-GCM`. *Dated sample; current output may differ.* | [V] (secondary) | https://github.com/haugene/docker-transmission-openvpn/issues (Windscribe threads) · Windscribe forum/GitHub posts |
| FA-06 | **Stealth (stunnel) and WStunnel** are Windscribe *app* connection modes; the Windscribe-published `wstunnel` is a proxy forwarding OpenVPN-TCP to a WSTunnel/Stunnel server. The router generators list only OpenVPN/IKEv2/WireGuard. | [V] (features) / [A] (that no stealth config is offered by generators) | https://windscribe.com/features · https://github.com/Windscribe/wstunnel |
| FA-07 | Windscribe's firewall/kill switch and app split tunneling are app features and are not part of router configs; R.O.B.E.R.T. only works through Windscribe DNS inside the tunnel; IPv6 may bypass depending on config. | [V] | router KB article above |
| FA-08 | Windscribe desktop release notes record fixes for **privilege escalation through custom OpenVPN configs** (parser differences, embedded NUL) and for a cached WireGuard config "not cleared when its keys are invalidated" → WG keys *can* be invalidated server-side; strict parsing is justified. | [V] | Windscribe desktop app release notes (windscribe.com changelog) |
| FA-09 | A third-party fetcher notes generator API rate limiting (~20 configs/min). | [V] (secondary) | https://github.com/whizzzkid/windscribe-fetch-config |

**WireGuard on OpenWrt**
| # | Fact | Tag | Source |
|---|---|---|---|
| FA-10 | netifd `proto wireguard` options: interface `private_key, listen_port, addresses, mtu, fwmark, nohostroute, defaultroute, ip4table…`; peer sections `wireguard_<ifname>` with `public_key, preshared_key, allowed_ips, endpoint_host, endpoint_port, persistent_keepalive, route_allowed_ips`. | [V] | https://openwrt.org/docs/guide-user/services/vpn/wireguard/basics (and OpenWrt WireGuard client docs) |
| FA-11 | **`route_allowed_ips` is implemented by OpenWrt's netifd proto script, not by the kernel**; kernel WireGuard routes by AllowedIPs *internally* (cryptokey routing) regardless of OS routes; full-tunnel + `route_allowed_ips=1` interacts with `nohostroute`/endpoint routes and policy routing (openwrt issues/forum). | [V] | https://forum.openwrt.org/ (route_allowed_ips threads) · https://github.com/openwrt/openwrt/issues/22682 |
| FA-12 | `wg(8)`: `wg set <if> private-key <file> peer <pub> preshared-key <file> endpoint <ip:port> allowed-ips <list> persistent-keepalive <s>`; wg-quick keys (`Address`, `DNS`, `MTU`, `Table`, `PreUp/PostUp/PreDown/PostDown`, `SaveConfig`) are **wg-quick extensions** (the PostUp family executes shell commands). | [V] | wg(8) manual · https://github.com/pirate/wireguard-docs |
| FA-13 | `kmod-wireguard` is small (≈37 KB installed on 22.03/5.10 data), `kmod-xfrm-interface` ≈6 KB. | [V] (older release) | OpenWrt package listings (kernel feeds) |

**strongSwan / IKEv2 on OpenWrt**
| # | Fact | Tag | Source |
|---|---|---|---|
| FA-14 | strongSwan **route-based VPN** with XFRM interfaces: `ip link add NAME type xfrm [dev X] if_id N`; swanctl child `if_id_in`/`if_id_out`; by default **no routes are installed for CHILD_SAs with an outbound interface ID**, so the global `charon.install_routes=0` is not needed (option `install_routes_xfrmi` since 5.9.10). | [V] | https://docs.strongswan.org/docs/latest/features/routeBasedVpn.html |
| FA-15 | `kmod-xfrm-interface` is required for XFRM interfaces on OpenWrt (missing module → "Unknown device type"/failed xfrmi creation errors). | [V] | https://github.com/openwrt/openwrt/issues (xfrm interface reports) |
| FA-16 | OpenWrt has a UCI layer for strongSwan swanctl in active development; non-core packages are on a **rolling model** per release series. | [V] | https://forum.openwrt.org/t/strongswan-packages-missing/253131 |
| FA-17 | **strongSwan packages vanished from the 25.12 feeds (incl. `ipq40xx/mikrotik`, the same CPU family as the AC-1304) around 2026-08-26** because strongSwan 6.0.3 failed to build against wolfSSL 5.9.2; fix backported to `openwrt-25.12` and **merged 2026-09-05** (PR #30380); a bump to 6.0.7 for security fixes (PR #30631) was still pending late September. | [V] | https://github.com/openwrt/openwrt/issues/24922 · https://github.com/openwrt/packages/pull/30380 |
| FA-18 | strongSwan Android `.sswan` is a documented JSON profile format (`type: ikev2-eap`, `remote.addr/id`, `local.eap_id`, …); it does not carry the password in a portable way. | [V] | strongSwan documentation: “Android VPN client profiles” (.sswan) — verify exact URL in VA-24 |

**Tooling in OpenWrt**
| # | Fact | Tag | Source |
|---|---|---|---|
| FA-19 | OpenWrt packages these ucode modules: `fs, math, nl80211, resolv, rtnl, struct, ubus, uci, uloop` (Makefile snapshot). A `socket` module exists **upstream in ucode**; whether OpenWrt 25.12 ships it as `ucode-mod-socket` is **not verified**. | [V] / [A] | https://lxr.openwrt.org/source/ucode/Makefile · https://ucode.mein.io |
| FA-20 | sing-box `urltest` semantics used as the *UX/semantic reference* for latency tests: default probe URL `https://www.gstatic.com/generate_204`, interval 3 min, tolerance 50 ms, idle timeout 30 min. | [V] | https://sing-box.sagernet.org/configuration/outbound/urltest/ |

**Existing projects (details in §4)**
| # | Fact | Tag | Source |
|---|---|---|---|
| FA-21 | PassWall2 — **GPL-3.0**, active (release 26.9.16-1), apk feed, uses a `tcping` helper plus curl-based URL tests. OpenClash — **MIT**, active (v0.47.156, 2026-08), apk, mihomo-API delay tests, needs `dnsmasq-full` and heavy deps. HomeProxy — **GPL-2.0**, sing-box front-end (apk fork exists). `luci-app-pbr` — **AGPL-3.0-or-later**. | [V] | https://github.com/Openwrt-Passwall/openwrt-passwall2 · https://github.com/vernesong/OpenClash · https://github.com/immortalwrt/homeproxy · https://github.com/openwrt/packages/tree/master/net/pbr |
| FA-22 | HomeProxy (sing-box) lists WireGuard among supported protocols but **not OpenVPN or IKEv2**; OpenClash (mihomo) lists proxy protocols only (no OpenVPN/IKEv2). | [V] | READMEs above |
| FA-23 | LuCI's `luci-proto-wireguard` offers an **import-settings** feature for pasted WireGuard config (documented in a VPN provider's OpenWrt guide). | [V] | IVPN knowledge-base guide “OpenWrt WireGuard setup” (search: ivpn openwrt wireguard) |

### 3.2 Assumptions & Verification Checklist (close in `DECISIONS.md`)
| ID | What to verify | Where |
|---|---|---|
| VA-01 | The real repository vs `PLAN.md` (file names, option names, function boundaries); produce a mapping table. | A0 |
| VA-02 | Presence/names/versions on `ipq40xx/chromium` 25.12 feeds: `kmod-wireguard`, `wireguard-tools`, `strongswan-charon`, `strongswan-swanctl`, `strongswan-mod-vici`, `-mod-kernel-netlink`, `-mod-socket-default`, `-mod-openssl`, `-mod-eap-mschapv2`, `-mod-eap-identity`, `-mod-md4`, `-mod-des`, `-mod-updown`, `-mod-pem/-x509/-pubkey/-pkcs1`, `kmod-xfrm-interface`, `kmod-ipsec4/6`, `ca-certificates`. Record versions and **installed sizes** (replace §9.3 estimates). | 9 |
| VA-03 | Which strongSwan version is in the 25.12 feed *now* (6.0.3 vs 6.0.7) and whether security advisories apply. | 9, RA-01 |
| VA-04 | `ucode-mod-socket` packaged in 25.12? If not: use fallbacks in §7.4 (uclient-fetch timing; busybox `nc`). | 7 |
| VA-05 | Busybox applets present: `timeout`, `nc`, `su` (not required), `date`, `sleep` with fractions. | 7 |
| VA-06 | WireGuard: handshake starts immediately when a `persistent-keepalive` peer is configured (used for the 100 ms handshake poll); `wg show <if> latest-handshakes` semantics (seconds); `wg set ... private-key <file>` path handling. | 6.5, 7.3 |
| VA-07 | `ip link add gvt0 type wireguard` + moving addresses/routes while a *netifd-managed* `wg0` exists (no interference); `wg` binary exit codes. | 6.5 |
| VA-08 | nft: `meta mark & mask == 0x03000000 accept` and `ip daddr @set meta mark set … accept` in a `type route hook output` chain behave as designed; set element timeouts; `delete element` idempotency. | 8.3 |
| VA-09 | Policy routing: rules at priority 700/701 coexist; `ip rule add fwmark 0x03000000/0x0f000000 lookup 4300`; `ip route … unreachable` fail-closed returns `ENETUNREACH` to the sender (not WAN leak). | 7.2 |
| VA-10 | OpenVPN: `--setenv GV_CTX test:<id>` visible to the `up` hook; `ncp-ciphers` accepted/aliased in 2.7.x; `ping-exit` + pushed `ping-restart` conflict behavior; `keepalive` ⊕ `ping*` exclusivity; running two `openvpn` instances with different `--dev`; `--dev gvt0 --dev-type tun`. | 6.4 |
| VA-11 | OpenVPN second-instance memory/CPU on the AC-1304 (RSS, handshake CPU time). | 7.8 |
| VA-12 | **Windscribe IKEv2** (needs the owner's real account): auth method (EAP-MSCHAPv2), IKE/ESP proposals accepted by strongSwan defaults, remote ID (= hostname?), server certificate issuer/chain and which trust anchors are needed, virtual-IP and DNS delivery (config payload), traffic selectors, behavior with **two simultaneous sessions on the same credentials**. | 6.6, 7.3.3 |
| VA-13 | strongSwan on OpenWrt: init script/service names in 25.12 (`ipsec`/`swanctl`), swanctl config include layout (`conf.d`), `swanctl --load-conns` semantics (does it unload other connections?), `--file` option, how coexistence with a user's own swanctl config is achieved; `charon.install_virtual_ip(_on)` behavior; updown env (`PLUTO_MY_SOURCEIP`, DNS vars). | 6.6 |
| VA-14 | CA trust: whether `ca-bundle` (single file) is unusable by strongSwan and `ca-certificates` (individual PEMs) or shipped roots are needed; exact roots for Windscribe IKEv2 servers. | 6.6 |
| VA-15 | Real Windscribe **WireGuard** config of the owner: exact keys present (`MTU`, `PersistentKeepalive`, IPv6 `Address`, `::/0`, multiple DNS), endpoint host form (hostname vs IP), whether any AmneziaWG-style parameters (`Jc`, `S1`, …) can appear. | 5, 6.5 |
| VA-16 | Real Windscribe **OpenVPN** `.ovpn` of the owner (current): directive list vs allowlist; `tls-auth` vs `tls-crypt`; compression; `verify-x509-name` form; hostname domains. | 5, 6.4 |
| VA-17 | Windscribe concurrent-connection limits for OpenVPN/WireGuard/IKEv2 with shared credentials (affects "test while connected"). | 7.3 |
| VA-18 | `uclient-fetch`: `-T`, `-O /dev/null`, `--no-check-certificate` absence, exit codes, HTTPS to `generate_204` endpoints; HTTP without redirects. | 7.4 |
| VA-19 | ucode `resolv` module API (`query(names, {nameserver:[…], timeout})`) and whether queries honor nft dst-set marking (they do by destination). | 7.4 |
| VA-20 | LuCI JS: multi-file `<input type=file multiple>`, `ui.Table` sorting, progress UI patterns in 25.12 LuCI. | 8.6 |
| VA-21 | `apk` behavior for **optional** packages recommended by `geovpn`/`geovpn-full` (no "recommends" in apk: must be hard deps of the meta-package). | 9 |
| VA-22 | Free RAM thresholds on AC-1304 at idle with baseline running (to calibrate the test preflight: default 48 MB). | 7.8 |
| VA-23 | License texts of the packages we depend on (wireguard-tools GPL-2.0, strongSwan GPL-2.0+, ucode ISC, uclient-fetch ISC…) for the NOTICE file. | 4 |
| VA-24 | `.sswan` field names against the current docs before implementing the importer. | 5 |
| VA-25 | `luci-proto-wireguard` import UI behavior and license (inspiration only; confirm we copy nothing). | 4 |

---

## 4. Existing Open-Source Landscape and Reuse Decision Matrix

### 4.1 Candidates evaluated
Columns: license · maintenance (as of 2026-10) · OpenWrt 25.x/apk · footprint · what could be reused. `[V]` verified (FA-21/22/23), `[A]` not verified (→ VA-23/VA-25).

| Project | What it does | License | Maintenance / 25.x-apk | Footprint | Reusable? |
|---|---|---|---|---|---|
| **wireguard-tools / kmod-wireguard** (OpenWrt feeds) | `wg` CLI; netifd `proto wireguard` script; kernel module | GPL-2.0 [A] | In feeds; 25.12 [V: FA-10/13] | `kmod` ≈ tens of KB [V: FA-13]; tools small [A] | **Yes — runtime dependency** (use `wg` + kernel; skip netifd script) |
| **luci-proto-wireguard** | LuCI protocol UI; has "import settings" for pasted configs [V: FA-23] | Apache-2.0 [A→VA-25] | In luci feed | small JS | **Design reference only** (we need server-side parsing and a multi-protocol UI) |
| **luci-app-openvpn / openvpn-* packages** | Legacy OpenVPN UI; OpenVPN binaries | Apache-2.0 / GPL-2.0 [A] | 25.12: `luci-app-openvpn`, OpenVPN 2.7.x [V: baseline F-14] | n/a | **openvpn-openssl: dependency (baseline)**; LuCI app: not used |
| **strongswan-\* packages** (swanctl, charon, mods) | IKEv2/IPsec daemon, vici, XFRM-interface support | GPL-2.0-or-later [A] | **Feed outage 2026-08-26→09-05; 6.0.3 now, 6.0.7 pending** [V: FA-17] | MBs of mods [A→VA-02] | **Yes — optional runtime dependency** |
| **strongSwan UCI/LuCI integrations** (`luci-app-strongswan-swanctl`, UCI swanctl init) | Config UI for user-managed tunnels | GPL/Apache [A] | Evolving [V: FA-16] | | **No** at runtime (we render our own swanctl fragment; avoids fighting a UI that owns `/etc/swanctl`); coexist-check only |
| **PassWall / PassWall2** | Proxy-core front-end (xray/sing-box…); node list with TCP-ping, URL tests, geo rules | **GPL-3.0** [V: FA-21] | Very active; apk feed [V] | Heavy (cores) | **Design inspiration only** (node-test UX); no copying (GPL-3.0 vs Apache-2.0, C-06). No OpenVPN/IKEv2 |
| **OpenClash** | mihomo front-end; delay tests via the core's API | **MIT** [V] | Active (v0.47.156, 2026-08); apk [V] | Heavy (ruby, curl, core) | **Design inspiration**; code is MIT but tied to mihomo API, nothing to lift |
| **HomeProxy** | sing-box front-end for LuCI (ucode/rpcd style) | **GPL-2.0** [V] | Active; apk fork exists [V] | sing-box core | **Inspiration** for ucode+rpcd+LuCI structure; no copying (GPL-2.0-only vs Apache-2.0) |
| **Nikki** (mihomo-based) | mihomo front-end | [A→VA-23] | Active [A] | Heavy | Inspiration only |
| **sing-box / mihomo cores** | Proxy engines; WireGuard outbound; `urltest` | GPL-3.0 / MIT [A] | In/near feeds [A] | MBs, userspace | **Rejected as engine** (§4.4) |
| **pbr / luci-app-pbr** | Policy-based routing, `dnsmasq.nftset` | **AGPL-3.0-or-later (LuCI app)** [V] | In 25.12 (1.2.x) [V: baseline F-13] | small | **Coexist + warn** (baseline). No code reuse (AGPL) |
| **mwan3 / luci-app-mwan3** | Multi-WAN with `track_ip` health and failover | GPL-2.0 [A] | In feeds [A] | small | **Design reference** for failure thresholds/hysteresis; not a dependency (multi-WAN model mismatch); coexist warning (baseline) |
| **Windscribe/wstunnel** (+ stunnel) | App-side Stealth/WStunnel transports | MIT/GPL [A] | Windscribe-maintained | small Go bin / stunnel | **Rejected for v1** (not produced by router generators, FA-06) |
| **whizzzkid/windscribe-fetch-config**, docker-transmission-openvpn Windscribe scripts | Scripts that download/patch Windscribe configs | [A] | Community | tiny | **Reference for format quirks only**; fetching configs needs account tokens — not adopted (privacy, NFR-18) |
| **Any package that already imports Windscribe configs on OpenWrt** | — | — | **None found**; community guides use `luci-proto-wireguard` import or manual setup [V: FA-23 + forum] | — | n/a → we build the Windscribe-aware importer |
| **uclient-fetch, usign, ucode (+`resolv`, `uci`, `fs`, `uloop`)** | HTTP client, signatures, scripting | ISC/GPL [A] | Core OpenWrt | tiny | **Yes — dependencies** (baseline) |

### 4.2 Reuse Decision Matrix (per component)
Legend: **DEP** depend on upstream package · **VEND** vendor/fork code · **REIMPL** reimplement · **REJ** reject.

| # | Component of this plan | Decision | Upstream | Justification / notes |
|---|---|---|---|---|
| 1 | WireGuard datapath | **DEP** | `kmod-wireguard`, `wireguard-tools` | Kernel WG is the efficient choice on a 716 MHz A7 (userspace WG would be slower); nothing to write. |
| 2 | WireGuard lifecycle (create/configure/teardown) | **REIMPL** (≈120 lines `ip`/`wg`) | — | netifd `proto wireguard` writes `/etc/config/network`, installs routes by AllowedIPs (`route_allowed_ips`, FA-11) and policy rules — all of which conflict with our routing (table 4200, mark-based). Direct `ip`/`wg` keeps one lifecycle model across OpenVPN/WG/IKEv2 and lets the test engine create `gvt0` without touching UCI. |
| 3 | WireGuard `.conf` parser | **REIMPL** | design ref: `luci-proto-wireguard` import | Server-side, hostile-input hardened (PostUp family rejected, NUL, size/line caps). Small. |
| 4 | OpenVPN datapath | **DEP** (baseline) | `openvpn-openssl` | Unchanged. |
| 5 | OpenVPN profile parser/renderer | **REIMPL** (extend baseline) | — | Baseline code; add Windscribe normalizations. |
| 6 | IKEv2 daemon | **DEP (optional pkg)** | `strongswan-*` | Only mainstream IKEv2 client stack on OpenWrt; alternatives not in feeds [A→VA-02]. Optional because of feed instability (FA-17). |
| 7 | IKEv2 config management | **REIMPL** (render swanctl fragment + vici via `swanctl` CLI) | — | UCI/LuCI strongSwan UIs own `/etc/swanctl`; we generate a separate fragment with `if_id` (FA-14). |
| 8 | XFRM interface | **DEP** | `kmod-xfrm-interface` | Required (FA-15). |
| 9 | Test engine core (isolation, jobs, cleanup) | **REIMPL** | — | Nothing upstream tests *VPN profiles* without activating them; proxy-core apps test via their own core's outbound (FA-20/21), which has no OpenVPN/IKEv2. |
| 10 | URL-test semantics (204 URL, samples, tolerance, interval) | **Design reuse** | sing-box `urltest` docs [V: FA-20], PassWall2/OpenClash UX | Concepts only, no code. |
| 11 | TCP connect latency | **REIMPL** | `ucode-mod-socket` if packaged, else busybox `nc` | PassWall2's `tcping` is GPL-3.0 and from a non-official feed → **REJ copying/dependency**. |
| 12 | HTTP(S) fetch for URL/speed tests | **DEP** | `uclient-fetch` (baseline) | Already a dependency. |
| 13 | DNS inside tests | **DEP** | `ucode-mod-resolv` (baseline dep) | Queries steered by destination marking (§7.2). |
| 14 | Health check / failover logic | **REIMPL** | design ref: mwan3 `track` thresholds | mwan3 is multi-WAN; not a dependency. |
| 15 | Policy routing / nft design | **KEEP** (baseline) | pbr coexistence only | AGPL → no code reuse. |
| 16 | Geo data pipeline | **KEEP** (baseline) | — | Unchanged. |
| 17 | Proxy engines (sing-box/mihomo/xray) | **REJ** | — | §4.4. |
| 18 | Windscribe Stealth/WStunnel | **REJ (v1)** | wstunnel/stunnel | FA-06; revisit if Windscribe publishes router stealth configs. |
| 19 | Windscribe config download/API | **REJ** | — | Requires account tokens; privacy risk; user downloads files manually. |
| 20 | QR code import | **Defer** (OQA-06) | possible client-side lib (MIT/Apache) | Optional per brief; if added, vendored with license + NOTICE. |
| 21 | LuCI widgets (tables, forms, modals, file input) | **DEP** | `luci-base` | No extra JS libraries. |

**Attribution/licensing procedure.** (1) Runtime dependencies are listed in `NOTICE` with license names and project URLs (VA-23). (2) Design references are listed under "Acknowledgements" in docs (no code, no obligation). (3) **If** any code is vendored later: only MIT/BSD/ISC/Apache-2.0, in `third_party/<name>/` with the original `LICENSE`, copyright headers preserved, `NOTICE` updated, and a `DECISIONS.md` entry. GPL/AGPL code is never copied while the project is Apache-2.0 (OQ-05 of the baseline; changing the project license is an owner decision, not an implementation detail).

### 4.3 Net effect
Zero vendored code; four new *runtime* dependencies (all optional packages except WireGuard in the default meta-package): `kmod-wireguard`, `wireguard-tools`, and (in `geovpn-ikev2`) `strongswan-*` + `kmod-xfrm-interface`.

### 4.4 Should an existing engine replace the nftables/dnsmasq design?
Evaluated honestly; **no**.
- **Protocol coverage is decisive**: sing-box/mihomo front-ends list WireGuard but not OpenVPN or IKEv2 [V: FA-22]. The owner's primary configs (Windscribe) use all three; an engine swap would *drop two of them* or force running OpenVPN/IKEv2 beside the engine, i.e. two stacks instead of one.
- **Resources**: proxy cores add MBs of binary and substantial RAM/CPU on a 716 MHz A7; userspace WireGuard is slower than the kernel's. The baseline is "no extra daemon".
- **Migration cost**: new routing model (TUN/TPROXY), rule-set format, DNS handling, kill-switch semantics, LuCI rewrite, new data pipeline — essentially the entire baseline.
- **Revisit trigger**: if the owner drops OpenVPN/IKEv2 and needs proxy protocols (VLESS/Trojan…) the proxy-engine route (HomeProxy/PassWall2) becomes the better product — but that is a different product, not this addendum.

---

## 5. Windscribe Config Generator Analysis and Import/UX Design

### 5.1 What the generators produce (facts vs. unknowns)
| Aspect | OpenVPN | WireGuard | IKEv2 |
|---|---|---|---|
| Inputs on the Windscribe page | Location (or Static IP), UDP/TCP, port (443 suggested), OpenVPN version [V FA-02] | Location, port (443 suggested), key pair new/existing [V FA-03] | Location → hostname list [V FA-04] |
| Output | `.ovpn` file with inline `<ca>`, `<tls-auth>`+`key-direction 1` [V (secondary) FA-05] | `.conf`: `[Interface]` PrivateKey/Address(es)/DNS (/MTU?), `[Peer]` PublicKey/PresharedKey/Endpoint/AllowedIPs (/PersistentKeepalive?) [V FA-03; optional keys A→VA-15] | **No file**: hostname + username + password [V FA-04] |
| Auth model | **Separate OpenVPN credentials** (username/password), same for all generated profiles; `auth-user-pass` bare in file [V] | Key-based; **keys embedded**; PSK present [V] | Username/password (EAP) [V: FA-04; EAP-MSCHAPv2 per secondary source, A→VA-12] |
| Crypto/params seen | `cipher AES-256-GCM`, `ncp-ciphers …`, `auth SHA512`, `remote-cert-tls server`, `verify-x509-name … name`, `ping 10`, `ping-exit 60` [V (sec.)] | WG defaults | A→VA-12 |
| DNS | Pushed `dhcp-option DNS 10.255.255.3` [V (sec.)] | `DNS =` typically `10.255.255.3` [V] | Config payload [A] |
| MTU | Not specified (pushed/defaults) [A] | 1420 recommended by Windscribe router guide; a `MTU` line may be present [V/A] | n/a |
| Expiry / rotation | No documented expiry for credentials [A] | **Keys can be invalidated server-side** (FA-08); regenerate; configs are per-location [V] | n/a (credential-based) |
| Endpoint form | Hostnames (various domains) with DNS-rotating IPs [V (sec.)] | Hostname:port [V] | Hostname [V] |
| Router limitations | Windscribe firewall/split/app features absent [V FA-07] | Same; AllowedIPs must stay complete [V] | Same |
| Not offered | Stealth/WStunnel [V/A FA-06] | AmneziaWG-style obfuscation parameters: **unknown** whether the generator can emit them (Windscribe apps mention AmneziaWG, FA-08) → **VA-15** | — |

### 5.2 Import dispatcher (one entry point for all imports) [R]
`import_profile({name?, filename?, content, kind:'auto'|'openvpn'|'wireguard'|'ikev2-form'|'sswan'})`. Content sniffing (first 4 KB, after BOM/CRLF normalization, **NUL ⇒ reject**):
1. contains a line `[Interface]` (case-insensitive) → **WireGuard**;
2. valid JSON object with `"type"` ∈ `ikev2-eap` → **.sswan**;
3. contains `client`/`remote `/`<ca>` lines → **OpenVPN**;
4. matches the *IKEv2 smart-paste* grammar (§5.3.3) → **IKEv2 form** prefill;
5. else: reject with "unrecognized format" (never guess).
All importers share: size cap 128 KB (WG 16 KB, paste-IKEv2 2 KB), line cap 4096, ≤ 64 endpoints, no NUL, no control chars except `\t\r\n`, **allowlist-based**, report `{ignored:[{line,directive,reason}], warnings:[], incomplete:[…]}`, secrets to 0600 files, nothing executed or interpolated into a shell (baseline §10.2, §12).

### 5.3 Per-protocol importers and Windscribe presets
#### 5.3.1 OpenVPN (extends baseline §10.4)
Parser additions: reject NUL; map `ncp-ciphers` → `data-ciphers` (warn "deprecated alias") [A→VA-10]; allow `ping`, `ping-restart`, `ping-exit`, `explicit-exit-notify`, `verify-x509-name … name|subject|name-prefix`, `tls-auth`+`key-direction`, `compress`/`comp-lzo no` (baseline).
**Windscribe normalizations (renderer, applied when the profile carries any of the listed directives — not only for Windscribe):**
| Rule | Why |
|---|---|
| N1 `ping-exit N` → `ping-restart N` | `ping-exit` and `ping-restart`/`keepalive` are mutually exclusive in OpenVPN [A→VA-10]; server pushes `ping-restart 60` (FA-05); procd respawn would work for exit but in-process restart is cleaner. |
| N2 If the profile has any of `ping`, `ping-restart`, `ping-exit`, `keepalive`: **do not emit the default `keepalive 10 60`** (baseline §9.2 default is used only when none is present). | Avoids a startup error for Windscribe configs (`ping 10` + `ping-exit 60`). **This fixes a latent baseline bug** for the primary use case. |
| N3 Bare `auth-user-pass` + no credential set → profile state `needs_credentials` (cannot start; UI prompts). | |
| N4 Provider detection: `verify-x509-name`/`remote` host ends with `.windscribe.com`, or tunnel DNS `10.255.255.3` → `provider='windscribe'` (cosmetic + hints; **no security effect**). | |
| N5 Deduplicate flags (`persist-key`, `nobind`, `resolv-retry`) against renderer-owned ones. | |
Everything else in FA-05 is already in the baseline allowlist. Windscribe pushes `redirect-gateway def1`, which the baseline ignores (`route-nopull` + pull-filter).

#### 5.3.2 WireGuard (new, `wg_parse.uc`)
Grammar: INI with `[Interface]` and exactly **one** `[Peer]` (multiple peers → reject: "single-peer profiles only"); keys case-insensitive; `#`/`;` comments.
| Key | Handling |
|---|---|
| `PrivateKey` | Base64, 44 chars/32 bytes → file `wg.key` (0600); never in UCI/rpc/log. |
| `Address` | comma list of IPv4/IPv6 with prefix → `wg_address` (list). |
| `DNS` | comma list; **IP literals kept** → `wg_dns`; domain/search entries ignored with a note. |
| `MTU` | 1280–1500 → `wg_mtu`; default **1420** [R, FA-03]. |
| `ListenPort`, `FwMark`, `Table`, `SaveConfig` | **Ignored with note** (kernel picks the port; marks/routes are ours). |
| `PreUp/PostUp/PreDown/PostDown` | **Denied with security reason** (FA-12: shell execution). |
| Unknown keys (e.g. AmneziaWG `Jc, Jmin, Jmax, S1, S2, H1…`) | **Reject the import** with explicit message: "obfuscation parameters are not supported by kernel WireGuard" (VA-15). |
| `[Peer] PublicKey` | Base64 32 bytes → `wg_public_key`. |
| `PresharedKey` | → file `wg.psk` (0600), `wg_has_psk=1`. |
| `Endpoint` | `host:port` / `[v6]:port`; host validated as hostname or IP; → `wg_endpoint_host/_port`. |
| `AllowedIPs` | List of CIDRs → `wg_allowed_ips`. **Validation: must cover the default route** (`0.0.0.0/0`, and `::/0` if the profile should carry IPv6) — otherwise error "AllowedIPs doesn't cover 0.0.0.0/0: GeoVPN routes the tunnel as a default route; narrow AllowedIPs would drop traffic" (Windscribe also says to keep AllowedIPs complete, FA-03). Override only via explicit `wg_allow_partial=1` (advanced). |
| `PersistentKeepalive` | 0–600 → `wg_keepalive`; default **25** [R, FA-03]. |
Windscribe detection: endpoint host `.windscribe.com`, DNS `10.255.255.3`. Hints in report: "keys are tied to this location; regenerate the config in your Windscribe account (Config Generators) if the handshake never completes" (FA-08).

#### 5.3.3 IKEv2 (new, `ike_import.uc`)
No standard portable file format exists; the realistic paths are:
1. **Manual form** (always): Name, Hostname, Credential set (or username+password), Remote ID (default = hostname), advanced.
2. **Smart paste** (Windscribe-oriented): accepts `Hostname: … / Username: … / Password: …` blocks (labels `host|hostname|server|address`, `user|username|login`, `pass|password`, case-insensitive, `:`/`=`/tab separated) or three lines in that order; anything ambiguous → pre-fills the form for manual confirmation. Password is moved to the credential store immediately and never echoed.
3. **strongSwan Android `.sswan`** (optional): `type=ikev2-eap` → `remote.addr`, `remote.id`, `local.eap_id`; password absent → prompt (FA-18, VA-24).
4. *Not supported:* Apple `.mobileconfig`, Windows PowerShell/VPN profiles, raw `swanctl.conf`/`ipsec.conf` (maybe later; OQA).
Windscribe preset: `provider='windscribe'`, EAP-MSCHAPv2, remote id = hostname, system CA trust, TS `0.0.0.0/0,::/0` — all **[A→VA-12]**; the UI labels IKEv2 as "experimental" until validated against a real account.

### 5.4 Credential sets [R] (FR-34)
`config credential 'c_xxxxxxxx'` (`name`, `kind='userpass'`, `has_secret`), secret in `/etc/geovpn/credentials/<id>/auth` (dir 0700, file 0600: line 1 user, line 2 password). Profiles reference `option cred 'c_…'`. The OpenVPN driver passes `auth-user-pass <path>` as before; the IKEv2 driver reads user/secret at render time. **Windscribe flow:** enter *OpenVPN credentials* once → "Use for all OpenVPN profiles from this provider" (default checked). Baseline per-profile `auth` files keep working (migration leaves them; new imports prefer credential sets). Rotating a password updates one file.

### 5.5 Batch import and naming (FR-35)
`<input type=file multiple>`; the browser sends files **one rpc per file** (≤128 KB each) with a progress list. Name: from `filename` (strip extension, `_`/`-` → space; e.g. `Windscribe-Dallas-Trinity.conf` → "Windscribe Dallas Trinity"); duplicates detected by hash of `(proto, endpoint host, port, public_key|ca-hash)` → "already imported — skip / replace / keep both". Default `group` from provider. A 30-file import must complete without blocking the UI (≈ per-file parse < 50 ms expected [A]).

### 5.6 Limitations to state in the UI and README
1. Stealth/WStunnel and any Windscribe *app-only* feature: unsupported.
2. Windscribe plan required (Pro / Build-a-Plan).
3. WG configs are location-specific and keys can be invalidated; GeoVPN cannot regenerate them (no API use by design).
4. UDP-only WG: networks that block UDP can't use it; choose OpenVPN-TCP/443.
5. IKEv2 is experimental until VA-12 passes; depends on strongSwan packaging health (FA-17).
6. R.O.B.E.R.T./Windscribe DNS applies only to domains that follow the VPN DNS path; domains routed **direct** use the direct DNS (design consequence of "DNS follows the route").
7. IPv6: honored per tunnel capability; otherwise blocked (baseline §5.7).

### 5.7 User flow (target UX)
`Import (drop/select 1…N files or paste) → report (per file: ✔ proto, endpoint, ⚠ ignored directives) → enter credentials once (if asked) → [Test all] → table sorted by latency with ✔/✘ → [Connect best] (or per-row Connect) → existing split tunneling applies unchanged.`
```
┌ Import profiles ───────────────────────────────────────────────┐
│ [ Choose files… ] or paste text:  ┌──────────────────────────┐  │
│                                   │ [Interface] PrivateKey=… │  │
│ Files: ✔ ws-dallas.conf   WireGuard  Windscribe  443/udp      │
│        ✔ ws-paris.ovpn    OpenVPN    Windscribe  443/udp  ⚠1  │
│        ✘ foo.conf  “PostUp not allowed” (security)            │
│ OpenVPN credentials needed: [user] [pass] ☑ use for all       │
│                              [ Import ] [ Import & Test all ] │
└─────────────────────────────────────────────────────────────────┘
```

### 5.8 Reference fixtures (synthetic; **no real keys**; to be replaced by owner-provided redacted samples, VA-15/16)
```
# OpenVPN (shape per FA-05)                       # WireGuard (shape per FA-03)
client                                             [Interface]
dev tun                                            PrivateKey = <base64-32B>
proto udp                                          Address = 100.64.12.34/32
remote host.example 443                            DNS = 10.255.255.3
resolv-retry infinite                              MTU = 1420
nobind                                             [Peer]
persist-key                                        PublicKey = <base64-32B>
cipher AES-256-GCM                                 PresharedKey = <base64-32B>
ncp-ciphers AES-256-GCM:AES-256-CBC:AES-128-GCM    AllowedIPs = 0.0.0.0/0
auth SHA512                                        Endpoint = host.example:443
remote-cert-tls server                             PersistentKeepalive = 25
verify-x509-name host.example name
auth-user-pass
ping 10
ping-exit 60
key-direction 1
<ca> … </ca>  <tls-auth> … </tls-auth>
```

---

## 6. Protocol Layer Design

### 6.1 Unified tunnel-profile model (UCI, `config profile`)
The baseline `config profile '<pXXXXXXXX>'` is **extended, not replaced**. A missing `proto` means `openvpn` (so every baseline config is already valid, NFR-15).

Common options (all protocols):
| Option | Type | Default | Meaning |
|---|---|---|---|
| `proto` | enum | `openvpn` | `openvpn` · `wireguard` · `ikev2` |
| `name`, `enabled` | | | baseline |
| `provider` | enum | `''` | `''` · `windscribe` · `generic` — label + UI hints only, **no security effect** |
| `group` | string | `''` | UI grouping (≤ 32 chars, display-escaped) |
| `cred` | id | `''` | credential set (`c_xxxxxxxx`) for openvpn/ikev2 |
| `auto_pool` | bool | `1` | eligible for "best" auto-connect and failover |
| `test_url` | url | `''` | optional per-profile override of test targets |
| `source_sha256`, `imported_at` | | | baseline |

OpenVPN options: **unchanged** (`remote`, `tls_kind`, `cipher`, … §9.2 of the baseline).

WireGuard options (new):
| Option | Type | Default | Validation |
|---|---|---|---|
| `wg_endpoint_host` | string | — | hostname (`^[A-Za-z0-9.-]{1,253}$`) or IP literal |
| `wg_endpoint_port` | uint | — | 1–65535 |
| `wg_public_key` | string | — | base64, 44 chars, 32 bytes |
| `wg_address` | list | — | IPv4/IPv6 with prefix; ≥ 1 |
| `wg_dns` | list | — | IP literals only |
| `wg_allowed_ips` | list | `0.0.0.0/0` (+`::/0`) | CIDRs; must cover the default route unless `wg_allow_partial=1` |
| `wg_mtu` | uint | `1420` | 1280–1500 |
| `wg_keepalive` | uint | `25` | 0–600 |
| `wg_has_psk` | bool | derived | PSK file present |
| `wg_allow_partial` | bool | `0` | advanced |
Secrets: `/etc/geovpn/profiles/<id>/wg.key`, `wg.psk` (0600). **No key material in UCI.**

IKEv2 options (new):
| Option | Type | Default | Validation |
|---|---|---|---|
| `ike_host` | string | — | hostname/IP literal |
| `ike_remote_id` | string | = host | `^[A-Za-z0-9@._:-]{1,128}$` |
| `ike_auth` | enum | `eap-mschapv2` | `eap-mschapv2` (v1); `psk`/`pubkey` reserved |
| `ike_ca` | enum | `system` | `system` (shipped roots) · `file` (uploaded `ca.pem`) |
| `ike_proposals`, `ike_esp` | string | `default` | strongSwan proposal grammar `^[A-Za-z0-9_-]+(-[A-Za-z0-9_]+)*(,…)*$`, ≤ 200 chars |
| `ike_dpd` | uint | `30` | 5–300 s |
| `ike_fragmentation` | bool | `1` | |
| `ike_mobike` | bool | `0` | off by default on a fixed-WAN router [R] |
| `ike_if_id` | uint | `4242` | 1–2³²−1, `ike_if_id_test` = `4243` |

### 6.2 Driver interface (ucode) [R]
Directory `usr/share/ucode/geovpn/drivers/{openvpn,wireguard,ikev2}.uc` plus `drivers/common.uc` (context, journal, shell-free exec). Drivers are **pure functions of `(ctx, profile, cfg)`**; they never touch nft, fw4, dnsmasq or the global state — the core does that from the driver's reported facts.
```js
// ctx  = { kind:'active'|'test', id:'<profile id>', dev:'geovpn0'|'gvt0', table:4200|4300,
//          rundir:'/var/run/geovpn' | '/var/run/geovpn/test/<jid>', ifid:4242|4243,
//          unit:'geovpn'|'geovpn-test', deadline:<epoch ms or null> }
export const proto;                       // 'openvpn' | 'wireguard' | 'ikev2'
export function available() {}            // → { ok, missing:[pkgnames], note }
export function validate(profile, cfg) {} // → { errors:[], warnings:[] }   (pure; also used by importers)
export function endpoints(profile) {}     // → [{ host, port, transport:'udp'|'tcp', ips:[…] }]  (resolution via system DNS)
export function prepare(ctx, profile, cfg) {} // render files under ctx.rundir → { ok, err }
export function start(ctx) {}             // create ctx.dev; → { ok, err, async:bool }
export function facts(ctx) {}             // → { up, dev, v4:[], v6:[], dns:[], has_v6, mtu, since, endpoint_ip,
                                          //     rx, tx, last_handshake, state:'connecting'|'connected'|'stale'|'down' }
export function refresh(ctx) {}           // re-resolve endpoint, nudge; called by WAN hotplug and health tick
export function stop(ctx) {}              // orderly shutdown
export function cleanup(ctx) {}           // idempotent: remove EVERY artifact for ctx (links, procs, conns, files)
```
`start()` may be asynchronous (OpenVPN, IKEv2); readiness is signalled by `facts().up` (polled) or by the hook (OpenVPN/IKEv2 updown). All external commands go through `common.exec(argv[])` (argv arrays only, timeouts mandatory, stdout/stderr size-capped, secrets never in argv).

### 6.3 How split tunneling attaches to any protocol (the whole contract)
The core function `core.tunnel_up(ctx, facts)` is the **only** consumer of driver facts and does exactly what baseline `_hook up` did (§10.5 of the baseline):
1. `ip -4 route replace default dev <ctx.dev> table <ctx.table> metric 10` (and v6 if `facts.has_v6` and `ipv6∈{auto,vpn}`);
2. `net.ipv4.conf.<dev>.rp_filter=2`;
3. *(active only)* tunnel DNS → `dns_vpn` sets/dnsmasq when `dns_vpn_servers` contains `pushed` (source: `facts.dns`);
4. *(active only)* always-direct set ← `endpoints(profile)[*].ips`; dnsmasq `server=/<host>/<direct DNS>` + `nftset` for hostnames (baseline §10.10);
5. *(active only)* write `state.json` with `proto`, `since`, addresses, counters.
`core.tunnel_down(ctx)` removes the default route(s) (the `unreachable` entry stays when the kill switch is on).
**Everything downstream** — classifier, `ip rule … lookup 4200`, `guard`, fw4 zone with `list device 'geovpn0'`, masquerade, MSS clamp, dnsmasq — **depends only on the device name `geovpn0`, table 4200 and the mark**, all protocol-independent. This is why the split layer needs **no change** (FR-28).

### 6.4 OpenVPN driver (changes to the baseline)
| Change | Detail |
|---|---|
| Extract | Move rendering/launch code from `ovpn_render.uc`/init into `drivers/openvpn.uc` (keep a thin `ovpn_render.uc` shim for one release). |
| Context | Render `dev <ctx.dev>`, `setenv GV_CTX <kind>:<id>` (renderer-controlled; **never** from user files), `syslog geovpn` or `geovpn-test`. |
| Hook | `ovpn-hook` whitelists `GV_CTX` and passes it to `geovpn _hook`; the hook resolves `rundir/table/dev` from the context (test context writes only under its `rundir`, installs the route in table 4300, **does not** touch dnsmasq, fw4 or `state.json`). |
| Keepalive rule | N1/N2 of §5.3.1 (no default `keepalive` when the profile has any ping option; `ping-exit` → `ping-restart`). |
| Credentials | `auth-user-pass <cred path>` from the credential set (fallback: per-profile `auth`). `needs_credentials` state if missing. |
| Supervision | Active: procd instance as in baseline. Test: procd instance of `geovpn-test` wrapped with busybox `timeout` (§7.3.1). |
| Allowlist | + `ncp-ciphers` mapping; NUL rejection; everything else baseline. |

### 6.5 WireGuard driver
**Why direct `ip`/`wg` instead of netifd (D-A2).** netifd's `proto wireguard` creates `network` UCI sections, installs routes from AllowedIPs when `route_allowed_ips=1`, and (with full-tunnel AllowedIPs) places a default route in the **main** table — which would pull all *direct* traffic into the tunnel and fight our table-4200 design (FA-10/FA-11). Setting `route_allowed_ips=0` solves routes but still leaves a UCI/netifd lifecycle that the test engine cannot reuse (it would have to write temporary UCI). Calling the kernel API through `ip`/`wg` is ~120 lines, identical for active and test contexts, and needs no UCI writes.

**How AllowedIPs and routes interact (explicit design rules):**
1. AllowedIPs are programmed into the kernel peer (`wg set … allowed-ips`) because WireGuard's *cryptokey routing* needs them: a packet routed into the device is encrypted only if its destination matches a peer's AllowedIPs, otherwise dropped (FA-11).
2. **No OS routes are derived from AllowedIPs** (equivalent to `route_allowed_ips=0`). The only routes are `default dev <dev>` in table 4200 (active) or 4300 (test).
3. Because the tunnel is used as a default route, AllowedIPs **must cover** `0.0.0.0/0` (and `::/0` for IPv6) — validated at import and at start (§5.3.2).
4. **Routing-loop avoidance:** the encrypted UDP packets are generated by the kernel with destination = endpoint IP and are *not marked*; they follow the main table (WAN). In `router_traffic=policy` the endpoint IP is in the always-direct sets (core step 4). No `fwmark` is configured on the WG socket (not needed because no rule matches unmarked packets; setting one would risk colliding with other tools).
5. **Endpoint DNS:** hostname resolved through the system resolver on the *direct* path (baseline `server=/<host>/<direct DNS>` rule) before `wg set … endpoint <ip>:<port>`; re-resolved on WAN `ifup` and by the health tick when the handshake is stale.
6. WG private key read by the kernel tool from the 0600 file (`private-key <file>`), PSK likewise; nothing secret in argv (FA-12).

Reference commands (verify: VA-06/07):
```sh
ip link add dev geovpn0 type wireguard
wg set geovpn0 private-key /etc/geovpn/profiles/p1/wg.key \
   peer <PUBKEY> preshared-key /etc/geovpn/profiles/p1/wg.psk \
   endpoint 203.0.113.7:443 allowed-ips 0.0.0.0/0,::/0 persistent-keepalive 25
ip address add 100.64.12.34/32 dev geovpn0
ip link set dev geovpn0 mtu 1420 up
# → core.tunnel_up(): ip route replace default dev geovpn0 table 4200 metric 10 ; rp_filter=2
```
**State derivation:** `wg show <dev> dump` → latest handshake epoch, rx/tx. `connecting` until first handshake; `connected` while handshake age ≤ 180 s; `stale` beyond (health tick may `refresh()`); `down` if the device is missing.
**Reconnect model:** kernel keepalive + rekey; `refresh()` re-resolves the endpoint and `wg set … endpoint` on change; device loss ⇒ `start()` again via the health tick/WAN event.
**Stop/cleanup:** `ip link del dev geovpn0` (routes in table 4200 vanish with the device).
**IPv6:** `has_v6 = wg_address has v6 && AllowedIPs has ::/0`; else baseline v6 block applies.
**Windscribe specifics:** DNS `10.255.255.3` is only reachable inside the tunnel → use token `pushed` (default for such profiles); MTU 1420/keepalive 25 defaults; hint on handshake failure about invalidated keys (FA-08).

### 6.6 IKEv2 driver (optional package `geovpn-ikev2`)
**Implementation choice [R]: strongSwan with `swanctl` (vici) and a route-based XFRM interface.** Justification: it is the only IKEv2 client stack maintained in OpenWrt feeds [A→VA-02]; route-based XFRM interfaces (FA-14) turn the IPsec SA into a normal device `geovpn0`, which is exactly what the split layer needs; with `if_id_out` set, strongSwan installs **no routes** for the CHILD_SA by default (FA-14), so our policy routing is not fought and the global `charon.install_routes=0` is unnecessary (other IPsec users unaffected).
**Authentication methods supported:** EAP-MSCHAPv2 (username/password — Windscribe's model, FA-04) in v1; certificate and PSK are *reserved* option values (strongSwan supports them; not exposed in v1 UI to keep the surface small). **Traffic selectors:** `remote_ts = 0.0.0.0/0, ::/0`, `local_ts` dynamic (virtual IP assigned by the server via config payload); because packets must carry the **virtual IP as source** to match the XFRM policy, the zone masquerade (baseline fw4 zone `masq=1`) rewrites the source to the address on the xfrm device — the VIP must therefore be installed on `geovpn0` (updown script below).
**Footprint on AC-1304:** to be measured (VA-02); strongSwan + EAP/MSCHAPv2/crypto plugins is the heaviest optional component of this addendum (§9.3).

Reference render (verify every key against the swanctl.conf docs: VA-13):
```
connections {
  gv_p1 {
    version = 2
    remote_addrs = ikev2-host.example.net
    vips = 0.0.0.0, ::
    dpd_delay = 30s
    fragmentation = yes
    mobike = no
    local  { auth = eap-mschapv2 ; eap_id = <username> }
    remote { auth = pubkey ; id = ikev2-host.example.net ; cacerts = geovpn-isrg-x1.pem }
    children {
      gv_p1 {
        remote_ts = 0.0.0.0/0, ::/0
        if_id_in = 4242
        if_id_out = 4242
        start_action = none
        dpd_action = restart
        updown = /usr/libexec/geovpn/ike-updown
      }
    }
  }
}
secrets { eap-gv_p1 { id = <username> ; secret = 0x<hex of password> } }   # hex form avoids quoting/injection (VA-13)
```
**Lifecycle:**
1. `prepare`: render the fragment (0600) + stage CA PEMs (`/usr/share/geovpn/ca/*.pem` shipped: ISRG Root X1/X2 [A→VA-14] + optional user CA).
2. `start`: `ip link add geovpn0 type xfrm if_id 4242` → load our fragment into charon → `swanctl --initiate --child gv_p1 --timeout <s>`.
3. `ike-updown` (per-CHILD hook; whitelisted env, same validation as `ovpn-hook`): on `up-client` assign the VIP(s) to `geovpn0`, record DNS from the configuration payload, then `geovpn _hook up --ctx …` → `core.tunnel_up`.
4. `facts`: `swanctl --list-sas` (parsed) → state `connected` when the IKE_SA and CHILD_SA are ESTABLISHED/INSTALLED.
5. `stop`: `swanctl --terminate --ike gv_p1` → unload our connection → `ip link del geovpn0`.
6. Reconnect: `dpd_action=restart` + `close_action=restart`, charon owns retries; health tick verifies.
**Loading method (must be decided empirically in phase A7, VA-13):** the method has to (a) leave every connection/SA not named `gv_*` untouched and (b) keep the *active* `gv_*` SA when a *test* connection is added/removed. Ranked candidates: **M1** speak vici directly (`load-conn`/`unload-conn` per connection) from ucode — most precise, needs a socket module (VA-04); **M2** keep one combined drop-in fragment containing the active + test connections and load with `swanctl --load-conns` (re-loading unchanged connections keeps their SAs [A]); **M3** (rejected) a second `charon` instance: UDP 500/4500 conflict.
**Coexistence rules:** GeoVPN manages only `gv_*` connections and `if_id` 4242/4243 (configurable); preflight lists existing connections and refuses on `if_id` collisions; the init/uninstall paths never stop a `charon` that GeoVPN did not start (flag `we_started_charon`).
**Risks:** strongSwan packaging instability (FA-17) → package kept optional, `available()` check, UI banner; Windscribe parameters unverified (VA-12) → "experimental"; EAP-MSCHAPv2 needs `md4`/`des`/`eap-mschapv2` plugins which were **not** in the sample `strongswan-default` set (VA-02) → listed as explicit dependencies (§9.2).

### 6.7 IPv6 and kill-switch matrix (all inherited from baseline §5.7/5.8)
| | OpenVPN | WireGuard | IKEv2 |
|---|---|---|---|
| `has_v6` source | `ifconfig_ipv6_local` | v6 `Address` ∧ `::/0` ∈ AllowedIPs | v6 VIP ∧ TS `::/0` |
| v6 without tunnel support | v6 table `unreachable` + guard | same | same |
| Kill switch (`unreachable default` in table 4200 + guard) | unchanged | unchanged (`ip link del` removes the default route; the `unreachable` entry persists) | unchanged |
| Transport itself (loop prevention) | server IPs ∈ always-direct | endpoint IP ∈ always-direct | host IPs ∈ always-direct |
| Tunnel DNS for `pushed` | push `dhcp-option DNS` | `DNS =` | config payload |

### 6.8 Minimal changes to baseline code
| File (baseline §7) | Change |
|---|---|
| `config.uc` | Validators for new options/sections (`proto`, `wg_*`, `ike_*`, `credential`, `test`, `autoconnect`); `proto` default `openvpn`. |
| `ovpn_parse.uc` / `ovpn_render.uc` | §6.4 changes; render moved to `drivers/openvpn.uc`. |
| **new** `drivers/{common,openvpn,wireguard,ikev2}.uc`, `wg_parse.uc`, `ike_import.uc`, `import.uc` (dispatcher), `cred.uc` | §5–§6. |
| `state.uc` | `proto`, `last_handshake`, per-driver fields. |
| `nftgen.uc` | Additive: test sets, TEST rules (§8.3). |
| `route.uc` | Test table/rule helpers (`test_route_up/down`), `panic` also cleans test artifacts. |
| `/etc/init.d/geovpn` | `start_service` dispatches on `proto`; WG/IKEv2 are "oneshot" instances + `facts` polling; new `switch` command. |
| `ovpn-hook` | whitelist `GV_CTX`; generic `geovpn _hook --ctx`. |
| **new** `/etc/init.d/geovpn-test`, `usr/libexec/geovpn/ike-updown`, `geovpn-health` (cron tick) | §7. |
| `geovpn.uc` (rpcd) | New methods (§8.2); `import_ovpn` kept as alias of `import_profile`. |
| `diag.uc` | Driver `available()` checks, strongSwan/WireGuard warnings, orphan scan. |
| LuCI `profiles.js` | Rewritten multi-protocol; new `testpanel.js`, `importer.js`, `autoconnect.js` modules. |
| `settings.js` | + *Testing*, *Auto-connect* groups. |
| `luci-app-geovpn.json` (ACL/menu) | + methods. |
Nothing in `nftgen` precedence, `dnsgen`, `fwzone`, `data.uc` and the data pack changes.

---

## 7. Test-Engine Design

### 7.1 What can be tested without switching the active connection (capability matrix)
| Test | OpenVPN-TCP | OpenVPN-UDP | WireGuard | IKEv2 |
|---|---|---|---|---|
| **P1 Endpoint TCP probe** (connect latency to host:port) | ✔ meaningful | ✘ (UDP) | ✘ | ✘ |
| **P2 UDP probe** | ✘ — OpenVPN servers with `tls-auth`/`tls-crypt` silently drop packets lacking a valid HMAC, so a probe gets no answer (**no safe probe without the key; do not pretend**) | ✘ — WireGuard ignores unauthenticated packets | ✔ *stretch*: crafted IKE_SA_INIT (RFC 7296) — server answers unauthenticated; gives RTT/reachability (phase A7+, optional) |
| **R Real tunnel test** in isolation (handshake/connect time + URL test samples) | ✔ | ✔ | ✔ (**cheapest/best**: handshake ≈ 1 RTT) | ✔ **Tier-2** (shared `charon`; see 7.3.3) |
| **S Throughput estimate** (bounded download through the test tunnel) | ✔ | ✔ | ✔ | ✔ |
| **L Live check** of the *active* profile (no second tunnel; passes through the live tunnel) | ✔ | ✔ | ✔ | ✔ |
Rule: **the active profile is never "really tested" with a second tunnel** — it gets the *live check* (handshake age/counters + URL samples marked into table 4200). A real test of a profile that shares credentials with the active one is **refused** for IKEv2 and warned for OpenVPN/WG until VA-17 shows parallel sessions are allowed (otherwise the server may drop the active session).
If safe isolation is impossible (IKEv2 with no acceptable loading method, VA-13): fall back to *P2 probe only* and mark results "probe-only".

### 7.2 Isolation mechanism (D-A4)
```
 active path (unchanged)                          test path (new, only while a test runs)
 LAN ─► nft pre (mark VPN=1/DIRECT=2) ─► rule 700 ─► table 4200 ─► geovpn0
 router DNS ─► nft out (dns_vpn) ───────► rule 700 ─► table 4200 ─► geovpn0
 test client (uclient-fetch/ucode) ─► nft out: (daddr . dport) ∈ test_dst ─► mark TEST=3 ─► rule 701 ─► table 4300 ─► gvt0
                                                        table 4300 = { unreachable default (always, first) ; default dev gvt0 (when up) }
 test tunnel's own outer packets (UDP/TCP to endpoint) are UNMARKED → main table → WAN ; endpoint ∈ test_ep → direct even under router_traffic=policy
```
Why this works without namespaces: (i) *separate device* (`gvt0`), (ii) *separate table and mark*, (iii) marking by **destination (ip . port) sets with a 90 s element timeout**, so even a crashed runner cannot leave test routing active for longer than 90 s, (iv) **fail-closed**: the `unreachable default` route exists from the very first step, so a test packet can never fall through to WAN or `geovpn0`, (v) a **guard** chain drops any TEST-marked output not leaving via `gvt0`. `ip netns` is rejected: it needs veth plumbing, extra fw4 zone/forwarding and NAT for the underlay, and OpenVPN's `tun` cannot be moved into a namespace the way WireGuard can.

Reference additions to the baseline ruleset (§10.7) — **additive** (verify VA-08/09):
```nft
  set test_dst4 { type ipv4_addr . inet_service; flags timeout; timeout 90s; size 256; }   # targets + test DNS (port 53/80/443)
  set test_dst6 { type ipv6_addr . inet_service; flags timeout; timeout 90s; size 256; }
  set test_ep4  { type ipv4_addr; flags timeout; timeout 90s; size 64; }                    # test tunnel endpoints → must stay direct
  set test_ep6  { type ipv6_addr; flags timeout; timeout 90s; size 64; }
  chain out {                                   # TEST rules FIRST, terminal, so no later rule can re-mark them
    meta l4proto { tcp, udp } ip  daddr . th dport @test_dst4 meta mark set meta mark & 0xf0ffffff | 0x03000000 accept
    meta l4proto { tcp, udp } ip6 daddr . th dport @test_dst6 meta mark set meta mark & 0xf0ffffff | 0x03000000 accept
    meta mark & 0x0f000000 == 0x03000000 accept
    # … existing dns_vpn4/6 and fetch_vpn4/6 rules unchanged …
  }
  chain test_guard {
    type filter hook output priority filter - 1; policy accept;
    meta mark & 0x0f000000 == 0x03000000 oifname != "gvt0" drop
  }
  # in chain classify (router_traffic=policy) add right after the 'ct direction reply' rule:
  #   ip daddr @test_ep4 jump set_direct ; ip6 daddr @test_ep6 jump set_direct
```
Routing (reference):
```sh
ip -4 rule add priority 701 fwmark 0x03000000/0x0f000000 lookup 4300 ; ip -6 rule add … (same)
ip -4 route replace unreachable default table 4300 metric 4000       ; ip -6 route replace unreachable default table 4300 metric 4000
# when gvt0 is up (core.tunnel_up with ctx.kind=test):
ip -4 route replace default dev gvt0 table 4300 metric 10
```
**Conflict guard:** before adding an `(ip, port)` to `test_dst`, the engine rejects it if the IP is in `always*`, `dns_vpn*`, `fetch_vpn*`, `private*`, any LAN subnet, or equals the active endpoint (prevents the test from stealing the router's DNS/updates or looping). Defaults avoid `1.1.1.1/9.9.9.9`.

### 7.3 Per-protocol test procedure
Common envelope (`test_run(profile)`): `lock → preflight (RAM/load/driver available/credentials present) → journal start → [mark endpoints test_ep] → table 4300 + unreachable → driver.prepare/start(ctx=test) → wait ready (≤ test_timeout) → measure → driver.stop/cleanup → journal done`. Every step appends to the journal **before** acting (§7.9).

#### 7.3.1 OpenVPN
Render config with `dev gvt0`, `route-nopull`, `setenv GV_CTX test:<jid>:<id>`, `connect-timeout`, `connect-retry-max 1`, `syslog geovpn-test`. Launch **through `/etc/init.d/geovpn-test`** (procd instance, command prefixed with busybox `timeout <T+5>` [A→VA-05]) so a single `stop` path exists. The test `up` hook records `up_ts` and installs the default route in table 4300. Measure: `connect_ms = up_ts − spawn_ts`. Memory/CPU cap: one real test at a time (VA-11).
#### 7.3.2 WireGuard
Steps as §6.5 with `dev=gvt0`, **key files read in place**, `persistent-keepalive` set (triggers an immediate handshake attempt [A→VA-06]). Poll `wg show gvt0 dump` every 100 ms until a non-zero latest-handshake → `handshake_ms`. If none within `test_timeout`: result `no_handshake` with the hint "UDP blocked, wrong endpoint, or key invalidated (Windscribe: regenerate)". Teardown = `ip link del gvt0`.
#### 7.3.3 IKEv2 (Tier-2)
Requires the §6.6 loading method (VA-13). Steps: `ip link add gvt0 type xfrm if_id 4243` → load connection `gv_t_<jid>` (distinct name/if_id; `updown` with test context) → `swanctl --initiate --child gv_t_<jid> --timeout <T>` (blocking; duration = `connect_ms`) → measure → `swanctl --terminate` → unload → `ip link del`. **Restrictions:** refuse while an IKEv2 SA with the *same credentials* is active (server may supersede it, VA-12/17); `charon` not running ⇒ the test starts it and stops it afterwards (`we_started_charon`); packaging absent ⇒ test row shows "IKEv2 support not installed".

### 7.4 Measurements
Per profile: `probe_ms` (P1 when applicable), `handshake_ms` (WG: first handshake; OpenVPN/IKEv2: time-to-up), then **URL test**: `samples` (default 3) sequential requests to a test target through the test tunnel; per sample `dns_ms` (when the URL has a hostname), `connect_ms`, `total_ms`, `http_status`; aggregates `median_ms`, `min_ms`, `jitter_ms` (max−min), `loss_pct`. Optional `speed_mbps` (§7.8).
Implementation of the probes (decided by availability, VA-04/18/19):
- **DNS** via ucode `resolv` with `nameserver=<tunnel DNS>`; the query is steered into the test tunnel by `(dnsip,53) ∈ test_dst`.
- **TCP connect timing / plain HTTP**: ucode `socket` if packaged; **fallback** `uclient-fetch -q -T <t> -O /dev/null <url>` timed with a monotonic clock (total time) and busybox `nc` for TCP connect.
- **HTTPS URLs** only via `uclient-fetch`.
Default targets (configurable, FR-39/42; **no identifiers, no cookies, fixed generic User-Agent**): `https://www.gstatic.com/generate_204` (semantic default shared with sing-box [V: FA-20]) and `http://cp.cloudflare.com/generate_204` [A→VA-18]. Hostnames are resolved **through the test tunnel**. Targets must be `http(s)://host[:port]/path`, no userinfo, host not private/loopback/link-local/LAN (SSRF guard), ≤ 200 chars.
Result record (JSON):
```json
{"id":"p3a9f21c","proto":"wireguard","status":"pass","tested_at":1790000000,
 "probe_ms":null,"handshake_ms":142,"url":{"samples":3,"ok":3,"median_ms":96,"min_ms":88,"jitter_ms":14,"loss_pct":0},
 "speed_mbps":null,"reason":null,"hint":null}
```
`status ∈ pass | fail | skipped | cancelled | error` with `reason ∈ no_handshake | auth_failed | timeout | dns_failed | http_failed | latency | target_conflict | driver_missing | needs_credentials | resources | cancelled`.

### 7.5 Pass/fail thresholds and ranking
`config test 'test'` (§8.1): `max_handshake_ms` (default 8000), `max_latency_ms` (median, default 800), `max_loss_pct` (default 34 → ≥ 2 of 3 samples must succeed), `require_http` (default 1). **pass** ⇔ tunnel ready within `max_handshake_ms` ∧ (`require_http` ⇒ ok-samples ≥ ⌈samples×(1−max_loss)⌉) ∧ `median_ms ≤ max_latency_ms`. **Ranking key:** pass desc → `median_ms` asc → `handshake_ms` asc → `proto_preference` (default `wireguard, openvpn, ikev2`) → name. Ties within `tolerance_ms` (default 50, as in [V: FA-20]) are treated as equal and fall to the next key.

### 7.6 UI (Connections tab)
```
┌ Connections ─────────────────────────────────────────────────────────────────────────┐
│ ● Connected: Windscribe Dallas (WireGuard) 3h 12m   ↓1.2 GB ↑80 MB   [Stop][Emergency]│
│ [Import…] [Add ▾ OpenVPN|WireGuard|IKEv2] [Test all] [Test selected] [Connect best] ⚙ │
│ Test progress: ███████░░░ 7/10  “Windscribe Paris” … [Cancel]                          │
│ ☐ Name              Proto   Provider   Endpoint            Last test            Actions│
│ ☐ Dallas  ★active   WG      Windscribe dallas…:443        ✔ 96 ms · 142 ms hs  [live check][Edit]│
│ ☐ Paris             WG      Windscribe paris…:443         ✔ 121 ms · 160 ms    [Test][Connect]… │
│ ☐ Frankfurt         OVPN    Windscribe fra…:443/udp       ✔ 188 ms · 2.1 s     [Test][Connect]… │
│ ☐ Office            IKEv2⚗  generic    vpn.corp…          ✘ auth_failed        [Test][Edit][Del]│
│ Sort: [Latency ▾] [Name] [Last tested]   Filter: [All|Pass|Fail|Untested]  Group by provider ☐ │
└───────────────────────────────────────────────────────────────────────────────────────┘
```
Per-row **Test**; **Test all** = all `enabled` profiles (sequential real tests, probes up to 4 in parallel); **Test selected**; **Connect best** = test (or reuse a result younger than `test_ttl`) then connect the top-ranked passing profile; **Cancel** (aborts the job and cleans up). Result drawer shows the record fields, timestamps, hints and the last 20 test-log lines (scrubbed). Settings → *Testing*: thresholds, targets (list editor with validation), samples, timeout, TTL, speed-test URL/limits, preflight RAM/load. The **Connect** button honors `connect_gate` (§7.7). IKEv2 rows carry an "experimental" badge until VA-12 passes. Polling: 1 s only while a job runs, otherwise none.

### 7.7 Auto-connect, health checks and failover (exact behavior)
`config autoconnect 'auto'` (§8.1): `mode ∈ off | gate | best | fallback`, `fallback` (ordered list of profile ids), `connect_gate ∈ off | warn | require`, `test_ttl` (300 s), `health_enabled`, `health_interval` (multiples of 60 s, default 120), `fail_threshold` (3), `down_grace` (30 s), `failover` (0/1), `failback` (0/1, default 0), `min_switch_interval` (60 s), `max_switches_per_hour` (6), `persist_switch` (0).
| Policy | Behavior |
|---|---|
| **manual** (`mode=off`, `connect_gate=off`) | Connect = start the chosen profile; no test (baseline behavior). |
| **connect only if the test passes** (`connect_gate=require`) | Connect first runs a real test (reusing a pass ≤ `test_ttl`); on fail → **abort connect**, keep the current tunnel, show the result. `warn` asks for confirmation. |
| **connect best after testing** (`mode=best`, or the *Connect best* button) | Test candidates (`auto_pool=1`, enabled; at most `best_max_candidates`, default 8, cheapest first by last-known latency), rank (§7.5), connect the first passing one; if none pass → do **not** change the connection, report. |
| **fallback list** (`mode=fallback`) | Primary = `active_profile`; when it fails (below), try `fallback` entries in order. |
**Health check (cron tick, no resident process).** `* * * * * /usr/bin/geovpn health-tick` (installed only when `health_enabled=1` or WG/IKEv2 is active; ≈ 40 ms per tick). Every `health_interval` the tick runs the **live check** on the active tunnel: (1) driver `facts()` (OpenVPN up-state/IKEv2 SA/WG handshake age ≤ 180 s), (2) one URL sample through the live tunnel using the existing `fetch_vpn` marking (baseline set), (3) update `fail_count` (consecutive failures) in `/var/run/geovpn/health.json`.
**Failover trigger** (`failover=1`): `fail_count ≥ fail_threshold` **or** tunnel `down` longer than `down_grace`. Algorithm:
```
if now - last_switch < min_switch_interval or switches_last_hour >= max_switches_per_hour: stop auto; raise alert
candidates = ordered(fallback) if mode=fallback else rank(auto_pool) ; exclude current; take ≤ failover_max_candidates (3)
for c in candidates:
    r = recent_pass(c, test_ttl) or real_test(c)             # isolated, never touches current/kill-switch state
    if r.pass:  switch(c); reset counters; return            # break-before-make (below)
backoff: wait 1,2,4,…≤30 min, then retry; alert banner after the first failed round
```
**`switch(c)`** = baseline `service restart` with `active_profile` overridden **at runtime** (`/var/run/geovpn/active_override`); UCI `active_profile` is rewritten **only if** `persist_switch=1` (flash-wear and surprise avoidance). *Failback* (optional): when the original primary tests pass for 3 consecutive ticks, switch back (respecting rate limits).
**Break-before-make** is accepted in v1: the old tunnel is stopped, then the tested candidate started (≈ 1–5 s for OpenVPN/IKEv2, < 1 s for WireGuard). The test just before the switch is what makes the new connection predictable.
**Interaction with the kill switch.** *Kill switch ON:* during the switch window VPN-bound LAN traffic is **blocked by design** (table 4200 has only `unreachable`); direct (bypass-listed) traffic is unaffected. Tests are *not* VPN-bound traffic (TEST mark, own table), so they run normally while the kill switch blocks — failover candidates can be tested **during** an outage. *Kill switch OFF:* during the window, VPN-marked flows fall through to WAN (fail-open, as in the baseline) — the UI shows this next to the failover toggle; recommendation: enable the kill switch together with failover.
**Interaction with geo split.** Classification, sets, DNS and data are protocol-independent and untouched by switching; only table-4200's default route and the tunnel-DNS (`pushed`) change; dnsmasq is restarted only if the pushed DNS differs between profiles (e.g. different providers). Endpoint IPs of the *new* profile are added to the always-direct sets **before** its tunnel starts (so the transport never enters the tunnel).
**Flap protection.** Hysteresis (`fail_threshold`), `min_switch_interval`, hourly cap, exponential backoff, and "no switch while a user-initiated action holds the service lock".

### 7.8 Resource limits (AC-1304) [A→VA-11, VA-22]
| Limit | Default | Notes |
|---|---|---|
| Concurrent **real** tests | **1** (`test.max_real`, range 1–2) | CPU is the bottleneck (single-thread crypto). |
| Concurrent P1 probes | 4 | cheap sockets |
| Per-test timeout | 20 s (5–60) | covers handshake + samples |
| Job deadline | `n_profiles × (test_timeout + 5) + 30 s`, hard max 15 min | watchdog kills beyond |
| URL sample timeout | 5 s each, 3 samples | |
| Speed test | ≤ 2 MB **or** 10 s, **only on explicit request**, never in *Test all* | measures router capacity as much as the server |
| Preflight | refuse real tests if free RAM < 48 MB or 1-min load > 3.0 (`resources` reason) | thresholds calibrated in VA-22 |
| Result memory | ≤ 200 profiles × ~400 B in `/var/run` | volatile; optional daily persist to flash is **off** |
| Test tunnel lifetime | ≤ `test_timeout + 5` s | |

### 7.9 Cleanup guarantees (FR-44)
**Journal** `/var/run/geovpn/test/<jid>/journal` (append-only, one action per line, written *before* the action): `link gvt0` · `rule 701 v4|v6` · `route table 4300` · `nft test_ep <addr>` · `nft test_dst <addr . port>` · `proc <pidfile>` · `procd geovpn-test` · `swanctl conn gv_t_<jid>` · `xfrmi gvt0` · `file <path>` · `charon started`.
**`test_cleanup(jid|all)`** replays the journal in reverse, each step idempotent and error-tolerant, then verifies post-conditions. **Triggers:** normal end; failure/exception (ucode `try/finally`); cancel (`test_cancel` sets a flag + `SIGTERM` to the runner; runner traps TERM/INT/HUP in the sh wrapper → cleanup); runner crash/`kill -9` → **watchdog** (the cron tick, or a 1-minute cron entry present only while `/var/run/geovpn/test/*/job.json` exists, checks `deadline` and pid liveness); service start/stop/restart; `geovpn panic`; package removal; boot (tmpfs ⇒ empty); **self-expiry** (nft set elements time out after 90 s even if everything else fails; `unreachable` table 4300 + guard keep stale marks harmless).
**Post-conditions (asserted by `geovpn test-cleanup --verify`, exit 0 only if all hold):** no link `gvt0`; no `ip rule` priority 701 (v4/v6) and table 4300 empty; `test_dst*`, `test_ep*` empty; no `geovpn-test` procd instance or `openvpn --dev gvt0` process; no `gv_t_*` swanctl connection and no `xfrmi` with the test `if_id`; `/var/run/geovpn/test/` empty; `charon` stopped if (and only if) GeoVPN started it; **active tunnel state byte-identical** before/after (`state.json` unchanged, table 4200/rule 700/nft classifier untouched).
**Idempotence:** a second cleanup is a no-op; a *start* of a new job runs cleanup first if stale artifacts exist.

### 7.10 Privacy and path guarantees (FR-42)
Test traffic goes only to (a) the profile's own endpoint (underlay, unmarked, direct — inherent), (b) the tunnel DNS server, (c) the configured target `(ip, port)` pairs via the test tunnel. Endpoint hostname resolution uses the normal direct path (same exposure as a normal connect). Targets carry no account data, no cookies, a constant generic User-Agent (`geovpn-test`), and `User-Agent`/query strings can't be user-injected from rpc (validated). The optional *exit-info* feature (public trace endpoint) is **off by default**. Results never include credentials/keys; the test log is scrubbed like the baseline logs.

### 7.11 Job model and rpc flow
`test_start{ids|all, mode:probe|real|speed, connect_best?}` → `{job_id}` (immediately; the runner is detached via `spawn`); `test_status{job_id}` → `{state: queued|running|done|cancelled|failed, index, total, current:{id, step}, results:[…]}`; `test_cancel{job_id}`; `test_results{ids?}` → last results (volatile). Only **one job** at a time (lock `/var/run/geovpn/test.lock`); user-initiated `service` actions cancel a running job first (service has priority; the job's cleanup runs before the start sequence continues).

---

## 8. Changes to Schema, API, nftables/Routing/DNS, LuCI, ACL/Menu, i18n, Security

### 8.1 UCI schema additions and migration
**Profile options:** §6.1 (all additive). **New section types:**
```
config credential 'c_a1b2c3d4'            # secrets in /etc/geovpn/credentials/c_a1b2c3d4/auth (0700/0600), never in UCI
	option name 'Windscribe OpenVPN'
	option kind 'userpass'
	option has_secret '1'

config test 'test'                         # singleton
	option max_handshake_ms '8000'   # 1000–60000
	option max_latency_ms '800'      # 50–10000 (median of samples)
	option max_loss_pct '34'         # 0–100
	option require_http '1'
	option samples '3'               # 1–10
	option timeout_s '20'            # 5–60
	option tolerance_ms '50'
	option test_ttl '300'            # seconds a pass stays valid
	option max_real '1'              # 1–2
	option min_free_ram_mb '48'
	option max_load '3.0'
	list   targets 'https://www.gstatic.com/generate_204'
	list   targets 'http://cp.cloudflare.com/generate_204'
	list   proto_preference 'wireguard'
	list   proto_preference 'openvpn'
	list   proto_preference 'ikev2'
	option speed_url ''              # empty = speed test disabled
	option speed_max_kb '2048'
	option rt_table '4300'           # test routing table   (rule priority = main.rule_priority + 1)

config autoconnect 'auto'                  # singleton
	option mode 'off'                # off | gate | best | fallback
	list   fallback ''               # ordered profile ids
	option connect_gate 'off'        # off | warn | require
	option health_enabled '0'
	option health_interval '120'     # multiple of 60, 60–3600
	option fail_threshold '3'        # 1–10
	option down_grace '30'           # 5–600 s
	option failover '0'
	option failover_max_candidates '3'
	option best_max_candidates '8'
	option failback '0'
	option min_switch_interval '60'
	option max_switches_per_hour '6'
	option persist_switch '0'
```
Validation rules are enforced in `config.uc` (ranges above; `targets` per §7.4; ids `^[pc][0-9a-f]{8}$`). Unknown options are ignored with a warning (baseline rule).
**Migration v1 → v2** (`/etc/uci-defaults/91-geovpn-migrate`, mode 0755, idempotent):
1. If `main.config_version ≥ 2` → exit. 2. Copy `/etc/config/geovpn` to `/etc/geovpn/backup/geovpn.v1.<epoch>` (0600). 3. **Do not rewrite existing profiles** (absent `proto` = `openvpn`). 4. Add `config test 'test'` and `config autoconnect 'auto'` with the defaults above if missing. 5. `uci set geovpn.main.config_version=2; uci commit geovpn`. 6. On any error restore the backup and exit non-zero (the baseline keeps running with the v1 file). 7. `geovpn migrate --rollback` restores the newest backup; `geovpn migrate --prepare-downgrade` re-points `active_profile` to an OpenVPN profile and warns about WG/IKEv2 profiles (the baseline would show them as incomplete OpenVPN profiles and refuse to start them — safe, no leak).
Fresh installs ship the v2 default file. The migration never starts/stops services and never touches nft/ip/dnsmasq/firewall.

### 8.2 rpcd/ubus API (object `luci.geovpn`) — changes
All new inputs: length-limited, regex-validated, error shape unchanged (`{error,message}`); **no method returns secrets**.
| Method | Args | Returns | Notes |
|---|---|---|---|
| `import_profile` (new; `import_ovpn` stays as alias) | `content` (≤128 KB), `filename?`, `name?`, `kind?` (`auto`…), `cred?`, `dry_run?` | `{id?, proto, provider, summary, ignored:[], warnings:[], incomplete:[], duplicate_of?}` | Dispatcher §5.2; `dry_run` powers the batch report. |
| `credential_save` | `id?`, `name`, `username`, `password?` | `{id}` | Password write-only; omit to keep the existing one. |
| `credential_list` | — | `{items:[{id,name,username,has_secret,used_by:[ids]}]}` | Username is not secret; password never returned. |
| `credential_delete` | `id` | `{ok}` | Refused while referenced (or `force`). |
| `profile_put_material` | + roles `wg-key`, `wg-psk`, `ike-ca` | `{ok,bytes}` | Validated PEM/base64. |
| `drivers` | — | `{openvpn:{ok},wireguard:{ok,missing:[]},ikev2:{ok,missing:[],note}}` | Drives UI hints/install buttons text. |
| `test_start` | `ids?[]` or `all?`, `mode` (`probe|real|speed`), `connect_best?` | `{job_id}` | One job at a time (`busy` otherwise). |
| `test_status` | `job_id` | `{state,index,total,current,results:[]}` | Poll 1 s while running. |
| `test_cancel` | `job_id` | `{ok}` | Triggers cleanup. |
| `test_results` | `ids?[]` | `{items:[record]}` | Volatile. |
| `test_cleanup` | `verify?` | `{ok,leftovers:[]}` | Idempotent. |
| `autoconnect_status` | — | `{mode,fail_count,last_switch,switches_last_hour,override,alerts:[]}` | |
| `service` | `action` + `switch` | `{ok,state}` | `switch` requires `profile`; honors `connect_gate`. |
| `status` | — | + `tunnel.proto`, `tunnel.last_handshake`, `health`, `override` | Backward compatible superset. |
| `diag` | — | + driver availability, strongSwan/WireGuard module checks, **orphan scan** (test artifacts) | |
Detached work (jobs, health ticks) runs via `/usr/libexec/geovpn/spawn` (baseline V-14 covers the rpcd detach contract).

### 8.3 nftables / routing / DNS
| Area | Change |
|---|---|
| nft | §7.2 additions: `test_dst4/6` (concatenated `ip . port`, 90 s timeout), `test_ep4/6`, `out` TEST rules first, `test_guard`; `classify` gets `test_ep` direct rules. The `structure hash` of the baseline includes these sets; reload/replace logic unchanged. Mark value `3` is reserved for TEST (`mark_shift` unchanged). |
| Routing | Table 4300 + rule priority `rule_priority+1` created **only while a test job runs** (journaled), `unreachable default` first; `panic` and `teardown` also remove them. Preflight extends: table 4300/priority 701 must be free. |
| fw4 | **No change**: zone `geovpn` stays device `geovpn0` for every protocol. Test device `gvt0` is deliberately **not** in any zone (input/forward from it stay dropped by fw4; replies to test-originated flows are ESTABLISHED and accepted by fw4's normal conntrack rule [A→VA-09]). |
| DNS | No change to dnsmasq generation. **New rule:** profile endpoint hostnames of *non-active* profiles (tests, failover candidates) are resolved with ucode `resolv` against **explicit direct nameservers** (the baseline's `auto` direct set) — never through dnsmasq's default path, which in `bypass` mode goes through the (possibly down) active tunnel. For the active profile the baseline `server=/<host>/<direct>` rule applies unchanged. Candidate endpoint IPs are inserted into `always4_dyn/always6_dyn` **before** the switch. |
| IPv6 | Unchanged logic fed by `facts.has_v6`. |

### 8.4 LuCI changes
| View/module | Change |
|---|---|
| `profiles.js` | Rewritten: multi-protocol table (§7.6), import modal (§5.7), per-protocol edit modals (OpenVPN unchanged; WG: endpoint, addresses, DNS, MTU, keepalive, allowed-IPs (read-only unless partial), *replace keys* (write-only inputs); IKEv2: host, remote ID, credential set, CA, advanced), credential-set manager, status card generalized, **Emergency** button retained. |
| **new** `testpanel.js` (module) | Job control, progress, result drawer, sorting/filtering, thresholds shortcut. |
| **new** `importer.js` | Multi-file reader (≤128 KB each), dispatcher call per file, dry-run report, duplicate resolution, credential prompt. |
| **new** `autoconnect.js` | Mode/fallback list (drag & drop), health/failover controls, alerts banner. |
| `settings.js` | Groups *Testing* and *Auto-connect*; "Driver status" box (what is installed/missing + the exact `apk add` command text). |
| `logs.js` | Sources `geovpn-test`, `charon` (if present, scrubbed). |
| `split.js` | **Unchanged** (protocol-blind). |
| Menu | Unchanged. **ACL:** read += `drivers, credential_list, test_status, test_results, autoconnect_status`; write += `import_profile, credential_save, credential_delete, test_start, test_cancel, test_cleanup` (existing `service`, `panic`, `profile_*`). UCI `geovpn` read/write only; no `network`/`firewall`/`file` ACL (all privileged work is server-side). |
| Performance | Result tables ≤ 200 rows rendered; polling only during jobs; no data URLs/QR in v1. |
| Verification | VA-20 (multi-file input, `ui.Table` sort, progress patterns). |

### 8.5 i18n (EN + FA)
New strings (≈ 250 [A]) for protocols, import report messages, test reasons/hints (`no_handshake`, `auth_failed`, …), thresholds, auto-connect/failover, IKEv2 experimental notice, driver-missing messages. Rules unchanged from baseline §11.7: English source in `_()`, `po/templates/geovpn.pot` regenerated, `po/fa/geovpn.po` complete (CI gate ≤ 2 % untranslated), RTL logical CSS, **LTR isolation for all technical tokens** (endpoints, keys' fingerprints, IPs, CIDRs, `10.255.255.3`, `generate_204` URLs). Persian terminology table kept in `docs/i18n-fa-glossary.md` (e.g. اعتبارنامه = credential, دست‌دهی = handshake, تأخیر = latency) for consistency; native review before release.

### 8.6 Security design (additions to baseline §12)
| Threat | Mitigation |
|---|---|
| WireGuard `.conf` carrying shell hooks (`PostUp`…) | Denied (FA-12); only allowlisted keys; unknown keys reject the import. |
| Obfuscation/“AmneziaWG” keys misparsed | Reject with explanation; never partially import. |
| Key leakage | Keys only in 0600 files, read by `wg` from path; never in argv/UCI/rpc/log; scrubber extended with the WireGuard key shape (`[A-Za-z0-9+/]{43}=`) and `0x<hex>` secrets. |
| Injection into `swanctl.conf` | All values regex-whitelisted (no `{ } " # \ ; newline`), **secrets emitted as `0x<hex>`**, file rendered by the generator only, 0600 in tmpfs. |
| `ike-updown` env injection (runs as root from charon) | Fixed path, root-owned 0755, env whitelist + per-value regex, writes only under `rundir`; calls `geovpn _hook` with validated args. |
| SSRF/abuse via test URLs | `http(s)` only, no userinfo, ≤ 200 chars, host must not be private/loopback/link-local/LAN or an IP in protected sets (§7.2), ports 80/443/8080/8443 default allowlist (configurable), redirects not followed. |
| Test as a DoS on the router | Concurrency/timeout caps, preflight, single job, hard deadlines, watchdog. |
| Traffic from a test leaking | Fail-closed table 4300 + `test_guard` + 90 s set expiry (C-07; AT-28). |
| Credential-set mishandling | Dir 0700/file 0600; `credential_list` never returns passwords; delete wipes (`rm` + overwrite best-effort); referenced-by check. |
| Job/profile id tampering, path traversal | ids `^[pct][0-9a-f]{8}$`; paths composed from validated ids only; realpath confinement (baseline). |
| `.sswan` JSON bombs | Size 16 KB, depth ≤ 6, key allowlist. |
| Windscribe-specific parser CVE class (FA-08) | NUL/control-char rejection, single tokenizer implementation shared by parser and renderer, fuzzing in A9. |
| Auto-failover as an attack surface (flapping to a malicious profile) | Candidates only from the user's own enabled profiles; no remote-provided lists; rate limits. |

---

## 9. Packaging Changes

### 9.1 Package set (v1.1.0)
| Package | Status | Contents | In `geovpn`? | In `geovpn-full`? |
|---|---|---|---|---|
| `geovpn-core` | **updated** (1.1.0) | drivers, importers, test engine, health tick, `geovpn-test` init, migration | ✔ | ✔ |
| `luci-app-geovpn` (+ `luci-i18n-geovpn-fa`) | **updated** | new JS modules, ACL, `.pot/.po` | ✔ | ✔ |
| `geovpn-wireguard` | **new**, `PKGARCH:=all` | no files; `DEPENDS:=+geovpn-core +kmod-wireguard +wireguard-tools` | ✔ | ✔ |
| `geovpn-ikev2` | **new**, `PKGARCH:=all` | `ike-updown`, `/usr/share/geovpn/ca/*.pem`, driver glue; strongSwan deps (§9.2) | ✘ | ✔ |
| `geovpn` | **updated meta** | `+geovpn-core +luci-app-geovpn +luci-i18n-geovpn-fa +geovpn-wireguard` | — | — |
| `geovpn-full` | **new meta** | `+geovpn +geovpn-ikev2` | — | — |
| `geovpn-data-seed` | unchanged | | | |
Rationale: WireGuard is small, mainstream and part of the owner's primary use case → in the default meta-package; strongSwan is large, has had a feed outage (FA-17) and a Tier-2 feature set → opt-in. apk has no "recommends" concept [A→VA-21], hence explicit meta-packages. The driver code itself ships in `geovpn-core` (a few KB) and **detects** missing dependencies at runtime (`available()`), so installing/removing the optional packages never requires a core upgrade.

### 9.2 Dependencies (to verify: VA-02, VA-03)
`geovpn-wireguard`: `+kmod-wireguard +wireguard-tools`.
`geovpn-ikev2` (names **to verify**; list from the OpenWrt strongSwan package family): `+strongswan-charon +strongswan-swanctl +strongswan-mod-vici +strongswan-mod-kernel-netlink +strongswan-mod-socket-default +strongswan-mod-openssl +strongswan-mod-eap-mschapv2 +strongswan-mod-md4 +strongswan-mod-des +strongswan-mod-updown +strongswan-mod-pem +strongswan-mod-x509 +strongswan-mod-pubkey +strongswan-mod-pkcs1 +strongswan-mod-nonce +strongswan-mod-random +strongswan-mod-hmac +strongswan-mod-sha2 +strongswan-mod-aes +strongswan-mod-gcm +kmod-xfrm-interface +kmod-ipsec4 +kmod-ipsec6`. *(A sample `strongswan-default` installation on `ipq40xx/mikrotik` did not contain `eap-mschapv2`/`md4`, FA-17/VA-02, so they are explicit.)* Alternative if the maintainers' dependency graph changes: depend on `strongswan-full` (larger).
`geovpn-core`: no new hard dependency (uses `uclient-fetch`, `ucode-mod-resolv`, busybox `timeout`). If `ucode-mod-socket` turns out to be packaged (VA-04) add it to `DEPENDS`; otherwise keep the fallbacks (§7.4).

### 9.3 Footprint and budget (AC-1304: 512 MB RAM, 4 GB eMMC [V]) — estimates **[A→VA-02, VA-11, VA-22]**
| Item | Flash | RAM (steady / peak) |
|---|---|---|
| Addendum scripts/JS (`geovpn-core`+LuCI delta) | ≤ +160 KB (NFR-17) | 0 resident |
| `kmod-wireguard` + `wireguard-tools` | ≈ tens–100 KB [FA-13] | negligible |
| strongSwan family for IKEv2 | ≈ 1–3 MB [A] | `charon` ≈ 5–10 MB [A] while running |
| Second OpenVPN process during a test | — | ≈ 5–10 MB for ≤ 25 s [A] |
| Test sets/rules | — | < 100 KB |
All fit the AC-1304 comfortably; on 128 MB/16 MB-flash devices IKEv2 is not recommended. Replace estimates with measurements in phase A9.

### 9.4 Upgrade path and files
`apk upgrade` (or `apk add geovpn`) → `geovpn-core` postinst → `91-geovpn-migrate` (§8.1) → `rpcd reload`; the running tunnel is **not restarted** by the upgrade (baseline behavior: the user presses *Apply*/restart; a banner tells them a new version is active). New/changed files: `/etc/init.d/geovpn-test` (0755), `/usr/libexec/geovpn/{ike-updown,spawn}` (0755), `/etc/uci-defaults/91-geovpn-migrate` (0755), cron marker block `# geovpn health begin/end`. `/lib/upgrade/keep.d/geovpn` gains `/etc/geovpn/credentials` and `/etc/geovpn/backup`. `conffiles`: `/etc/config/geovpn` (unchanged). Uninstall (`prerm`) additionally runs `geovpn test-cleanup`, removes the health cron marker, and **never** stops a charon it did not start. Version `1.1.0`, `config_version=2`, data-pack schema unchanged.

---

## 10. Testing Strategy (extends baseline §15)

### 10.1 Layers added
| Layer | Additions |
|---|---|
| L0 Static | shellcheck for `geovpn-test`, `ike-updown`, health tick; ucode `-c` on drivers/importers; ESLint on new JS modules; JSON schema for `.sswan` fixtures. |
| L1 Unit | `wg_parse` corpus (valid / Windscribe-shaped / hostile: PostUp family, multi-peer, AmneziaWG keys, bad base64, NUL, CRLF/BOM, 100 KB, `AllowedIPs` partial/huge); OpenVPN parser deltas (`ncp-ciphers`, ping/keepalive rules, NUL); IKEv2 smart-paste grammar and `.sswan` parser; `swanctl.conf`/WG/OpenVPN renderers (golden files, injection attempts in every field); credential store permissions; scoring/threshold/ranking logic; failover state machine (time-mocked: thresholds, backoff, rate limits); journal replay; URL validator (SSRF cases). |
| L2 Render | `nft -c -f` for the extended ruleset; `wg setconf`-style dry validation where possible; `swanctl --load-conns` dry parse (if supported) in the harness; golden diff of baseline ruleset vs. extended (only additions). |
| L3 Integration | Harness (§10.2) with WG, OpenVPN and strongSwan peers; netem for latency/loss. |
| L4 Device/Owner | AC-1304 checklist + **owner's real Windscribe account** acceptance (AT-42). |

### 10.2 Integration harness additions (QEMU/x86 OpenWrt 25.12 or rootfs container + netns, baseline §15.2)
Peers (Linux namespaces on the host): **WireGuard server** (kernel wg, NAT to inet-ns echo servers, distinct egress IP per server for path proof), **OpenVPN server** (UDP+TCP, `tls-auth`, `auth-user-pass-verify` test script, pushes `redirect-gateway`, `dhcp-option DNS`, `ping-restart 60`), **strongSwan server** (EAP-MSCHAPv2 users, test CA — the harness can't reproduce Windscribe's real CA, so the trust anchor is injected via `ike_ca=file`; the real CA chain is covered only by AT-42), **echo/HTTP servers** (`/generate_204`), **netem** for RTT/loss/jitter, `tcpdump` taps on WAN/LAN/tunnels. Fixtures: synthetic Windscribe-shaped configs (§5.8) for the three protocols; baseline-v1 config fixtures for migration.

### 10.3 Acceptance tests ↔ requirements
| AT | Scenario | Covers |
|---|---|---|
| AT-22 | **Migration**: baseline-v1 fixtures (OpenVPN + geo split + kill switch + per-client policies) → upgrade → rendered nft (minus additive sets), `ip rule`, routes, dnsmasq file **identical**; tunnel stays up; rollback restores. | FR-45, NFR-15 |
| AT-23 | Downgrade rehearsal (`--prepare-downgrade`, install baseline) | NFR-15 |
| AT-24 | WG import: valid + Windscribe-shaped accepted; hostile corpus rejected/neutralized; no key in logs/rpc/argv | FR-31, FR-33, NFR-18 |
| AT-25 | WG tunnel + split (bypass & include), path proof, kill switch, IPv6 leak test (v4-only WG), `pushed` DNS 10.255.255.3-style | FR-29, FR-15, FR-16, FR-17 |
| AT-26 | Windscribe-shaped OpenVPN (`ncp-ciphers`, `ping 10` + `ping-exit 60`, bare `auth-user-pass`, `tls-auth`) starts and survives pushed `ping-restart 60`; N1/N2 verified | FR-33, FR-02 |
| AT-27 | **Test isolation**: during a real test of B, active A shows no loss and ≤ 20 % latency change; table 4200/rule 700/classifier unchanged; LAN DNS works | FR-37, NFR-14 |
| AT-28 | **Test leak**: kill switch on + test tunnel down/unreachable → no test packets on WAN or `geovpn0` (tcpdump); marked packets only via `gvt0` | C-07, FR-42 |
| AT-29 | **Cleanup** under failure injection: `kill -9` runner at every journal step, cancel, reboot, disk-full, concurrent start → `test-cleanup --verify` passes; set expiry ≤ 90 s | FR-44 |
| AT-30 | Result correctness with netem: ranking, thresholds, tolerance, `no_handshake`, `auth_failed`, `timeout`, `dns_failed`, `target_conflict` | FR-36, FR-39 |
| AT-31 | UI: Test / Test all / selected / Cancel / sort / progress; concurrency cap; resource preflight refusal | FR-38, FR-43 |
| AT-32 | Connect policies: `require` aborts on fail; `warn`; best; fallback ordering | FR-40 |
| AT-33 | Health + **failover**: kill server → switch within bound; kill switch ON ⇒ no leak in the window, OFF ⇒ documented fail-open; flap protection, backoff, hourly cap; geo split unaffected after switch | FR-41 |
| AT-34 | IKEv2 (if VA-13 allows): connect, split, DNS, kill switch, **Tier-2 test** isolation/cleanup, `charon` ownership rules | FR-30, FR-32, FR-37 |
| AT-35 | Credential sets: one credential for N profiles; rotation; modes 0700/0600; used-by protection | FR-34, NFR-18 |
| AT-36 | Batch import of 30 files, dedupe, naming, UI responsiveness | FR-35 |
| AT-37 | Optional packages absent: hints, no crash, `driver_missing` | NFR-16 |
| AT-38 | ACL + validation for all new methods; SSRF cases; id tampering | FR-21, FR-42 |
| AT-39 | FA translation complete; RTL token isolation | FR-22 |
| AT-40 | Install/upgrade/uninstall matrix (`geovpn`, `geovpn-full`, removing `geovpn-ikev2`) leaves no orphan rules/links/conns/cron/files | FR-25, FR-44 |
| AT-41 | AC-1304 measurements: test impact, RAM, speed test, size budget | NFR-14, NFR-17 |
| AT-42 | **Owner acceptance with real Windscribe account**: OpenVPN, WireGuard, IKEv2 each: import → test → connect → exit IP check → DNS path → geo split | FR-33 |
Baseline AT-01…AT-21 stay in the regression set and must remain green after every phase.

---

## 11. Implementation Roadmap (addendum phases A0–A9)
| Phase | Deliverables | Depends on | Est. (p-days) | Definition of Done |
|---|---|---|---|---|
| **A0 Reconcile** | Repo-vs-PLAN mapping table; baseline regression run; fixtures of v1 configs; close VA-01, VA-02, VA-03, VA-04, VA-05, VA-23 | — | 2 | Mapping + green baseline AT-01…21; verified package names/sizes recorded |
| **A1 Driver refactor + migration** | `drivers/` skeleton; OpenVPN driver extracted **with zero behavior change**; profile model v2; `91-geovpn-migrate` + rollback; new UCI sections; N1/N2 keepalive fix; `import.uc` dispatcher (OpenVPN only) | A0 | 5 | AT-22, AT-23, AT-26 (OpenVPN part) pass; baseline AT unchanged; diff of nft/ip outputs = ∅ |
| **A2 WireGuard** | `wg_parse.uc`, driver, `geovpn-wireguard`, state/facts, always-direct integration, import via dispatcher, Windscribe WG preset; close VA-06, VA-07, VA-15 | A1 | 6 | AT-24, AT-25 pass |
| **A3 Credentials & batch import** | Credential sets (backend+UI), batch importer, dedupe/naming, Windscribe OpenVPN preset | A1 | 4 | AT-35, AT-36, AT-26 |
| **A4 Test engine core** | `test_*` library, journal/cleanup, nft/route additions, OpenVPN+WG real tests, TCP probe, URL tests, thresholds/scoring, `geovpn-test` init, `geovpn test` CLI; close VA-08, VA-09, VA-10, VA-11, VA-18, VA-19 | A2 | 8 | AT-27, AT-28, AT-29, AT-30 pass |
| **A5 Test UI** | rpc methods, `testpanel.js`, results table/sort/filter, settings group, resource preflight | A4 | 5 | AT-31, AT-38 (test part) |
| **A6 Auto-connect & failover** | `connect_gate`, best/fallback, health tick, failover, backoff, alerts, UI | A4, A5 | 5 | AT-32, AT-33 |
| **A7 IKEv2 (optional)** | `ike_import.uc`, driver, `ike-updown`, loading method decision (M1/M2), CA handling, `geovpn-ikev2`, Tier-2 test, UI forms; close VA-12 (owner), VA-13, VA-14, VA-17, VA-24 | A2, A4 | 8 | AT-34 pass or **documented probe-only fallback** with the decision recorded |
| **A8 i18n, docs, packaging, CI** | `.pot/.po` (FA), README EN/FA updates (§13), meta-packages, feed/CI matrix incl. new packages, QEMU peers in CI; close VA-20, VA-21, VA-25 | A1–A7 | 5 | AT-37, AT-39, AT-40 |
| **A9 Hardening & device** | Fuzzing (parsers), soak (failover + tests, 24 h), AC-1304 measurements, owner Windscribe acceptance; update §9.3 numbers | A8 | 4 | AT-41, AT-42; report with real numbers |
| | | **Total** | **≈ 52** | v1.1.0 tag |
Ordering notes: A2 and A3 can overlap after A1; A5/A6 can start once A4's rpc contract is frozen; A7 may slip to v1.1.1 **without blocking** the release of WireGuard + testing (the packaging keeps it optional).

---

## 12. Risks & Mitigations
| ID | Risk | L/I | Mitigation |
|---|---|---|---|
| RA-01 | strongSwan packages missing/broken in a 25.12 build again (FA-17) or lagging security fixes (6.0.3 vs 6.0.7) | M/M | IKEv2 optional; `available()`; banner; documented fallback (OpenVPN/WG); track version in diag |
| RA-02 | Windscribe IKEv2 parameters differ from assumptions (proposals, CA, remote ID, parallel sessions) | M/M | "experimental"; VA-12 with owner's account; manual proposal override; probe-only fallback |
| RA-03 | `charon` coexistence/loading semantics unload user's connections | M/H | Decide M1/M2 empirically (VA-13); AT-34 asserts untouched connections; refuse if unsafe |
| RA-04 | Test traffic leaks or captures router traffic (dst-set marking) | L/H | `(ip . port)` sets, conflict guard, fail-closed table, guard chain, 90 s expiry; AT-28 |
| RA-05 | Orphan artifacts after crash | M/M | Journal-before-action, watchdog, self-expiry, `--verify`; AT-29 |
| RA-06 | Parallel session with same credentials kicks the active tunnel during a test | M/H | Refuse/warn per §7.1; VA-17; default `max_real=1`; live check for the active profile |
| RA-07 | Failover flapping or switching into a worse tunnel | M/M | Hysteresis, test-before-switch, rate limits, backoff, alerts |
| RA-08 | WG `AllowedIPs` partial or Windscribe invalidates keys | M/L | Import validation + hints; no auto-regeneration (no API use) |
| RA-09 | Windscribe format drift (generator changes) | M/L | Allowlist parsers + report of ignored directives; fixtures from owner; provider label has no behavior |
| RA-10 | `ucode-mod-socket` not packaged → coarser timings | M/L | Fallbacks (§7.4) documented; accuracy note in UI |
| RA-11 | Break-before-make gap during failover | H/L | Documented; kill switch recommended; WG gap < 1 s |
| RA-12 | License contamination | L/H | C-06, zero vendored code, NOTICE; review in A8 |
| RA-13 | Migration bug breaks working setups | L/H | Backup/rollback, no profile rewriting, AT-22/23, regression suite |
| RA-14 | UI complexity/perf on mobile | L/L | Paginated tables, polling only during jobs |
| RA-15 | AC-1304 CPU contention during tests degrades LAN throughput | M/M | One real test at a time, load/RAM preflight, ≤ 25 s tunnels; AT-27/41 |

---

---

## 13. README Changes (exact text)

Apply to `README.md` (EN) and `README.fa.md` (FA). **Replace** the paragraph/list/table named in each heading; **add** the new sections where indicated. Commands marked ⚠ must be re-verified against the real behavior (VA items) before release. Four-backtick fences are only for embedding here.

### 13.1 `README.md` (English)

````markdown
<!-- REPLACE the intro paragraph -->
GeoVPN turns an OpenWrt router into a **VPN client that sends only the traffic you choose through the VPN** — with
**OpenVPN, WireGuard or IKEv2**. Pick countries (GeoIP) and domain categories (GeoSite) in LuCI: matching traffic goes
**directly** through your normal internet connection, everything else goes **through the VPN** — or the other way round.
Import your provider's files (Windscribe is a first-class target), **test every profile before connecting**, connect to the
best one, and let GeoVPN fail over automatically if it stops working.

<!-- REPLACE the Features list: add these bullets -->
- **Three protocols**: OpenVPN, WireGuard, IKEv2 (EAP username/password) — one Connections tab, one split-tunneling engine.
- **Import**: `.ovpn`, WireGuard `.conf`, IKEv2 form/paste (and strongSwan `.sswan`); drop many files at once; credentials entered once and shared.
- **Test before you connect**: per-profile and *Test all* (handshake/connect time, URL latency, pass/fail thresholds) in an isolated test tunnel that never touches your active VPN or LAN traffic.
- **Auto-connect**: connect only if the test passes, connect to the best profile, ordered fallback list, optional health checks with automatic failover.

<!-- REPLACE the 'Supported devices and versions' table row 'Other devices' and ADD a protocol table -->
| Protocol | Package | Notes |
|---|---|---|
| OpenVPN | `geovpn-core` (always) | `openvpn-openssl`, OpenVPN 2.7.x |
| WireGuard | `geovpn-wireguard` (in `geovpn`) | kernel module `kmod-wireguard`; single-peer profiles |
| IKEv2 | `geovpn-ikev2` (in `geovpn-full`) | strongSwan `swanctl` + XFRM interface; **experimental**; larger (see Performance) |

<!-- REPLACE 'Installation → A) From the package feed' last step -->
```sh
apk update
apk add geovpn          # core + LuCI + Persian + WireGuard
# optional, adds IKEv2 (strongSwan):
apk add geovpn-full     # ⚠ verify package availability for your release: apk search strongswan
```
Add IKEv2 later with `apk add geovpn-ikev2`; remove it with `apk del geovpn-ikev2` (IKEv2 profiles stay, disabled).

<!-- ADD after 'First-time setup' -->
## Using your Windscribe configs
GeoVPN needs a Windscribe **Pro or Build-a-Plan** account and the files from your account's **Config Generators**
(OpenVPN, WireGuard, IKEv2). GeoVPN cannot download them for you (no account tokens are used).

**OpenVPN** — generate a `.ovpn` (choose location, UDP/TCP, port 443 is a good default) and click **Get Credentials**
for the separate *OpenVPN username/password* (these are **not** your account login and are the same for all profiles).
In LuCI: *VPN → GeoVPN → Connections → Import*, select one or many `.ovpn` files, enter the credentials once and keep
“use for all” ticked.

**WireGuard** — generate a `.conf` per location (keep a new key pair or reuse one). **Do not edit `AllowedIPs`**;
GeoVPN decides what goes through the tunnel. Import the files the same way (no credentials needed, keys are inside).
Tip: GeoVPN uses MTU 1420 and keepalive 25 if the file has none.

**IKEv2** *(experimental, needs `geovpn-ikev2`)* — the generator only gives you a **hostname, username and password**.
*Add → IKEv2* and paste them (or fill the form).

Not supported: Windscribe *Stealth/WStunnel*, the Windscribe app's firewall and app-level split tunneling (GeoVPN has its own kill switch and split tunneling).
WireGuard keys are tied to the location and can be invalidated by Windscribe — if a profile never gets a handshake, generate a new config.

## Testing profiles and auto-connect
- **Test** (per row) or **Test all**: GeoVPN brings the profile up on a separate temporary device (`gvt0`), measures the
  handshake/connect time and a few HTTP requests through it, and tears it down. Your active VPN and your LAN are not affected.
  A test takes ≤ 20 s; one tunnel test runs at a time to protect the router's CPU.
- **Pass/fail** thresholds and test URLs: *Settings → Testing*. Results are sorted by latency.
- **Connect best** tests (or reuses a recent pass) and connects the fastest passing profile. **Connect only if the test passes**: *Settings → Auto-connect → Connect gate = require*.
- **Failover**: *Auto-connect → Health checks* + *Failover*. When the active VPN fails the checks, GeoVPN tests the next candidates and switches to the first one that passes. Recommended together with the **kill switch** (otherwise VPN-bound traffic briefly goes direct during the switch).
- Limits you should know: UDP-only servers (WireGuard, OpenVPN/UDP with `tls-auth`) cannot be pinged without a real handshake — the real test is the check; the active profile is checked “live” instead of with a second tunnel; IKEv2 tests are best-effort.
- CLI: `geovpn test --all`, `geovpn test <id>`, `geovpn test-cleanup --verify`, `geovpn switch <id>`.

<!-- ADD to 'Configuration reference' -->
`profile` (new): `proto` (`openvpn|wireguard|ikev2`), `provider`, `group`, `cred`, `auto_pool`, `test_url`;
WireGuard: `wg_endpoint_host`, `wg_endpoint_port`, `wg_public_key`, `wg_address`, `wg_dns`, `wg_allowed_ips`, `wg_mtu` (1420), `wg_keepalive` (25);
IKEv2: `ike_host`, `ike_remote_id`, `ike_auth`, `ike_ca`, `ike_proposals`, `ike_esp`, `ike_dpd` (30), `ike_fragmentation`, `ike_mobike`, `ike_if_id` (4242).
`credential`: `name`, `kind`. `test`: `max_handshake_ms` (8000), `max_latency_ms` (800), `max_loss_pct` (34), `require_http` (1), `samples` (3), `timeout_s` (20), `test_ttl` (300), `max_real` (1), `targets`, `speed_url`.
`autoconnect`: `mode` (`off|gate|best|fallback`), `fallback`, `connect_gate` (`off|warn|require`), `health_enabled`, `health_interval` (120), `fail_threshold` (3), `down_grace` (30), `failover`, `failback`, `min_switch_interval` (60), `max_switches_per_hour` (6), `persist_switch` (0).

<!-- ADD to 'Troubleshooting' -->
| Symptom | Check / fix |
|---|---|
| WireGuard: no handshake | UDP blocked or wrong endpoint; for Windscribe the key may be invalidated → regenerate the config; `wg show geovpn0` |
| WireGuard imports but nothing works | `AllowedIPs` must include `0.0.0.0/0` (GeoVPN refuses narrower ones) |
| OpenVPN profile “needs credentials” | Add the credential set (Windscribe: the *OpenVPN* credentials, not your login) |
| IKEv2 “authentication failed” | Re-check username/password (IKEv2 credentials), hostname; `logread -e charon` |
| IKEv2 not available in the UI | `apk add geovpn-ikev2` (or `geovpn-full`); check `apk search strongswan` for your release |
| Test says `resources` | Free RAM < 48 MB or high load: stop other jobs, try again |
| Test says `target_conflict` | Change the test URL (its IP is used by another GeoVPN rule) |
| Leftovers after a crash (`gvt0`, rule 701) | `geovpn test-cleanup` (they also expire by themselves within 90 s) |
| Failover keeps switching | Raise `fail_threshold`/`min_switch_interval`; check the target URL is reachable through every profile |

<!-- ADD to 'Security notes' -->
- WireGuard files are parsed with an allowlist; `PostUp/PreUp/PostDown/PreDown` and unknown/obfuscation keys are **rejected**. Private keys live only in `/etc/geovpn/profiles/<id>/` (root, 0600).
- Test URLs must be `http(s)` to public hosts; private/LAN targets are refused.
- Backups contain your VPN keys and credentials (`/etc/geovpn/profiles`, `/etc/geovpn/credentials`).

<!-- ADD to 'Performance notes' -->
WireGuard runs in the kernel and is usually faster than OpenVPN on this CPU. IKEv2 (strongSwan) adds a few MB of flash/RAM. A tunnel test briefly runs a second tunnel (≈ 25 s, one at a time).

<!-- ADD to 'FAQ' -->
**Can I test the profile I'm currently using?** It gets a *live check* (handshake age, a few requests through the live tunnel) instead of a second tunnel, because many providers don't like two sessions on one account.
**Does GeoVPN rotate keys or fetch new Windscribe configs?** No. You download configs yourself; GeoVPN only imports and tests them.
**Upgrading from 1.0?** Automatic: your config is backed up to `/etc/geovpn/backup/` and migrated without touching existing profiles. Roll back with `geovpn migrate --rollback`.
````

### 13.2 `README.fa.md` (فارسی)

````markdown
<div dir="rtl">

<!-- جایگزین پاراگراف معرفی -->
GeoVPN روتر OpenWrt شما را به یک **کلاینت VPN** تبدیل می‌کند که **فقط ترافیکِ انتخاب‌شده را از VPN عبور می‌دهد** — با
**OpenVPN، WireGuard یا IKEv2**. در LuCI کشورها (GeoIP) و دسته‌های دامنه (GeoSite) را انتخاب می‌کنید؛ ترافیکِ منطبق **مستقیم** و بقیه
**از VPN** می‌رود (یا برعکس). فایل‌های سرویس‌دهندهٔ خود را وارد کنید (Windscribe هدف اصلی است)، **هر پروفایل را پیش از اتصال آزمایش کنید**،
به بهترین آن متصل شوید و اگر از کار افتاد، GeoVPN خودکار به پروفایل دیگر سوئیچ کند.

<!-- افزودن به فهرست امکانات -->
- **سه پروتکل**: OpenVPN، WireGuard، IKEv2 (نام‌کاربری/گذرواژهٔ EAP) — یک تب اتصال‌ها و یک موتور تونل‌زنی تفکیکی.
- **درون‌ریزی**: فایل‌های `.ovpn` و `.conf` وایرگارد، فرم/چسباندن IKEv2 (و `.sswan`)؛ انتخاب چند فایل هم‌زمان؛ اعتبارنامه یک بار وارد و مشترک می‌شود.
- **آزمون پیش از اتصال**: برای هر پروفایل یا «آزمون همه» (زمان دست‌دهی/اتصال، تأخیر درخواست HTTP، حد قبول/رد) در یک تونل آزمایشی جدا که به VPN فعال و ترافیک شبکهٔ محلی دست نمی‌زند.
- **اتصال خودکار**: فقط در صورت قبولی آزمون، اتصال به بهترین پروفایل، فهرست پشتیبان با ترتیب، و بررسی سلامت با جابه‌جایی خودکار (اختیاری).

## پروتکل‌ها و بسته‌ها
| پروتکل | بسته | توضیح |
|---|---|---|
| OpenVPN | `geovpn-core` | همیشه نصب است |
| WireGuard | `geovpn-wireguard` (داخل `geovpn`) | ماژول هسته `kmod-wireguard`؛ پروفایل تک‌همتا |
| IKEv2 | `geovpn-ikev2` (داخل `geovpn-full`) | strongSwan؛ **آزمایشی** |

## نصب

</div>

```sh
apk update
apk add geovpn          # هسته + LuCI + فارسی + WireGuard
apk add geovpn-full     # اختیاری: افزودن IKEv2
```

<div dir="rtl">

## استفاده از فایل‌های Windscribe
به حساب **Pro یا Build-a-Plan** و فایل‌های بخش **Config Generators** حساب خود نیاز دارید (OpenVPN، WireGuard، IKEv2). GeoVPN آن‌ها را برای شما دانلود نمی‌کند.

**OpenVPN** — فایل `.ovpn` را بسازید (مکان، UDP/TCP و درگاه؛ ۴۴۳ پیشنهاد خوبی است) و با **Get Credentials** نام‌کاربری/گذرواژهٔ **جداگانهٔ OpenVPN** را بگیرید (این‌ها گذرواژهٔ ورود حساب نیستند و برای همهٔ پروفایل‌ها یکسان‌اند).
در LuCI: *VPN ← GeoVPN ← Connections ← Import*؛ یک یا چند فایل را انتخاب و اعتبارنامه را یک بار وارد کنید («استفاده برای همه» فعال بماند).

**WireGuard** — برای هر مکان یک `.conf` بسازید. **مقدار `AllowedIPs` را ویرایش نکنید**؛ GeoVPN خودش تعیین می‌کند چه چیزی از تونل برود. فایل‌ها را همین‌طور وارد کنید (کلیدها داخل فایل‌اند). اگر فایل MTU یا keepalive نداشته باشد، GeoVPN مقدارهای ۱۴۲۰ و ۲۵ را به کار می‌برد.

**IKEv2** *(آزمایشی؛ نیازمند `geovpn-ikev2`)* — مولّد فقط **نام میزبان، نام‌کاربری و گذرواژه** می‌دهد. از *Add ← IKEv2* آن‌ها را الصاق کنید یا فرم را پر کنید.

پشتیبانی نمی‌شود: *Stealth/WStunnel* در Windscribe، فایروال و تقسیم‌ترافیک برنامهٔ Windscribe (GeoVPN کلید قطع و تونل‌زنی تفکیکی خودش را دارد).
کلیدهای WireGuard وابسته به مکان‌اند و ممکن است باطل شوند — اگر هیچ‌گاه دست‌دهی انجام نشد، پیکربندی جدید بسازید.

## آزمون پروفایل‌ها و اتصال خودکار
- **Test** (هر ردیف) یا **Test all**: GeoVPN پروفایل را روی یک دستگاه موقت جدا (`gvt0`) بالا می‌آورد، زمان دست‌دهی/اتصال و چند درخواست HTTP را اندازه می‌گیرد و جمع می‌کند. VPN فعال و شبکهٔ محلی شما تحت‌تأثیر قرار نمی‌گیرد. هر آزمون حداکثر حدود ۲۰ ثانیه است و هم‌زمان فقط یک آزمون تونل اجرا می‌شود.
- **حد قبول/رد** و نشانی‌های آزمون: *Settings ← Testing*. نتایج بر اساس تأخیر مرتب می‌شوند.
- **Connect best**: بهترین پروفایلِ قبول‌شده را وصل می‌کند. **فقط در صورت قبولی آزمون**: *Settings ← Auto-connect ← Connect gate = require*.
- **جابه‌جایی خودکار**: *Auto-connect ← Health checks + Failover*. پیشنهاد می‌شود با **کلید قطع** استفاده شود؛ وگرنه ترافیک مخصوص VPN در لحظهٔ جابه‌جایی مستقیم می‌رود.
- محدودیت‌ها: سرورهای فقط‌UDP (WireGuard و OpenVPN/UDP با `tls-auth`) بدون دست‌دهیِ واقعی «پینگ» نمی‌شوند؛ پروفایل فعال با «بررسی زنده» سنجیده می‌شود نه تونل دوم؛ آزمون IKEv2 در حد تلاش است.
- دستورها: `geovpn test --all`، `geovpn test <id>`، `geovpn test-cleanup --verify`، `geovpn switch <id>`.

## عیب‌یابی (افزوده‌ها)
- **WireGuard دست‌دهی نمی‌کند:** ‏UDP مسدود/نشانی اشتباه؛ در Windscribe ممکن است کلید باطل شده باشد؛ `wg show geovpn0`.
- **WireGuard وارد شد ولی کار نمی‌کند:** ‏`AllowedIPs` باید `0.0.0.0/0` را شامل شود.
- **پروفایل OpenVPN «نیازمند اعتبارنامه»:** مجموعهٔ اعتبارنامهٔ OpenVPN را (نه گذرواژهٔ ورود حساب) اضافه کنید.
- **IKEv2 «احراز هویت ناموفق»:** نام‌کاربری/گذرواژهٔ IKEv2 و نام میزبان را بررسی کنید؛ `logread -e charon`.
- **بازمانده‌ها پس از خطا (`gvt0`):** ‏`geovpn test-cleanup` (در هر حال تا ۹۰ ثانیه خودبه‌خود منقضی می‌شوند).

## ارتقا از نسخهٔ ۱٫۰
خودکار است: پیکربندی شما در `/etc/geovpn/backup/` پشتیبان‌گیری و بدون دست‌زدن به پروفایل‌های موجود مهاجرت داده می‌شود. بازگشت: `geovpn migrate --rollback`.

</div>
````

---

## 14. Open Questions for the Owner (defaults applied until answered)
| ID | Question | Recommended default |
|---|---|---|
| OQA-01 | Ship IKEv2 in the default `geovpn` meta-package? | **No** — `geovpn-full` (reason: FA-17, size, Tier-2) |
| OQA-02 | Adopt externally managed (netifd) WireGuard/other interfaces as "external" profiles (split-only)? | Not in v1.1; candidate for v1.2 |
| OQA-03 | Persist failover switches to UCI (`active_profile`)? | **No** (runtime override; flash and surprise avoidance) |
| OQA-04 | Default test targets | gstatic `generate_204` (HTTPS) + Cloudflare captive-portal `generate_204` (HTTP) |
| OQA-05 | Default `connect_gate` | `off` (manual = baseline behavior) |
| OQA-06 | QR import | Defer (client-side QR decoding library = extra JS weight) |
| OQA-07 | Windscribe Stealth/WStunnel support | **Unsupported** in v1.1 (FA-06) |
| OQA-08 | Keep project license Apache-2.0 (no vendoring) or move to GPL to allow reuse of GPL code? | Keep Apache-2.0 (C-06) |
| OQA-09 | Concurrency of real tests | 1 (range 1–2) |
| OQA-10 | Health checks via cron tick (≤ 60 s granularity) vs. a resident watcher | Cron tick (C-05) |
| OQA-11 | Speed test | Off unless a `speed_url` is configured; never in *Test all* |
| OQA-12 | Allow partial AllowedIPs (`wg_allow_partial`) | Hidden advanced flag, off |
| OQA-13 | Make-before-break failover (keep both tunnels briefly) | Not in v1.1 (needs dual-device active model) |
| OQA-14 | Which Windscribe locations/profiles should the repo's fixtures mirror? | Owner supplies 1 redacted sample per protocol (VA-15/16) |

---

## 15. Appendix — Document Control
- `PLAN.md` + this addendum + the current repository are the sources of truth; conflicts are resolved in `DECISIONS.md` (ID, date, context, options, decision, affected sections) and reflected back here by PR.
- Traceability: every `FR-28…FR-46`, `NFR-14…NFR-19`, `C-05…C-07` maps to ≥ 1 acceptance test in §10.3 and to files named in §6.8/§8/§9; the final report must contain the full matrix (baseline IDs included where affected, §2.3).
- Source list: §3.1 (all URLs). Items marked [A] are not facts until closed in §3.2.
