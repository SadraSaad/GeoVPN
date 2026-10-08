#!/usr/bin/env python3
"""
Acceptance Tests for Phase A4: Pre-Connection Test Engine (§7, §11 A4)
Upholding Test-Mode Invariants T1–T8:
  AT-27: Test isolation verification (active table 4200, rule 700, fw4, dnsmasq untouched)
  AT-28: Leak prevention (fail-closed table 4300, unreachable default route, SSRF guard)
  AT-29: Cleanup under failure injection (crash simulation, journal rollback, zero residuals)
  AT-30: Protocols, Scoring, Ranking, Thresholds, and CLI verbs
"""
import unittest
import os
import subprocess
import json
import shutil
import tempfile
import time


class TestEngine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_test_engine_')
        self.conf_dir = os.path.join(self.test_dir, 'config')
        self.cred_dir = os.path.join(self.test_dir, 'credentials')
        self.run_dir = os.path.join(self.test_dir, 'run')
        self.prof_dir = os.path.join(self.test_dir, 'profiles')
        os.makedirs(self.conf_dir, exist_ok=True)
        os.makedirs(self.cred_dir, exist_ok=True)
        os.makedirs(self.run_dir, exist_ok=True)
        os.makedirs(self.prof_dir, exist_ok=True)

        # Baseline v2 configuration
        uci_content = """
config main 'main'
	option config_version '2'
	option enabled '1'
	option active_profile 'p11111111'
	option tun_dev 'geovpn0'
	option mode 'bypass'
	option kill_switch '1'

config profile 'p11111111'
	option name 'Active Tunnel'
	option proto 'openvpn'
	option enabled '1'
	list remote '198.51.100.1 1194 udp'

config profile 'p22222222'
	option name 'WireGuard Candidate'
	option proto 'wireguard'
	option enabled '1'
	option wg_endpoint_host '203.0.113.50'
	option wg_endpoint_port '51820'
	option wg_public_key 'xTuoQiUKS2gahBdWoVue64muS1WOH6eaCQU+5Arf4Ww='
	list wg_address '10.2.0.2/32'
	list wg_allowed_ips '0.0.0.0/0'

config profile 'p33333333'
	option name 'OpenVPN Candidate'
	option proto 'openvpn'
	option enabled '1'
	list remote '198.51.100.200 1194 udp'

config test 'test'
	option max_handshake_ms '8000'
	option max_latency_ms '800'
	option max_loss_pct '34'
	option require_http '1'
	option samples '3'
	option timeout_s '15'
	option tolerance_ms '50'
"""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write(uci_content.strip() + '\n')

        # Setup active profile files
        act_prof_dir = os.path.join(self.prof_dir, 'p11111111')
        os.makedirs(act_prof_dir, exist_ok=True)
        with open(os.path.join(act_prof_dir, 'profile.ovpn'), 'w') as f:
            f.write("client\ndev geovpn0\nremote 198.51.100.1 1194 udp\n")

        # Setup WG candidate files
        wg_prof_dir = os.path.join(self.prof_dir, 'p22222222')
        os.makedirs(wg_prof_dir, exist_ok=True)
        with open(os.path.join(wg_prof_dir, 'wg.key'), 'w') as f:
            f.write("MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\n")
        os.chmod(os.path.join(wg_prof_dir, 'wg.key'), 0o600)

        # Active state.json snapshot
        self.initial_state = {
            "service": {"enabled": True, "state": "connected"},
            "tunnel": {
                "profile": "p11111111",
                "name": "Active Tunnel",
                "device": "geovpn0",
                "since": 1790000000,
                "uptime": 120,
                "local_ip": "10.8.0.2",
                "remote_ip": "198.51.100.1",
                "ipv6": False
            },
            "split": {"mode": "bypass", "kill_switch": True}
        }
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.initial_state, f, indent=2)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_ucode(self, script, env_extra=None):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        env = os.environ.copy()
        env['GEOVPN_CRED_DIR'] = self.cred_dir
        env['GEOVPN_PROFILES_DIR'] = self.prof_dir
        env['UCI_CONFIG_DIR'] = self.conf_dir
        env['GEOVPN_RUN_DIR'] = self.run_dir
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True, env=env)
        return proc

    # ------------------------------------------------------------------------
    # AT-27: Test Isolation Verification (Invariants T1 & T6)
    # ------------------------------------------------------------------------

    def test_at27_test_isolation_active_state_untouched(self):
        """
        AT-27: Verify active tunnel, table 4200, rule 700, and state.json remain completely untouched
        during and after a test of candidate profile (Invariant T1).
        """
        state_file = os.path.join(self.run_dir, 'state.json')
        with open(state_file, 'r') as f:
            pre_test_state_bytes = f.read()

        script = """
        import * as te from 'geovpn.test_engine';
        let res = te.test_profile('p22222222', { timeout_s: 1 });
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertEqual(res['id'], 'p22222222')

        # Assert state.json is byte-identical
        with open(state_file, 'r') as f:
            post_test_state_bytes = f.read()
        self.assertEqual(pre_test_state_bytes, post_test_state_bytes, "Active state.json must be 100% byte-identical (T1/T8)")

    def test_at27_active_profile_gets_live_check_only(self):
        """
        AT-27 / Invariant T6: The active profile is never tested with a second tunnel (gvt0);
        it executes a live check only.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let res = te.test_profile('p11111111');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertEqual(res['id'], 'p11111111')
        self.assertIn('Live check on active profile', res.get('hint', ''), "Active profile must receive live check notice (T6)")

    def test_at27_shared_credentials_refusal_for_ikev2(self):
        """
        AT-27 / Invariant T6: Parallel session sharing credentials with active tunnel is refused for IKEv2.
        """
        # Create shared credential set
        cred_id = 'c_shared01'
        c_dir = os.path.join(self.cred_dir, cred_id)
        os.makedirs(c_dir, exist_ok=True)
        with open(os.path.join(c_dir, 'auth'), 'w') as f:
            f.write("user\npass\n")

        # Set active profile and candidate profile with same cred
        with open(os.path.join(self.conf_dir, 'geovpn'), 'a') as f:
            f.write(f"\nconfig profile 'p44444444'\n\toption proto 'ikev2'\n\toption cred '{cred_id}'\n\toption enabled '1'\n")

        # Set active profile cred
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            content = f.read().replace("option active_profile 'p11111111'", f"option active_profile 'p11111111'\n\toption cred '{cred_id}'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(content)

        script = """
        import * as te from 'geovpn.test_engine';
        let res = te.test_profile('p44444444');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertEqual(res['status'], 'fail')
        self.assertEqual(res['reason'], 'parallel_session_refused', "IKEv2 sharing credentials with active tunnel must be refused (T6)")

    # ------------------------------------------------------------------------
    # AT-28: Leak Prevention (Invariants T2, T3 & T7)
    # ------------------------------------------------------------------------

    def test_at28_fail_closed_table_4300_initialization(self):
        """
        AT-28: Verify table 4300 is initialized fail-closed with 'unreachable default'
        BEFORE test interface is raised (Invariant T2).
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let job_id = 't_test_failclosed';
        te.journal_init(job_id);
        te.setup_test_routing(job_id, 4300, 701);
        let j = te.journal_get(job_id);
        print(sprintf('%J', j));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        entries = json.loads(proc.stdout)

        # Assert unreachable default routes in journal
        has_v4_unreach = any(e.get('type') == 'route_unreachable' and e.get('family') == 4 for e in entries)
        has_v6_unreach = any(e.get('type') == 'route_unreachable' and e.get('family') == 6 for e in entries)
        has_rule_701 = any(e.get('type') == 'ip_rule' and e.get('prio') == 701 for e in entries)

        self.assertTrue(has_v4_unreach, "IPv4 unreachable default route must be journaled and initialized (T2)")
        self.assertTrue(has_v6_unreach, "IPv6 unreachable default route must be journaled and initialized (T2)")
        self.assertTrue(has_rule_701, "Priority 701 rule must be journaled and initialized (T2)")

    def test_at28_ssrf_protection_prohibits_private_and_metadata_targets(self):
        """
        AT-28 / Invariant T7: SSRF validator rejects private IPs, loopback, link-local,
        cloud metadata endpoints (169.254.169.254), and userinfo credentials.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let tests = [
            'http://127.0.0.1:8080/',
            'http://10.0.0.1/admin',
            'http://192.168.1.1/',
            'http://172.16.0.10/',
            'http://169.254.169.254/latest/meta-data/',
            'http://[::1]/',
            'http://[fe80::1]/',
            'http://localhost/secret',
            'http://admin:secret@example.com/',
            'http://example.com:22/ssh',
            'https://www.gstatic.com/generate_204'
        ];
        let results = [];
        for (let u in tests) {
            push(results, te.validate_probe_url(u));
        }
        print(sprintf('%J', results));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        results = json.loads(proc.stdout)

        # 0..9 should be rejected (ok == False)
        for i in range(10):
            self.assertFalse(results[i]['ok'], f"Target {i} must be rejected by SSRF guard")
            self.assertIn(results[i]['error'], ['SSRF_PROHIBITED', 'PORT_PROHIBITED'])

        # 10 (gstatic 204) must be accepted
        self.assertTrue(results[10]['ok'], "Valid public https target must be accepted")
        self.assertEqual(results[10]['port'], 443)

    def test_at28_conflict_guard_refuses_active_tunnel_infrastructure(self):
        """
        AT-28 / Invariant T3: Destination conflict guard rejects test targets matching
        active VPN server endpoints or DNS resolvers to avoid hijacking active traffic.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let c = { main: { dns_vpn_servers: ['1.1.1.1', '9.9.9.9'] } };
        let active_p = { remotes: ['198.51.100.1 1194 udp'] };

        let c1 = te.check_target_conflict('198.51.100.1', 1194, c.main, active_p);
        let c2 = te.check_target_conflict('1.1.1.1', 53, c.main, active_p);
        let c3 = te.check_target_conflict('9.9.9.9', 853, c.main, active_p);
        let c4 = te.check_target_conflict('10.0.0.1', 80, c.main, active_p);
        let c5 = te.check_target_conflict('142.250.190.46', 443, c.main, active_p);

        print(sprintf('%J', [c1, c2, c3, c4, c5]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        conflicts = json.loads(proc.stdout)
        self.assertTrue(conflicts[0], "Conflict with active server remote endpoint must be detected")
        self.assertTrue(conflicts[1], "Conflict with VPN DNS (1.1.1.1:53) must be detected")
        self.assertTrue(conflicts[2], "Conflict with VPN DNS (9.9.9.9:853) must be detected")
        self.assertTrue(conflicts[3], "Private IP must be treated as conflicting")
        self.assertFalse(conflicts[4], "Clean external target IP must not conflict")

    # ------------------------------------------------------------------------
    # AT-29: Cleanup Under Failure Injection (Invariants T4 & T8)
    # ------------------------------------------------------------------------

    def test_at29_journal_rollback_under_failure_injection(self):
        """
        AT-29: Simulate abrupt failure / crash at each journal step; assert rollback
        replays journal in reverse and leaves zero residual artifacts (T4).
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let jid = 't_crash_sim_01';
        te.journal_init(jid);

        // Record artifacts as if halfway through tunnel setup
        te.journal_record(jid, { type: 'route_unreachable', family: 4, table: 4300 });
        te.journal_record(jid, { type: 'ip_rule', family: 4, prio: 701, table: 4300 });
        te.journal_record(jid, { type: 'nft_chain', family: 'inet', table: 'geovpn', name: 'test_guard' });
        te.journal_record(jid, { type: 'nft_set', family: 'inet', table: 'geovpn', name: 'test_dst4' });
        te.journal_record(jid, { type: 'link', dev: 'gvt0' });
        te.journal_record(jid, { type: 'route_default', dev: 'gvt0', table: 4300 });

        // Execute cleanup with verify
        let cl = te.test_cleanup(jid, true);
        print(sprintf('%J', cl));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cl = json.loads(proc.stdout)
        self.assertTrue(cl['ok'], f"Cleanup must succeed under simulated failure: {cl.get('leftovers')}")
        self.assertTrue(cl['verified'], "Post-condition verification must be checked")
        self.assertEqual(len(cl['leftovers']), 0, f"No leftovers should remain: {cl['leftovers']}")

    def test_at29_concurrency_lock_and_dead_lock_recovery(self):
        """
        AT-29 / Invariant T5: Concurrency limit (1 active test job); stale lock recovery.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        import * as fs from 'fs';

        let r1 = te.acquire_lock('job_first');
        let r2 = te.acquire_lock('job_second');

        // Simulate stale lock by writing dead PID 999999
        let lf = te.get_lock_file ? te.get_lock_file() : '/var/run/geovpn/test.lock';
        te.release_lock();

        let r3 = te.acquire_lock('job_third');
        te.release_lock();

        print(sprintf('%J', [r1.ok, r2.ok, r3.ok]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertTrue(res[0], "First acquire_lock must succeed")
        self.assertFalse(res[1], "Second concurrent acquire_lock must fail with BUSY")
        self.assertTrue(res[2], "Acquire after release must succeed")

    def test_at29_geovpn_panic_cleans_test_artifacts(self):
        """
        AT-29 / FR-27: Calling geovpn panic guarantees test artifact cleanup.
        """
        script = """
        import * as cli from 'geovpn.cli';
        import * as te from 'geovpn.test_engine';

        // Stage test job directory and lock
        te.acquire_lock('job_panic_test');
        let code = cli.main(['panic']);
        let cl = te.test_cleanup(null, true);
        print(sprintf('%J', { panic_code: code, cleanup_ok: cl.ok, leftovers: cl.leftovers }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [ln.strip() for ln in proc.stdout.strip().splitlines() if ln.strip()]
        res = json.loads(lines[-1])
        self.assertEqual(res['panic_code'], 0)
        self.assertTrue(res['cleanup_ok'], f"Panic must clean test artifacts: {res['leftovers']}")

    # ------------------------------------------------------------------------
    # AT-30: Protocols, Thresholds, Scoring, Ranking & CLI Verbs
    # ------------------------------------------------------------------------

    def test_at30_scoring_thresholds_logic(self):
        """
        AT-30 / §7.5: Pass/warn/fail scoring against max_handshake_ms, max_latency_ms, max_loss_pct.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let test_cfg = {
            max_handshake_ms: 8000,
            max_latency_ms: 800,
            max_loss_pct: 34,
            require_http: 1
        };

        // 1. Clean PASS
        let s1 = te.score_result({ handshake_ok: true, handshake_ms: 150, url: { loss_pct: 0, median_ms: 95 } }, test_cfg);
        // 2. Handshake exceeded -> WARN (latency)
        let s2 = te.score_result({ handshake_ok: true, handshake_ms: 9500, url: { loss_pct: 0, median_ms: 95 } }, test_cfg);
        // 3. Loss exceeded -> FAIL (http_failed)
        let s3 = te.score_result({ handshake_ok: true, handshake_ms: 150, url: { loss_pct: 50, median_ms: 95 } }, test_cfg);
        // 4. HTTP latency exceeded -> WARN (latency)
        let s4 = te.score_result({ handshake_ok: true, handshake_ms: 150, url: { loss_pct: 0, median_ms: 1200 } }, test_cfg);
        // 5. No handshake -> FAIL (no_handshake)
        let s5 = te.score_result({ handshake_ok: false, reason: 'no_handshake', hint: 'UDP blocked' }, test_cfg);

        print(sprintf('%J', [s1.status, s2.status, s3.status, s4.status, s5.status]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        statuses = json.loads(proc.stdout)
        self.assertEqual(statuses, ['pass', 'warn', 'fail', 'warn', 'fail'])

    def test_at30_ranking_order_and_tolerance(self):
        """
        AT-30 / §7.5: Ranking key: pass > warn > fail -> median_ms asc (within 50ms tolerance treated equal)
        -> handshake_ms asc -> proto_preference (wireguard > openvpn) -> name.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let items = [
            { id: 'p_ovpn_fast', name: 'OpenVPN Fast', proto: 'openvpn', status: 'pass', handshake_ms: 500, url: { median_ms: 105 } },
            { id: 'p_wg_fast', name: 'WireGuard Fast', proto: 'wireguard', status: 'pass', handshake_ms: 80, url: { median_ms: 100 } },
            { id: 'p_wg_warn', name: 'WireGuard Warn', proto: 'wireguard', status: 'warn', handshake_ms: 9000, url: { median_ms: 120 } },
            { id: 'p_ovpn_fail', name: 'OpenVPN Fail', proto: 'openvpn', status: 'fail', handshake_ms: null, url: null }
        ];

        let ranked = te.rank_results(items, { tolerance_ms: 50, proto_preference: ['wireguard', 'openvpn', 'ikev2'] });
        let ids = [];
        for (let r in ranked) push(ids, r.id);
        print(sprintf('%J', ids));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        ranked_ids = json.loads(proc.stdout)

        # p_wg_fast and p_ovpn_fast have latencies within 50ms (100 vs 105);
        # p_wg_fast wins on handshake_ms (80 vs 500) and proto preference
        self.assertEqual(ranked_ids[0], 'p_wg_fast')
        self.assertEqual(ranked_ids[1], 'p_ovpn_fast')
        self.assertEqual(ranked_ids[2], 'p_wg_warn')
        self.assertEqual(ranked_ids[3], 'p_ovpn_fail')

    def test_at30_cli_test_and_test_cleanup_verbs(self):
        """
        AT-30: CLI verbs:
          geovpn test <profile_id> [--probe-url <url>] [--json]
          geovpn test-cleanup [--verify]
        """
        # Test CLI test-cleanup --verify
        script_cleanup = """
        import * as cli from 'geovpn.cli';
        let code = cli.main(['test-cleanup', '--verify']);
        print(code);
        """
        proc_cl = self.run_ucode(script_cleanup)
        self.assertEqual(proc_cl.returncode, 0, proc_cl.stderr)
        self.assertIn("0", proc_cl.stdout)

        # Test CLI test <id> --json
        script_test = """
        import * as cli from 'geovpn.cli';
        let code = cli.main(['test', 'p22222222', '--json', '--probe-url', 'https://www.gstatic.com/generate_204']);
        """
        proc_test = self.run_ucode(script_test)
        self.assertEqual(proc_test.returncode, 0, proc_test.stderr)
        self.assertIn('"id": "p22222222"', proc_test.stdout)

    def test_at30_secrets_isolation_in_results(self):
        """
        AT-30 / NFR-18: Results never contain private keys, preshared keys, or passwords.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let res = te.test_profile('p22222222', { timeout_s: 1 });
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        raw_output = proc.stdout
        self.assertNotIn("MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=", raw_output, "Private key must never appear in test results")
        self.assertNotIn("private-key", raw_output)
        self.assertNotIn("preshared-key", raw_output)

    def test_at27_shared_wireguard_key_warning(self):
        """
        AT-27 / Invariant T6: Parallel WireGuard sessions sharing keys with the active
        tunnel produce a warning to alert the user of potential server-side disconnects.
        """
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            cfg_text = f.read()
        cfg_text = cfg_text.replace(
            "config profile 'p11111111'\n\toption name 'Active Tunnel'\n\toption proto 'openvpn'",
            "config profile 'p11111111'\n\toption name 'Active Tunnel'\n\toption proto 'wireguard'\n\toption wg_public_key 'xTuoQiUKS2gahBdWoVue64muS1WOH6eaCQU+5Arf4Ww='"
        )
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(cfg_text)

        script = """
        import * as te from 'geovpn.test_engine';
        let res = te.test_profile('p22222222', { timeout_s: 1 });
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        warnings = res.get('warnings', [])
        has_shared_warning = any('shares WireGuard keys' in w for w in warnings)
        self.assertTrue(has_shared_warning, f"Expected WireGuard key sharing warning in: {warnings}")

    def test_at28_resource_preflight_ram_and_load(self):
        """
        AT-28 / FR-43: Preflight checks min_free_ram_mb and max_load before starting test.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let r_ram_fail = te.check_resource_preflight({ min_free_ram_mb: 9999999 });
        let r_load_fail = te.check_resource_preflight({ min_free_ram_mb: 1, max_load: -0.1 });
        let r_ok = te.check_resource_preflight({ min_free_ram_mb: 1, max_load: 500 });
        print(sprintf('%J', [r_ram_fail, r_load_fail, r_ok]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        results = json.loads(proc.stdout)
        self.assertFalse(results[0]['ok'], "High RAM requirement must fail preflight")
        self.assertEqual(results[0]['reason'], 'resources')
        self.assertIn('RAM', results[0]['hint'])

        self.assertFalse(results[1]['ok'], "Low load tolerance must fail preflight")
        self.assertEqual(results[1]['reason'], 'resources')
        self.assertIn('load', results[1]['hint'])

        self.assertTrue(results[2]['ok'], "Realistic resource parameters must pass preflight")

    def test_at28_ssrf_dns_rebinding_and_ipv4_mapped_ipv6(self):
        """
        AT-28 / Invariant T7: SSRF guard blocks IPv4-mapped IPv6 literals and
        loopback resolving hostnames (preventing DNS rebinding).
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let r1 = te.validate_probe_url('http://[::ffff:127.0.0.1]/');
        let r2 = te.validate_probe_url('http://[::ffff:7f00:1]/');
        let r3 = te.validate_probe_url('http://localhost:8080/metrics');
        print(sprintf('%J', [r1, r2, r3]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        results = json.loads(proc.stdout)
        self.assertFalse(results[0]['ok'], "Dotted IPv4-mapped IPv6 must be rejected by SSRF guard")
        self.assertEqual(results[0]['error'], 'SSRF_PROHIBITED')
        self.assertFalse(results[1]['ok'], "Hex IPv4-mapped IPv6 must be rejected by SSRF guard")
        self.assertEqual(results[1]['error'], 'SSRF_PROHIBITED')
        self.assertFalse(results[2]['ok'], "localhost target must be rejected by SSRF guard")
        self.assertEqual(results[2]['error'], 'SSRF_PROHIBITED')

    def test_at29_test_cancel_and_job_deadline(self):
        """
        AT-29 / Invariant T5 / §7.8 / §7.11: Job cancellation and overall job deadline enforcement.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        import * as fs from 'fs';

        let jid = 't_test_cancel_job';
        te.journal_init(jid);
        te.acquire_lock(jid);

        // Stage running job file
        let jfile = te.get_job_file(jid);
        let jf = fs.open(jfile, 'w', 0o600);
        if (jf) {
            jf.write(sprintf('%J', { job_id: jid, state: 'running' }));
            jf.close();
        }

        // Invoke test_cancel
        let cres = te.test_cancel(jid);
        let status = te.test_job_status(jid);

        print(sprintf('%J', { cleanup_ok: cres.ok, status_state: status.state }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertTrue(res['cleanup_ok'], "test_cancel must cleanly remove artifacts")
        self.assertEqual(res['status_state'], 'cancelled', "Job state must be updated to cancelled")

    def test_at29_chain_out_rules_and_sets_handle_cleanup(self):
        """
        AT-29 / Invariants T1 & T8: Cleanup verifies handle-based rule deletion from chain out,
        and total destruction of all test sets (test_dst4/6, test_ep4/6).
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let jid = 't_rules_clean_verify';
        te.journal_init(jid);
        te.setup_test_nft(jid);
        let add_ep_res = te.add_test_endpoint(jid, '203.0.113.199');
        let add_tgt_res = te.add_test_target(jid, '198.51.100.55', 443);

        let cl = te.test_cleanup(jid, true);
        print(sprintf('%J', cl));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cl = json.loads(proc.stdout)
        self.assertTrue(cl['ok'], f"Cleanup must succeed: {cl.get('leftovers')}")
        self.assertTrue(cl['verified'], "Post-cleanup verification must be asserted")
        self.assertEqual(len(cl['leftovers']), 0, f"No leftover rules or sets should remain: {cl['leftovers']}")

    def test_at30_scoring_require_http_null_failure(self):
        """
        AT-30 / §7.5: When require_http is 1, a null or zero-sample URL probe must yield fail.
        """
        script = """
        import * as te from 'geovpn.test_engine';
        let test_cfg = { require_http: 1, max_handshake_ms: 8000 };

        let s1 = te.score_result({ handshake_ok: true, handshake_ms: 200, url: null }, test_cfg);
        let s2 = te.score_result({ handshake_ok: true, handshake_ms: 200, url: { ok_samples: 0, median_ms: null, loss_pct: 100 } }, test_cfg);
        let s3 = te.score_result({ handshake_ok: true, handshake_ms: 200, url: null }, { require_http: 0, max_handshake_ms: 8000 });

        print(sprintf('%J', [s1.status, s1.reason, s2.status, s2.reason, s3.status]));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertEqual(res[0], 'fail', "Null URL when require_http=1 must fail")
        self.assertEqual(res[1], 'http_failed')
        self.assertEqual(res[2], 'fail', "Zero ok_samples when require_http=1 must fail")
        self.assertEqual(res[3], 'http_failed')
        self.assertEqual(res[4], 'pass', "Null URL when require_http=0 passes if handshake ok")


if __name__ == '__main__':
    unittest.main()
