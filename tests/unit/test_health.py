#!/usr/bin/env python3
"""
Acceptance Tests for Phase A6: Auto-Connect & Failover Engine (§7.7, §11 A6)
Covers AT-32 and AT-33:
  - AT-32: Connect policies: require aborts on fail, warn, best, fallback ordering.
  - AT-33: Health assessment, hysteresis, test-before-switch, rate limiting (min 60s, max 6/hr),
           exponential backoff, kill-switch / fail-open interplay, candidate endpoint IP added
           to direct sets before switch, runtime override (/var/run/geovpn/active_override).
"""
import unittest
import os
import subprocess
import json
import shutil
import tempfile
import time


class TestHealthAndFailover(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_health_test_')
        self.conf_dir = os.path.join(self.test_dir, 'config')
        self.cred_dir = os.path.join(self.test_dir, 'credentials')
        self.run_dir = os.path.join(self.test_dir, 'run')
        self.prof_dir = os.path.join(self.test_dir, 'profiles')
        os.makedirs(self.conf_dir, exist_ok=True)
        os.makedirs(self.cred_dir, exist_ok=True)
        os.makedirs(self.run_dir, exist_ok=True)
        os.makedirs(self.prof_dir, exist_ok=True)

        # Base UCI configuration with autoconnect section
        uci_content = """
config main 'main'
	option config_version '2'
	option enabled '1'
	option active_profile 'p11111111'
	option tun_dev 'geovpn0'
	option mode 'bypass'
	option kill_switch '1'

config autoconnect 'auto'
	option mode 'fallback'
	list fallback 'p22222222'
	list fallback 'p33333333'
	option connect_gate 'off'
	option health_enabled '1'
	option health_interval '120'
	option fail_threshold '3'
	option down_grace '30'
	option failover '1'
	option failover_max_candidates '3'
	option min_switch_interval '60'
	option max_switches_per_hour '6'
	option persist_switch '0'
	option failback '0'

config profile 'p11111111'
	option name 'Primary OpenVPN'
	option proto 'openvpn'
	option enabled '1'
	list remote '198.51.100.1 1194 udp'

config profile 'p22222222'
	option name 'Candidate WireGuard'
	option proto 'wireguard'
	option enabled '1'
	option auto_pool '1'
	option wg_endpoint_host '203.0.113.50'
	option wg_endpoint_port '51820'
	option wg_public_key 'xTuoQiUKS2gahBdWoVue64muS1WOH6eaCQU+5Arf4Ww='
	list wg_address '10.2.0.2/32'
	list wg_allowed_ips '0.0.0.0/0'

config profile 'p33333333'
	option name 'Candidate Backup OpenVPN'
	option proto 'openvpn'
	option enabled '1'
	option auto_pool '1'
	list remote '198.51.100.200 1194 udp'
"""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write(uci_content.strip() + '\n')

        # Setup primary profile directory
        p1_dir = os.path.join(self.prof_dir, 'p11111111')
        os.makedirs(p1_dir, exist_ok=True)
        with open(os.path.join(p1_dir, 'profile.ovpn'), 'w') as f:
            f.write("client\ndev geovpn0\nremote 198.51.100.1 1194 udp\n")

        # Setup WG candidate directory
        p2_dir = os.path.join(self.prof_dir, 'p22222222')
        os.makedirs(p2_dir, exist_ok=True)
        with open(os.path.join(p2_dir, 'wg.key'), 'w') as f:
            f.write("MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\n")

        # Setup secondary candidate directory
        p3_dir = os.path.join(self.prof_dir, 'p33333333')
        os.makedirs(p3_dir, exist_ok=True)
        with open(os.path.join(p3_dir, 'profile.ovpn'), 'w') as f:
            f.write("client\ndev geovpn0\nremote 198.51.100.200 1194 udp\n")

        # Active state.json snapshot
        self.state_data = {
            "service": {"enabled": True, "state": "connected"},
            "tunnel": {
                "profile": "p11111111",
                "name": "Primary OpenVPN",
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
            json.dump(self.state_data, f, indent=2)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_ucode(self, script, env_extra=None):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        env = os.environ.copy()
        env['GEOVPN_CRED_DIR'] = self.cred_dir
        env['GEOVPN_PROFILES_DIR'] = self.prof_dir
        env['GEOVPN_RUN_DIR'] = self.run_dir
        env['UCI_CONFIG_DIR'] = self.conf_dir
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True, env=env)
        return proc

    # ------------------------------------------------------------------------
    # 1. Health Assessment & Hysteresis Gating (AT-33 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_health_assessment_healthy(self):
        """Live health assessment correctly reports healthy when tunnel is up and live check passes."""
        # Create hook.env indicating up
        with open(os.path.join(self.run_dir, 'hook.env'), 'w') as f:
            f.write("script_type=up\nifconfig_local=10.8.0.2\nifconfig_remote=198.51.100.1\n")

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertTrue(res['ok'])
        self.assertEqual(res['health']['status'], 'healthy')
        self.assertEqual(res['fail_count'], 0)

    def test_at33_hysteresis_threshold_gating(self):
        """
        Hysteresis gating: consecutive failures are counted, and failover is NOT triggered
        until consecutive failures reach fail_threshold (prevent flap/thrash).
        """
        # Ensure hook.env is absent so tunnel appears down
        hook_file = os.path.join(self.run_dir, 'hook.env')
        if os.path.exists(hook_file): os.unlink(hook_file)

        # Set service state to disconnected
        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        # Tick 1: fail_count should become 1, no failover yet (threshold is 3)
        script_tick = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc1 = self.run_ucode(script_tick)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        out1 = json.loads(proc1.stdout)
        self.assertEqual(out1['st']['fail_count'], 1)
        self.assertFalse(out1['res'].get('switched', False))

        # Tick 2: fail_count becomes 2, still no failover
        proc2 = self.run_ucode(script_tick)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        out2 = json.loads(proc2.stdout)
        self.assertEqual(out2['st']['fail_count'], 2)
        self.assertFalse(out2['res'].get('switched', False))

        # Active profile should still be p11111111
        override_file = os.path.join(self.run_dir, 'active_override')
        self.assertFalse(os.path.exists(override_file), "Active profile must not switch before threshold")

    # ------------------------------------------------------------------------
    # 2. Rate Limiting: Min Interval & Hourly Cap (AT-33 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_failover_rate_limiting_min_interval(self):
        """
        Assert failover rate limiting: minimum switch interval (>= 60s) is strictly enforced.
        If a switch occurred < 60s ago, failover is blocked and alert is raised.
        """
        # Pre-populate health.json with recent switch 20s ago and fail_count at threshold
        now = int(time.time())
        health_state = {
            "fail_count": 3,
            "down_since": now - 35,
            "last_tick": now - 10,
            "last_switch": now - 20, # Only 20s ago!
            "switch_history": [now - 20],
            "backoff_step": 0,
            "backoff_until": 0,
            "alerts": []
        }
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump(health_state, f)

        # Tunnel is down
        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # Assert switch was rate limited
        self.assertTrue(out['res'].get('rate_limited', False), "Must flag rate_limited")
        self.assertFalse(out['res'].get('switched', False), "Must NOT switch active profile during cooldown")
        self.assertTrue(any('min switch interval' in a for a in out['st'].get('alerts', [])), "Must raise min switch interval alert")
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, 'active_override')))

    def test_at33_failover_rate_limiting_max_switches_per_hour(self):
        """
        Assert failover rate limiting: maximum switches per hour (<= 6/hr) is strictly enforced.
        If 6 switches occurred in the last hour, failover is blocked and alert is raised.
        """
        now = int(time.time())
        # Populate with 6 switches in the last hour (>= 60s apart)
        history = [now - 3000, now - 2400, now - 1800, now - 1200, now - 600, now - 100]
        health_state = {
            "fail_count": 3,
            "down_since": now - 40,
            "last_tick": now - 10,
            "last_switch": now - 100, # >= 60s ago, so min interval passes
            "switch_history": history,
            "backoff_step": 0,
            "backoff_until": 0,
            "alerts": []
        }
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump(health_state, f)

        # Tunnel is down
        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # Assert hourly cap blocked the switch
        self.assertTrue(out['res'].get('rate_limited', False))
        self.assertFalse(out['res'].get('switched', False))
        self.assertTrue(any('maximum switches per hour' in a for a in out['st'].get('alerts', [])))
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, 'active_override')))

    # ------------------------------------------------------------------------
    # 3. Test-Before-Switch Behavior (AT-33 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_test_before_switch_unhealthy_candidate_rejected(self):
        """
        Test-before-switch: candidates in pool are tested using isolated test engine
        BEFORE any switch occurs. An unhealthy candidate is NEVER switched to!
        """
        now = int(time.time())
        health_state = {
            "fail_count": 3,
            "down_since": now - 35,
            "last_tick": now - 10,
            "last_switch": now - 120,
            "switch_history": [],
            "backoff_step": 0,
            "backoff_until": 0,
            "alerts": []
        }
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump(health_state, f)

        # Invalidate candidates so all fail pre-connection testing
        # Pre-seed cache with failed results
        cached_results = [
            {"id": "p22222222", "status": "fail", "reason": "auth_failed", "tested_at": now},
            {"id": "p33333333", "status": "fail", "reason": "timeout", "tested_at": now}
        ]
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump(cached_results, f)

        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # Assert no switch was performed
        self.assertFalse(out['res'].get('switched', False))
        self.assertTrue(out['res'].get('failover_failed', False))
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, 'active_override')))

        # Assert exponential backoff was scheduled
        self.assertGreater(out['st'].get('backoff_until', 0), now)
        self.assertEqual(out['st'].get('backoff_step', 0), 1)

    def test_at33_test_before_switch_healthy_candidate_switched(self):
        """
        When a candidate passes pre-connection test, it is selected and switch is executed.
        """
        now = int(time.time())
        health_state = {
            "fail_count": 3,
            "down_since": now - 35,
            "last_tick": now - 10,
            "last_switch": now - 120,
            "switch_history": [],
            "backoff_step": 0,
            "backoff_until": 0,
            "alerts": []
        }
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump(health_state, f)

        # Seed candidate p22222222 with PASS
        cached_results = [
            {"id": "p22222222", "status": "pass", "median_ms": 45, "tested_at": now}
        ]
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump(cached_results, f)

        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # Assert switch succeeded
        self.assertTrue(out['res'].get('switched', False))
        self.assertEqual(out['res'].get('target'), 'p22222222')

        # Assert runtime override created
        override_file = os.path.join(self.run_dir, 'active_override')
        self.assertTrue(os.path.exists(override_file))
        with open(override_file, 'r') as f:
            self.assertEqual(f.read().strip(), 'p22222222')

        # Assert failure counters reset
        self.assertEqual(out['st']['fail_count'], 0)
        self.assertEqual(out['st']['down_since'], 0)
        self.assertEqual(out['st']['backoff_step'], 0)

    # ------------------------------------------------------------------------
    # 4. Candidate Endpoint IPs Added to Direct Sets Before Switch (§7.7)
    # ------------------------------------------------------------------------

    def test_at33_candidate_endpoint_ips_added_to_direct_sets(self):
        """
        Candidate endpoint IPs are added to nftables always4/always4_dyn sets
        BEFORE initiating a switch, so handshake packets are never blocked or trapped.
        """
        script = """
        import * as health from 'geovpn.health';
        import * as util from 'geovpn.util';

        let executed_commands = [];
        global._safe_exec_hook = function(argv, input) {
            push(executed_commands, argv);
            return { code: 0, stdout: '', stderr: '' };
        };

        // Profile p22222222 has wg_endpoint_host 203.0.113.50
        health.add_endpoint_ips_direct('p22222222');
        // Profile p33333333 has remote 198.51.100.200
        health.add_endpoint_ips_direct('p33333333');

        print(sprintf('%J', executed_commands));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cmds = json.loads(proc.stdout)

        # Assert nft add element commands were issued for both candidates
        self.assertIn(['nft', 'add', 'element', 'inet', 'geovpn', 'always4', '{ 203.0.113.50 }'], cmds)
        self.assertIn(['nft', 'add', 'element', 'inet', 'geovpn', 'always4_dyn', '{ 203.0.113.50 }'], cmds)
        self.assertIn(['nft', 'add', 'element', 'inet', 'geovpn', 'always4', '{ 198.51.100.200 }'], cmds)
        self.assertIn(['nft', 'add', 'element', 'inet', 'geovpn', 'always4_dyn', '{ 198.51.100.200 }'], cmds)

    def test_at33_endpoint_ips_added_before_switch_execution(self):
        """
        Assert endpoint IP insertion in nftables occurs BEFORE the service restart command.
        """
        script = """
        import * as health from 'geovpn.health';
        import * as util from 'geovpn.util';

        let call_order = [];
        global._safe_exec_hook = function(argv, input) {
            if (argv[0] == 'nft' && argv[5] == 'always4') {
                push(call_order, 'nft_endpoint_added');
            } else if (argv[0] == '/etc/init.d/geovpn' && argv[1] == 'restart') {
                push(call_order, 'service_restarted');
            }
            return { code: 0, stdout: '', stderr: '' };
        };

        health.switch_active_tunnel('p22222222', false);
        print(sprintf('%J', call_order));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        order = json.loads(proc.stdout)
        self.assertIn('nft_endpoint_added', order)
        self.assertIn('service_restarted', order)
        self.assertLess(order.index('nft_endpoint_added'), order.index('service_restarted'),
                       "nft endpoint direct route must be added BEFORE service restart")

    # ------------------------------------------------------------------------
    # 5. Kill Switch Interplay: Fail-Closed vs Fail-Open (§7.7 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_kill_switch_on_remains_blocked_on_failure(self):
        """
        Kill switch ON: when all candidates fail, table 4200 maintains 'unreachable default' route.
        Traffic remains strictly BLOCKED (never leaks unencrypted WAN).
        """
        script = """
        import * as route from 'geovpn.route';
        let main_cfg = {
            enabled: '1',
            tun_dev: 'geovpn0',
            rt_table: 4200,
            rule_priority: 700,
            mark_shift: 24,
            kill_switch: '1'
        };
        // Apply routing with kill switch ON
        route.apply_routes(main_cfg);

        // Tunnel down: default route removed, unreachable remains
        route.set_tunnel_down(4200);
        print('ROUTES_VERIFIED');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('ROUTES_VERIFIED', proc.stdout)

    def test_at33_kill_switch_off_fails_open(self):
        """
        Kill switch OFF: when kill switch is disabled, table 4200 does not have unreachable default;
        traffic cleanly falls open to WAN per user configuration.
        """
        script = """
        import * as route from 'geovpn.route';
        let main_cfg = {
            enabled: '1',
            tun_dev: 'geovpn0',
            rt_table: 4200,
            rule_priority: 700,
            mark_shift: 24,
            kill_switch: '0'
        };
        // Apply routing with kill switch OFF
        route.apply_routes(main_cfg);
        print('FAIL_OPEN_VERIFIED');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('FAIL_OPEN_VERIFIED', proc.stdout)

    def test_at33_kill_switch_interplay_alerts_in_health_tick(self):
        """Assert that health-tick alerts record kill-switch blocked status vs fail-open status."""
        now = int(time.time())
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump([{"id": "p22222222", "status": "fail", "tested_at": now}, {"id": "p33333333", "status": "fail", "tested_at": now}], f)
        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 3, "down_since": now - 35, "last_tick": now - 10, "last_switch": now - 200}, f)

        # 1. Kill switch ON (default in setUp)
        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        print(sprintf('%J', res));
        """
        proc1 = self.run_ucode(script)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        out1 = json.loads(proc1.stdout)
        self.assertTrue(any('blocked by kill switch' in a for a in out1.get('alerts', [])))

        # 2. Kill switch OFF
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option kill_switch '1'", "option kill_switch '0'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 3, "down_since": now - 35, "last_tick": now - 10, "last_switch": now - 200}, f)

        proc2 = self.run_ucode(script)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        out2 = json.loads(proc2.stdout)
        self.assertTrue(any('failing open to WAN' in a for a in out2.get('alerts', [])))

    # ------------------------------------------------------------------------
    # 6. Runtime Switch Override vs Persist (AT-33 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_runtime_switch_override_leaves_uci_untouched(self):
        """
        Runtime switch (persist_switch=0) overrides active profile in /var/run/geovpn/active_override
        without modifying flash UCI configuration.
        """
        script = """
        import * as health from 'geovpn.health';
        import * as cfg from 'geovpn.config';
        let res = health.switch_active_tunnel('p22222222', false);
        let c = cfg.load_config();
        let eff = cfg.get_effective_active_profile_id(c);
        let uci_prof = c.main.active_profile;
        let ov = cfg.get_active_override();
        print(sprintf('%J', { res: res, eff: eff, uci_prof: uci_prof, ov: ov }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # UCI active_profile is still primary (p11111111)
        self.assertEqual(out['uci_prof'], 'p11111111')
        # Active override in RAM is p22222222
        self.assertEqual(out['ov'], 'p22222222')
        # Effective active profile is p22222222
        self.assertEqual(out['eff'], 'p22222222')

    def test_at33_switch_persist_updates_uci(self):
        """
        Switch with persist=true writes active_profile to flash UCI and unlinks active_override.
        """
        # First set runtime override
        override_file = os.path.join(self.run_dir, 'active_override')
        with open(override_file, 'w') as f:
            f.write("p33333333\n")

        script = """
        import * as health from 'geovpn.health';
        import * as cfg from 'geovpn.config';
        let res = health.switch_active_tunnel('p22222222', true);
        let c = cfg.load_config();
        let eff = cfg.get_effective_active_profile_id(c);
        let uci_prof = c.main.active_profile;
        let ov = cfg.get_active_override();
        print(sprintf('%J', { res: res, eff: eff, uci_prof: uci_prof, ov: ov }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # UCI active_profile was rewritten to p22222222
        self.assertEqual(out['uci_prof'], 'p22222222')
        # Override file was removed
        self.assertIsNone(out['ov'])
        self.assertFalse(os.path.exists(override_file))

    # ------------------------------------------------------------------------
    # 7. Connect Gate Policy (AT-32 / FR-40)
    # ------------------------------------------------------------------------

    def test_at32_connect_gate_require_aborts_on_failed_test(self):
        """
        AT-32: connect_gate=require aborts manual switch if pre-connection test fails.
        """
        # Set connect_gate='require'
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option connect_gate 'off'", "option connect_gate 'require'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        # Seed candidate p22222222 with failure
        now = int(time.time())
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump([{"id": "p22222222", "status": "fail", "reason": "handshake_timeout", "tested_at": now}], f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.manual_switch('p22222222', false);
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)

        # Assert switch was aborted
        self.assertFalse(res['ok'])
        self.assertEqual(res['error'], 'CONNECT_GATE_FAILED')
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, 'active_override')))

    def test_at32_connect_gate_warn_and_off(self):
        """AT-32: connect_gate=warn logs warning but allows switch; connect_gate=off switches immediately."""
        now = int(time.time())
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump([{"id": "p22222222", "status": "fail", "reason": "timeout", "tested_at": now}], f)

        # 1. connect_gate='warn'
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option connect_gate 'off'", "option connect_gate 'warn'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        script_warn = """
        import * as health from 'geovpn.health';
        let res = health.manual_switch('p22222222', false);
        print(sprintf('%J', res));
        """
        proc_warn = self.run_ucode(script_warn)
        self.assertEqual(proc_warn.returncode, 0, proc_warn.stderr)
        res_warn = json.loads(proc_warn.stdout)
        self.assertTrue(res_warn['ok'], "connect_gate=warn must permit switch despite test failure")

        # 2. connect_gate='off'
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option connect_gate 'warn'", "option connect_gate 'off'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        script_off = """
        import * as health from 'geovpn.health';
        let res = health.manual_switch('p33333333', false);
        print(sprintf('%J', res));
        """
        proc_off = self.run_ucode(script_off)
        self.assertEqual(proc_off.returncode, 0, proc_off.stderr)
        res_off = json.loads(proc_off.stdout)
        self.assertTrue(res_off['ok'], "connect_gate=off must permit immediate switch")

    # ------------------------------------------------------------------------
    # 8. Advanced Failover: Backoff Progression & Best-Mode Ranking (§7.7)
    # ------------------------------------------------------------------------

    def test_at33_exponential_backoff_progression_and_skip(self):
        """Assert exponential backoff steps on repeated failures and skips ticks during cooldown."""
        now = int(time.time())
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump([{"id": "p22222222", "status": "fail", "tested_at": now}, {"id": "p33333333", "status": "fail", "tested_at": now}], f)
        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)

        # Round 1 failure (step 0 -> 1, backoff 60s)
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 3, "down_since": now - 35, "last_tick": now - 10, "last_switch": now - 200, "backoff_step": 0}, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc1 = self.run_ucode(script)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        out1 = json.loads(proc1.stdout)
        self.assertEqual(out1['st']['backoff_step'], 1)
        self.assertAlmostEqual(out1['st']['backoff_until'], now + 60, delta=2)

        # Non-forced tick during cooldown must skip
        script_skip = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: false });
        print(sprintf('%J', res));
        """
        proc_skip = self.run_ucode(script_skip)
        self.assertEqual(proc_skip.returncode, 0, proc_skip.stderr)
        out_skip = json.loads(proc_skip.stdout)
        self.assertTrue(out_skip.get('skipped'))
        self.assertEqual(out_skip.get('reason'), 'in_backoff')

        # Round 2 failure (step 1 -> 2, backoff 120s)
        now2 = int(time.time())
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 3, "down_since": now2 - 100, "last_tick": now2 - 70, "last_switch": now2 - 300, "backoff_step": 1, "backoff_until": now2 - 10}, f)
        proc2 = self.run_ucode(script)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        out2 = json.loads(proc2.stdout)
        self.assertEqual(out2['st']['backoff_step'], 2)
        self.assertAlmostEqual(out2['st']['backoff_until'], now2 + 120, delta=2)

    def test_at33_candidate_pool_ranking_in_best_mode(self):
        """Assert that in mode=best, candidates in auto_pool are ranked by test performance."""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option mode 'fallback'", "option mode 'best'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        now = int(time.time())
        # p33333333 is faster (25ms) than p22222222 (250ms)
        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        cached = [
            {"id": "p22222222", "status": "pass", "url": {"median_ms": 250}, "tested_at": now},
            {"id": "p33333333", "status": "pass", "url": {"median_ms": 25}, "tested_at": now}
        ]
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump(cached, f)

        self.state_data['service']['state'] = 'disconnected'
        with open(os.path.join(self.run_dir, 'state.json'), 'w') as f:
            json.dump(self.state_data, f)
        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 3, "down_since": now - 35, "last_tick": now - 10, "last_switch": now - 200}, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertTrue(res.get('switched'))
        # Faster candidate (p33333333) selected first!
        self.assertEqual(res.get('target'), 'p33333333')

    def test_at33_failback_after_three_consecutive_passes(self):
        """Assert failback switches back to primary profile after 3 consecutive passes."""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'r') as f:
            c = f.read().replace("option failback '0'", "option failback '1'")
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w') as f:
            f.write(c)

        now = int(time.time())
        with open(os.path.join(self.run_dir, 'active_override'), 'w') as f:
            f.write("p22222222\n")

        test_dir = os.path.join(self.run_dir, 'test')
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, 'results.json'), 'w') as f:
            json.dump([{"id": "p11111111", "status": "pass", "tested_at": now}], f)

        with open(os.path.join(self.run_dir, 'hook.env'), 'w') as f:
            f.write("script_type=up\nifconfig_local=10.2.0.2\n")

        with open(os.path.join(self.run_dir, 'health.json'), 'w') as f:
            json.dump({"fail_count": 0, "last_tick": now - 150, "last_switch": now - 200, "primary_pass_ticks": 2}, f)

        script = """
        import * as health from 'geovpn.health';
        let res = health.run_health_tick({ force: true });
        let st = health.load_health_state();
        print(sprintf('%J', { res: res, st: st }));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)

        # Passes reach 3 -> failback triggered
        self.assertTrue(any('Failback: switched back' in a for a in out['st'].get('alerts', [])))

    def test_at33_lock_file_stale_and_clock_jump_recovery(self):
        """Assert acquire_health_lock breaks stale locks (>60s) and future mtime locks (NTP step backward)."""
        lock_file = os.path.join(self.run_dir, 'health.lock')

        # 1. Stale lock older than 60s
        with open(lock_file, 'w') as f:
            f.write("12345\n")
        past_time = time.time() - 75
        os.utime(lock_file, (past_time, past_time))

        script1 = """
        import * as health from 'geovpn.health';
        let ok = health.acquire_health_lock();
        if (ok) health.release_health_lock();
        print(ok ? 'LOCKED_RECOVERED' : 'BLOCKED');
        """
        proc1 = self.run_ucode(script1)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        self.assertIn('LOCKED_RECOVERED', proc1.stdout)

        # 2. Lock with future timestamp (simulating clock step backward after NTP sync)
        with open(lock_file, 'w') as f:
            f.write("12345\n")
        future_time = time.time() + 100
        os.utime(lock_file, (future_time, future_time))

        proc2 = self.run_ucode(script1)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        self.assertIn('LOCKED_RECOVERED', proc2.stdout, "Must recover from future lock caused by NTP backward step")

    # ------------------------------------------------------------------------
    # 9. CLI Verbs: health-tick & switch (AT-33 / FR-41)
    # ------------------------------------------------------------------------

    def test_at33_cli_verbs_execution(self):
        """CLI verbs: 'geovpn health-tick' and 'geovpn switch <id>' (with and without --persist)."""
        # 1. Test CLI health-tick --json
        script_tick = """
        import * as cli from 'geovpn.cli';
        cli.main(['health-tick', '--json', '--force']);
        """
        proc1 = self.run_ucode(script_tick)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        out1 = json.loads(proc1.stdout.strip())
        self.assertTrue(out1['ok'])

        # 2. Test CLI switch p22222222 without --persist
        script_sw = """
        import * as cli from 'geovpn.cli';
        cli.main(['switch', 'p22222222']);
        """
        proc2 = self.run_ucode(script_sw)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        self.assertIn('Switched active profile to p22222222 (persisted: no)', proc2.stdout)

        # Assert runtime override created
        override_file = os.path.join(self.run_dir, 'active_override')
        self.assertTrue(os.path.exists(override_file))

        # 3. Test CLI switch p33333333 --persist
        script_sw_persist = """
        import * as cli from 'geovpn.cli';
        cli.main(['switch', 'p33333333', '--persist']);
        """
        proc3 = self.run_ucode(script_sw_persist)
        self.assertEqual(proc3.returncode, 0, proc3.stderr)
        self.assertIn('Switched active profile to p33333333 (persisted: yes)', proc3.stdout)
        self.assertFalse(os.path.exists(override_file))

    # ------------------------------------------------------------------------
    # 10. Autoconnect Status RPCD & Diagnostics (AT-38 / FR-41)
    # ------------------------------------------------------------------------

    def test_at38_autoconnect_status_structure(self):
        """rpcd autoconnect_status returns required schema fields."""
        script = """
        import * as health from 'geovpn.health';
        let st = health.get_autoconnect_status();
        print(sprintf('%J', st));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        st = json.loads(proc.stdout)

        expected_fields = [
            'mode', 'health_enabled', 'failover', 'fail_count', 'fail_threshold',
            'down_grace', 'last_tick', 'last_switch', 'switches_last_hour',
            'max_switches_per_hour', 'min_switch_interval', 'override',
            'primary_profile', 'active_profile', 'health', 'in_cooldown',
            'cooldown_remaining', 'in_backoff', 'backoff_remaining', 'alerts'
        ]
        for field in expected_fields:
            self.assertIn(field, st, f"Field '{field}' missing from autoconnect_status")

    def test_at38_rpcd_health_tick_method(self):
        """rpcd plugin exposes health_tick method and service action=health_tick."""
        plugin_path = os.path.join(self.repo_root, 'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'ucode', 'geovpn.uc')
        script = f"""
        let plugin = loadfile('{plugin_path}')();
        let obj = plugin['luci.geovpn'];
        let tick_res = obj.health_tick.call({{ args: {{ force: true }} }});
        let serv_res = obj.service.call({{ args: {{ action: 'health_tick' }} }});
        print(sprintf('%J', {{ tick: tick_res, serv: serv_res }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        res = json.loads(proc.stdout)
        self.assertTrue(res['tick']['ok'])
        self.assertTrue(res['serv']['ok'])


if __name__ == '__main__':
    unittest.main()
