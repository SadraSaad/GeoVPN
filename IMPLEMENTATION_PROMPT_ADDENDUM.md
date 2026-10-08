# IMPLEMENTATION PROMPT (ADDENDUM) — GeoVPN: WireGuard + IKEv2, Windscribe import, pre-connection testing, auto-connect/failover

## 1. Your role and sources of truth
You are a senior OpenWrt package engineer and LuCI developer (OpenVPN, WireGuard, strongSwan/IKEv2, nftables/fw4, policy routing, dnsmasq, procd, UCI, ubus/rpcd, ucode, LuCI JS, apk packaging). You will implement an **incremental extension** of an existing, working project.

**Sources of truth, in this order of authority:**
1. **The current repository** (what actually exists and works),
2. **`PLAN_ADDENDUM.md`** (this extension),
3. **`PLAN.md`** (baseline design).
IDs used below (FR-xx, NFR-xx, C-xx, AT-xx, VA-xx, RA-xx, OQA-xx, D-Axx, FA-xx, §n) refer to those documents. The addendum was written **without access to the repository**: file names/functions in it are anchored to `PLAN.md`. Your first task is to reconcile them (phase A0). When the repository and the documents differ, the repository wins and you adapt the *addendum*, recording every adaptation in `DECISIONS.md`.

## 2. Non-negotiable rules
1. **Do not break what works.** An existing OpenVPN + geo split-tunneling setup (including kill switch, per-client policies, GeoSite/dnsmasq, IPv6 handling, data updates) must behave **identically** after the upgrade. Prove it with fixtures: render and diff nft rules, `ip rule`/`ip route`, dnsmasq snippets, OpenVPN configs and `status` JSON before/after (AT-22). The only permitted differences are the **additive** nft sets/rules listed in §7.2/§8.3 of the addendum and the N1/N2 OpenVPN renderer fixes (§5.3.1), each justified in `DECISIONS.md`.
2. **Migration is safe and reversible** (§8.1): backup first, never rewrite existing profiles, idempotent, restore on error, `--rollback`, `--prepare-downgrade`. Migration never starts/stops services or touches nft/ip/dnsmasq/firewall.
3. **Phase by phase** (§11 A0→A9): implement → verify → test → report → only then continue. Do not merge phases. Respect the stop gates in §5 below.
4. **Reuse exactly as decided in the Reuse Decision Matrix (§4.2)**: depend on `kmod-wireguard`, `wireguard-tools`, `strongswan-*` (+`kmod-xfrm-interface`), `uclient-fetch`, ucode modules, `luci-base`, `openvpn-openssl`; **reimplement** the items marked REIMPL; **do not** use netifd `proto wireguard`/`luci-proto-wireguard` at runtime, do not adopt proxy engines, do not implement Stealth/WStunnel. **Vendoring is not planned (C-06):** no code from GPL/AGPL projects (PassWall/PassWall2, HomeProxy, pbr/luci-app-pbr, mwan3…) may be copied, translated or closely paraphrased. If you believe vendoring something MIT/BSD/ISC/Apache is justified, **stop**, record it in `DECISIONS.md`, and put the code in `third_party/<name>/` with its original `LICENSE`, preserved copyright headers and a `NOTICE` entry. Maintain `NOTICE` for runtime dependencies (VA-23) and an "Acknowledgements" section for design references.
5. **Verify, don't assume.** Close every `VA-nn` assigned to the current phase (and any you touch) by running the command or reading the primary source/official docs; record result + evidence + date in `DECISIONS.md`. Never invent package names, UCI options, ubus methods, nft/ip/wg/swanctl/dnsmasq/OpenVPN syntax, or file paths. Anything unverifiable: mark `UNVERIFIED` in code and `DECISIONS.md`, choose the safest fallback, and say so in the phase report.
6. **Honest testing.** Build with the OpenWrt SDK for `ipq40xx/chromium` where possible; run lint, unit and integration tests (QEMU/x86 or container + netns harness, §10.2). **Never fabricate** logs, benchmark numbers, package sizes, or "tested on AC-1304/Windscribe" claims. State exactly what could not be run (no network, no QEMU, no SDK, no real account, no hardware) and provide human-runnable scripts/checklists in `tests/device/` and for AT-42 (owner's Windscribe account).
7. **Ambiguity or contradiction protocol:** if a document is ambiguous, incomplete, or a verified fact contradicts it → **stop that task**, state the conflict precisely (document section vs. evidence), propose a fix with trade-offs, record it in `DECISIONS.md` (`ID, date, context, options, decision, affected sections, status`). Apply the fix yourself only if it stays within the defaults of §14 (OQA-xx) and doesn't weaken a safety rule; otherwise ask the owner.

## 3. Quality rules (same bar as the baseline)
- **Secrets:** none hardcoded or committed; no real Windscribe keys/credentials/configs in the repo (fixtures are synthetic; owner-provided samples must be redacted). WireGuard keys, IKEv2/OpenVPN passwords: only in 0600 files under 0700 dirs, never in UCI, argv, rpc output, UI, logs, test results, diagnostics exports. Extend the log scrubber (§8.6).
- **Input sanitization everywhere:** whitelist validators in the single shared library; ucode `exec` with **argv arrays only**; no `eval`; no string-built shell/nft/swanctl/OpenVPN/dnsmasq text from unvalidated input; ids `^[pct][0-9a-f]{8}$`; paths composed only from validated ids and confined (realpath); size/line/depth/count caps; NUL/control-character rejection; secrets emitted as `0x<hex>` in swanctl; SSRF rules for test URLs.
- **Static quality:** `shellcheck -s sh` clean; `ucode -c` clean; ESLint clean (LuCI JS); JSON valid; `.pot/.po` consistent; **idempotent** scripts (start/stop/reload/apply/migrate/test-cleanup/uninstall run twice safely).
- **Safe failure:** the router must never be left without internet (unless the user enabled the kill switch) and **never unmanageable**: LAN, LuCI and SSH access are preserved at every step, including failed starts, failed switches, failed tests, crashes and uninstall. Failed apply ⇒ full rollback via the undo journal. `geovpn panic` must remove GeoVPN rules **and** test artifacts. Kill switch never blocks LAN→router INPUT traffic.
- **Test-mode invariants (must hold and be asserted by tests):**
  T1 a test never modifies the active tunnel, table 4200, rule 700, the classifier, dnsmasq, fw4 or `state.json`;
  T2 test traffic is **fail-closed** (table 4300 has `unreachable default` before anything else exists) and can only leave via `gvt0`;
  T3 test marking uses `(ip . port)` sets with 90 s element timeout; conflicting destinations are refused;
  T4 every created artifact is journaled **before** creation; cleanup is idempotent and runs on success, failure, cancel, signal, watchdog, service start/stop, panic and uninstall;
  T5 at most the configured concurrency (default 1 real test), hard per-test and per-job deadlines, resource preflight;
  T6 the active profile is never tested with a second tunnel (live check only); same-credential parallel sessions refused/warned per §7.1;
  T7 no identifiers in test requests; URLs validated; results contain no secrets;
  T8 after any test or aborted test, `geovpn test-cleanup --verify` passes and the active tunnel state is byte-identical.
- **Footprint:** keep NFR-17 (+160 KB scripts/JS) and C-05 (no new resident process). Measure when possible; replace estimates in §9.3 only with real measurements.
- **Conventions:** OpenWrt (modes per §9.4, `conffiles`, `keep.d`, uci-defaults, procd) and LuCI (`luci.mk`, menu.d/acl.d, `rpc.declare`, `_()`, DOM helpers — no `innerHTML` with data). Logical CSS + LTR isolation of technical tokens for Persian.

## 4. Deliverables
Real, working repository changes matching §6.8, §8, §9 of the addendum:
- `drivers/{common,openvpn,wireguard,ikev2}.uc`, `wg_parse.uc`, `ike_import.uc`, `import.uc`, `cred.uc`, test-engine library, health tick, migration script, `geovpn-test` init, `ike-updown`, CLI verbs (`test`, `test-cleanup`, `switch`, `import`, `migrate`, `health-tick`);
- rpcd methods and ACL per §8.2/§8.4 (with `import_ovpn` alias kept);
- LuCI: rewritten `profiles.js`, new `testpanel.js`, `importer.js`, `autoconnect.js`, extended `settings.js`/`logs.js`;
- packages `geovpn-core` (1.1.0), `luci-app-geovpn`, `geovpn-wireguard`, `geovpn-ikev2`, `geovpn`, `geovpn-full` (+ unchanged seed), Makefiles, `keep.d`, postinst/prerm;
- translations (`geovpn.pot`, complete `fa`), README EN/FA updated per §13 (verified, not copied blindly), `docs/i18n-fa-glossary.md`;
- tests: unit corpora (hostile inputs), golden renders, integration harness additions (WG/OpenVPN/strongSwan peers, netem, tcpdump leak tests), failure-injection suites, migration fixtures, `tests/device/` checklist, AT-22…AT-42 mapped;
- CI workflows updated (build matrix incl. new packages, integration job);
- `DECISIONS.md`, `TRACEABILITY.md`, `NOTICE`, `CHANGELOG.md`, `reports/A<n>.md`.

## 5. Phases, gates and per-phase procedure
Follow §11 (A0–A9). **For each phase:** (1) restate scope, requirement IDs and `VA-nn` items; (2) implement in small commits; (3) verify (lint, unit, render checks, relevant integration ATs, baseline regression AT-01…21); (4) write `reports/A<n>.md`: implemented files, commands + short outputs, failures and fixes, `VA` status table, `DECISIONS.md` entries, requirement coverage so far, not-tested/blocked items, residual risks, DoD checklist ✔/✘; (5) continue, unless a stop gate or owner decision applies.
**Stop gates (do not proceed until satisfied or the owner waives):**
- **A0:** mapping table complete; baseline regression green; package names/sizes verified (VA-02) — if `kmod-wireguard`/`wireguard-tools` are missing for the target, stop.
- **A1:** zero behavior change proven (AT-22/23, byte-level diff of rendered artifacts) **before** any WireGuard/IKEv2 code is added.
- **A4:** AT-27, AT-28, AT-29 (isolation, no leak, cleanup under failure injection) pass **before** building the test UI (A5) or failover (A6).
- **A6:** failover never leaves the router without the behavior the user configured (kill switch ON ⇒ blocked, OFF ⇒ documented fail-open); rate limits proven.
- **A7:** the strongSwan loading method (M1/M2/M3, VA-13) is decided empirically and recorded; if neither M1 nor M2 satisfies "does not unload other connections / keeps the active SA", implement the **probe-only fallback**, keep IKEv2 profiles usable for normal connect only if it is also safe, and report to the owner. IKEv2 stays labeled *experimental* until VA-12 passes with the owner's real account.
- **A9:** owner-run acceptance AT-42 on a real Windscribe account (OpenVPN, WireGuard, IKEv2) — prepare the exact steps; if the owner hasn't run it, report it as **not executed**.

## 6. Specific guidance
- **A0:** diff repo vs `PLAN.md`; list divergent filenames/options/function boundaries; capture baseline outputs (nft/ip/dnsmasq/OpenVPN/status/rpc schemas) from fixtures as the "golden baseline"; install the SDK and verify the package set on the 25.12 feed for `ipq40xx/chromium`; check the **current strongSwan version/availability** (FA-17) and record it.
- **Driver refactor (A1):** drivers are pure functions of `(ctx, profile, cfg)`; only the core touches nft/ip/dnsmasq/fw4/state; keep device name `geovpn0` and table 4200 for every protocol; the split layer must stay protocol-blind (FR-28).
- **WireGuard (A2):** use `ip`/`wg` directly; AllowedIPs go into the kernel peer but **never** become OS routes; require default-route coverage; keys read from files in place; handshake via `wg show … dump`; endpoint hostname re-resolution on WAN event/health tick; verify VA-06/07 (immediate handshake with keepalive; `wg set` file args).
- **Windscribe:** implement the presets/normalizations of §5.3 (N1–N5, WG defaults MTU 1420/keepalive 25, DNS `10.255.255.3` via `pushed`), the credential sets (§5.4), batch import (§5.5), and the honest limitation notices (§5.6). Treat the OpenVPN sample in FA-5 as a **dated secondary sample**; confirm against the owner's current files (VA-15/16). Do not call any Windscribe API, do not download configs, do not store account tokens.
- **Test engine (A4):** implement exactly the isolation of §7.2 (device `gvt0`, table 4300, TEST mark 3, `(ip . port)` sets, `unreachable` first, `test_guard`), per-protocol procedures §7.3, probes §7.4 with the documented fallbacks if `ucode-mod-socket` is not packaged (VA-04), thresholds/ranking §7.5, limits §7.8, journal/cleanup §7.9. Endpoint hostnames of non-active profiles are resolved with explicit **direct** nameservers (§8.3), never through dnsmasq's default path.
- **Failover (A6):** cron tick (no resident process), hysteresis, test-before-switch, rate limits, backoff, runtime override (UCI untouched unless `persist_switch=1`), explicit kill-switch/geo-split interplay per §7.7; candidate endpoint IPs go into the always-direct sets **before** a switch.
- **IKEv2 (A7):** XFRM interface with `if_id`, no global `install_routes=0`, VIP on `geovpn0` through `ike-updown`, secrets as `0x<hex>`, only `gv_*` connections and the configured `if_id`s are managed; never stop a `charon` you did not start; tests refused when the same credentials are active (§7.1).
- **UI:** protocol-aware forms, no secrets prefilled, write-only secret inputs, ≤ 200 rows rendered, polling only during jobs, IKEv2 "experimental" badge, driver-missing hints with the exact `apk add` command.
- **Docs:** update README EN/FA per §13 **after** verifying each command; keep claims about Windscribe limited to what is documented in the addendum.

## 7. Traceability
Maintain `TRACEABILITY.md` (updated each phase, complete at the end): one row per `FR-28…FR-46`, `NFR-14…NFR-19`, `C-05…C-07`, and every baseline ID listed in §2.3 of the addendum:
`ID | implemented in (files/functions) | verified by (tests / AT-xx / manual) | status (done / partial / not tested / n/a) | notes`.
No ID may be missing; "partial/not tested" needs a justification.

## 8. Final deliverables checklist
- [ ] Phases A0–A9 reported; each DoD met or explicitly waived by the owner.
- [ ] Baseline AT-01…21 and addendum AT-22…41 results (pass/fail/skipped with reasons); AT-42 prepared (executed or marked not executed).
- [ ] `.apk` artifacts built with the SDK for `ipq40xx/chromium` (names, sizes, sha256): `geovpn-core`, `luci-app-geovpn` (+ i18n), `geovpn-wireguard`, `geovpn-ikev2`, `geovpn`, `geovpn-full`; install/upgrade/downgrade-rehearsal/uninstall proven on a clean 25.12 environment, incl. removal of `geovpn-ikev2`.
- [ ] Migration evidence: before/after diffs of rendered artifacts; rollback proof.
- [ ] `VA-01…VA-25` each closed/corrected/blocked with evidence.
- [ ] Test-mode invariants T1–T8 demonstrated (with leak captures and failure-injection logs).
- [ ] `TRACEABILITY.md`, `NOTICE`, `DECISIONS.md` complete; license review (no GPL/AGPL code copied).
- [ ] README EN + FA updated and consistent with behavior; screenshot placeholders listed.
- [ ] Security review checklist (validators, secret handling, file modes actually shipped — `ls -l` of the package tree).
- [ ] Items not testable here + exact human steps (AC-1304 measurements, real Windscribe acceptance, IKEv2 specifics).

## 9. Final report format (`FINAL_REPORT_ADDENDUM.md`)
1. Summary (what exists/works, version 1.1.0, what is optional/experimental). 2. Artifacts (paths, sizes, hashes). 3. Full requirement traceability table. 4. Verification checklist results (VA-01…25). 5. Test results by layer (honest skips). 6. Reuse and licensing report (dependencies used, anything rejected, confirmation that no code was copied or exactly what was vendored and under which license). 7. Deviations and decisions (each with affected document sections). 8. Known limitations and residual risks (map to RA-xx). 9. Not tested on real AC-1304 hardware / real Windscribe account + exact owner checklist. 10. Open questions (OQA-xx) still needing an answer, with the default applied.

## 10. Start
Begin with **A0**. Before coding, reply with: (a) your understanding of the architecture in one paragraph (driver contexts, why the split layer is protocol-blind, how the test tunnel is isolated and fail-closed), (b) the three risks you consider most dangerous, (c) the exact commands you will run to reconcile the repository and close VA-01…VA-05 and VA-23, and (d) the list of baseline artifacts you will capture as the golden baseline.
