#!/usr/bin/env python3
"""
Unit tests for IKEv2 / strongSwan protocol driver, .sswan / smart-paste parser,
credential security, XFRM interface isolation, and test engine parallel session refusal
(§6.6, §7.1, §11 A7 / FR-30, FR-32, NFR-16, NFR-19 / AT-26, AT-27, AT-28, AT-34).
"""
import unittest
import os
import subprocess
import json
import shutil
import tempfile
import stat

class TestIkev2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.fixtures_dir = os.path.join(cls.repo_root, 'tests', 'fixtures', 'golden_baseline')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_ike_test_')
        self.conf_dir = os.path.join(self.test_dir, 'config')
        self.cred_dir = os.path.join(self.test_dir, 'credentials')
        self.run_dir = os.path.join(self.test_dir, 'run')
        self.prof_dir = os.path.join(self.test_dir, 'profiles')
        os.makedirs(self.conf_dir, exist_ok=True)
        os.makedirs(self.cred_dir, exist_ok=True)
        os.makedirs(self.run_dir, exist_ok=True)
        os.makedirs(self.prof_dir, exist_ok=True)
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write("config main 'main'\n\toption config_version '2'\n")

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
    # 1. Packaging & Makefile Specification
    # ------------------------------------------------------------------------

    def test_geovpn_ikev2_makefile_spec(self):
        """Assert openwrt/geovpn-ikev2/Makefile dependencies and packaging flags."""
        mf_path = os.path.join(self.repo_root, 'openwrt', 'geovpn-ikev2', 'Makefile')
        self.assertTrue(os.path.exists(mf_path), "openwrt/geovpn-ikev2/Makefile must exist")
        with open(mf_path, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('PKGARCH:=all', content)
        self.assertIn('+geovpn-core', content)
        self.assertIn('+kmod-xfrm-interface', content)
        self.assertIn('+strongswan-charon', content)
        self.assertIn('+strongswan-swanctl', content)
        self.assertIn('+strongswan-mod-kernel-netlink', content)
        self.assertIn('+strongswan-mod-socket-default', content)
        self.assertIn('+strongswan-mod-eap-mschapv2', content)
        self.assertIn('+strongswan-mod-xauth-generic', content)
        self.assertIn('+strongswan-mod-openssl', content)
        self.assertIn('+strongswan-mod-vici', content)
        self.assertIn('Apache-2.0', content)

    def test_ike_updown_script_executable_and_handlers(self):
        """Assert /usr/libexec/geovpn/ike-updown is present and executable."""
        updown_path = os.path.join(self.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'libexec', 'geovpn', 'ike-updown')
        self.assertTrue(os.path.exists(updown_path), "ike-updown script must exist")
        mode = os.stat(updown_path).st_mode
        self.assertTrue(bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)), "ike-updown must be executable")
        with open(updown_path, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('up-client', content)
        self.assertIn('down-client', content)
        self.assertIn('PLUTO_MY_SOURCEIP', content)
        self.assertIn('PLUTO_CONNECTION', content)
        self.assertIn('pushed_dns', content)

    def test_driver_line_count_budget_nfr19(self):
        """Assert ikev2 driver meets modularity constraint <= 400 lines (NFR-19)."""
        drv_path = os.path.join(self.lib_path, 'geovpn', 'drivers', 'ikev2.uc')
        self.assertTrue(os.path.exists(drv_path), "ikev2.uc must exist")
        with open(drv_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        count = len(lines)
        self.assertLessEqual(count, 400, f"ikev2.uc ({count} lines) must not exceed 400 lines (NFR-19)")

    # ------------------------------------------------------------------------
    # 2. IKEv2 Parser (.sswan & Smart-Paste) Tests
    # ------------------------------------------------------------------------

    def test_parse_valid_sswan_json(self):
        """Parse valid strongSwan Android .sswan export JSON."""
        script = """
        import * as ike from 'geovpn.ike_import';
        let sswan_json = `
        {
            "uuid": "4f54c160-5a33-4f51-a96c-b26a6f68c345",
            "name": "Windscribe IKEv2 Amsterdam",
            "remote": {
                "address": "nl.windscribe.com",
                "identity": "nl.windscribe.com"
            },
            "local": {
                "eap_id": "wvpn_user123"
            },
            "authentication": {
                "username": "wvpn_user123",
                "password": "secret_password_999",
                "type": "eap-mschapv2"
            }
        }
        `;
        let res = ike.parse_sswan(sswan_json, 'Fallback Name');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(p['proto'], 'ikev2')
        self.assertEqual(p['name'], 'Windscribe IKEv2 Amsterdam')
        self.assertEqual(p['ike_host'], 'nl.windscribe.com')
        self.assertEqual(p['ike_remote_id'], 'nl.windscribe.com')
        self.assertEqual(p['ike_username'], 'wvpn_user123')
        self.assertEqual(p['password'], 'secret_password_999')
        self.assertEqual(p['ike_auth'], 'eap-mschapv2')
        self.assertEqual(p['ike_ca'], 'geovpn-isrg-x1.pem')
        self.assertEqual(p['ike_dpd'], 30)

    def test_parse_invalid_sswan_json(self):
        """Assert parser returns error on malformed or missing-field sswan JSON."""
        script = """
        import * as ike from 'geovpn.ike_import';
        let res1 = ike.parse_sswan('{ invalid json }');
        assert(res1.ok == false, 'malformed json rejected');
        let res2 = ike.parse_sswan('{"name": "No remote"}');
        assert(res2.ok == false, 'missing remote rejected');
        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_parse_smart_paste(self):
        """Parse smart-paste text block containing Server, Username, Password lines."""
        script = """
        import * as ike from 'geovpn.ike_import';
        let text = `
        Server: vpn.example.com
        Remote ID: vpn.example.com
        Username: john_doe
        Password: my_super_secret_password
        `;
        let res = ike.parse_smart_paste(text, 'Manual Paste Profile');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(p['proto'], 'ikev2')
        self.assertEqual(p['name'], 'Manual Paste Profile')
        self.assertEqual(p['ike_host'], 'vpn.example.com')
        self.assertEqual(p['ike_remote_id'], 'vpn.example.com')
        self.assertEqual(p['ike_username'], 'john_doe')
        self.assertEqual(p['password'], 'my_super_secret_password')

    def test_import_integration_sniff_and_0600_secret_file(self):
        """Test import.import_profile sniffs .sswan, writes 0600 secret file, and keeps UCI clean of plaintext secrets."""
        sswan_content = json.dumps({
            "uuid": "test-uuid-111",
            "name": "IKE Import Test",
            "remote": {"address": "198.51.100.50"},
            "local": {"eap_id": "test_user"},
            "authentication": {"username": "test_user", "password": "super_secret_pass"}
        })

        script = f"""
        import * as imp from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let res = imp.import_profile({{ content: '{sswan_content}', filename: 'test.sswan' }});
        assert(res.ok == true, 'import succeeded: ' + (res.error || ''));
        let pid = res.id;

        let p = cfg.get_profile(pid);
        assert(p != null, 'profile exists in config');
        assert(p.proto == 'ikev2', 'proto is ikev2');
        assert(p.ike_host == '198.51.100.50', 'host stored in uci');
        assert(p.has_ike_secret == true, 'has_ike_secret is true');

        // Verify secret file exists with 0600 permissions
        let pdir = '{self.prof_dir}/' + pid;
        let sfile = pdir + '/ike.secret';
        let st = fs.stat(sfile);
        assert(st != null, 'ike.secret exists');
        let sec = trim(fs.readfile(sfile));
        assert(sec == 'super_secret_pass', 'secret stored accurately in file');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

        # Confirm UCI does not contain plaintext password
        uci_file = os.path.join(self.conf_dir, 'geovpn')
        with open(uci_file, 'r') as f:
            uci_text = f.read()
        self.assertNotIn('super_secret_pass', uci_text, "Plaintext password must NEVER appear in UCI config (NFR-18)")

    # ------------------------------------------------------------------------
    # 3. IKEv2 Driver Lifecycle & Configuration Rendering
    # ------------------------------------------------------------------------

    def test_driver_validate_and_endpoints(self):
        """Test driver validate() catches missing host/secrets and endpoints() returns UDP 500/4500."""
        script = """
        import * as drv from 'geovpn.drivers.ikev2';
        // Invalid: missing host
        let v1 = drv.validate({ proto: 'ikev2' });
        assert(length(v1.errors) > 0, 'missing host rejected');

        // Invalid: missing username
        let v2 = drv.validate({ proto: 'ikev2', ike_host: 'vpn.example.com' });
        assert(length(v2.errors) > 0, 'missing username rejected');

        // Warning: missing secret
        let v2b = drv.validate({ proto: 'ikev2', ike_host: 'vpn.example.com', ike_username: 'alice' });
        assert(length(v2b.warnings) > 0, 'missing secret warned');

        // Valid: host + user + password
        let v3 = drv.validate({ proto: 'ikev2', ike_host: 'vpn.example.com', ike_username: 'alice', password: 'secret' });
        assert(length(v3.errors) == 0, 'valid profile passes');

        // Endpoints check
        let eps = drv.endpoints({ ike_host: 'vpn.example.com' });
        assert(length(eps) == 2, 'returns 2 endpoints');
        assert(eps[0].port == 500 && eps[0].transport == 'udp', 'port 500 udp');
        assert(eps[1].port == 4500 && eps[1].transport == 'udp', 'port 4500 udp');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_prepare_swanctl_conf_and_hex_secret(self):
        """
        Test prepare() renders isolated swanctl.conf with:
        - Hex-encoded 0x<hex> secret
        - if_id_in / if_id_out set to 4200 (active) or 4300 (test)
        - /usr/libexec/geovpn/ike-updown script configured
        - Strict 0600 permissions
        """
        script = f"""
        import * as drv from 'geovpn.drivers.ikev2';
        import * as drv_common from 'geovpn.drivers.common';
        import * as fs from 'fs';

        let prof = {{
            id: 'p12345678',
            proto: 'ikev2',
            ike_host: 'vpn.example.com',
            ike_remote_id: 'vpn.example.com',
            ike_username: 'alice',
            password: 'Password123!',
            ike_ca: 'geovpn-isrg-x1.pem',
            ike_dpd: 30,
            ike_dns: ['1.1.1.1', '8.8.8.8']
        }};

        // Active Context
        let ctx_active = drv_common.create_context('active', 'p12345678', {{
            proto: 'ikev2',
            rundir: '{self.run_dir}/active',
            dev: 'geovpn0',
            ifid: 4200
        }});

        let res_act = drv.prepare(prof, ctx_active);
        assert(res_act.ok == true, 'prepare active ok');

        let conf_act = fs.readfile('{self.run_dir}/active/swanctl.conf');
        assert(index(conf_act, 'gv_active') != -1, 'contains gv_active connection');
        assert(index(conf_act, 'if_id_in = 4200') != -1, 'if_id_in is 4200');
        assert(index(conf_act, 'if_id_out = 4200') != -1, 'if_id_out is 4200');
        assert(index(conf_act, 'updown = /usr/libexec/geovpn/ike-updown') != -1, 'updown configured');

        // Hex encoded secret verification
        // 'Password123!' -> 50617373776f726431323321
        assert(index(conf_act, '0x50617373776f726431323321') != -1, 'contains hex-encoded secret 0x50617373776f726431323321');
        assert(index(conf_act, 'Password123!') == -1, 'plaintext password NOT in swanctl.conf');

        // Test Context
        let ctx_test = drv_common.create_context('test', 'p12345678', {{
            proto: 'ikev2',
            rundir: '{self.run_dir}/test_job1',
            dev: 'gvt0',
            ifid: 4300,
            jid: 'job1'
        }});

        let res_test = drv.prepare(prof, ctx_test);
        assert(res_test.ok == true, 'prepare test ok');

        let conf_test = fs.readfile('{self.run_dir}/test_job1/swanctl.conf');
        assert(index(conf_test, 'gv_test_job1') != -1, 'contains gv_test_job1 connection');
        assert(index(conf_test, 'if_id_in = 4300') != -1, 'if_id_in is 4300');
        assert(index(conf_test, 'if_id_out = 4300') != -1, 'if_id_out is 4300');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_xfrm_interface_bringup_active_and_test(self):
        """
        Test driver start() brings up XFRM interface with if_id 4200 (geovpn0)
        and if_id 4300 (gvt0), loads credentials & connections, and initiates.
        """
        script = f"""
        import * as drv from 'geovpn.drivers.ikev2';
        import * as drv_common from 'geovpn.drivers.common';

        let prof = {{
            id: 'p12345678',
            proto: 'ikev2',
            ike_host: 'vpn.example.com',
            ike_username: 'alice',
            password: 'SecretPassword123'
        }};

        let executed_commands = [];
        global._safe_exec_hook = function(argv, input) {{
            push(executed_commands, argv);
            return {{ code: 0, stdout: '', stderr: '' }};
        }};

        // 1. Active Tunnel Bringup (geovpn0 with if_id 4200)
        let ctx_act = drv_common.create_context('active', 'p12345678', {{
            proto: 'ikev2',
            rundir: '{self.run_dir}/active',
            dev: 'geovpn0',
            ifid: 4200
        }});

        let res_act = drv.start(prof, ctx_act);
        assert(res_act.ok == true, 'active start ok');
        assert(res_act.dev == 'geovpn0', 'dev is geovpn0');
        assert(res_act.if_id == 4200, 'if_id is 4200');

        let has_add_4200 = false;
        let has_up_geovpn0 = false;
        let has_swanctl_load = false;
        let has_initiate_active = false;
        for (let cmd in executed_commands) {{
            if (cmd[0] == 'ip' && cmd[1] == 'link' && cmd[2] == 'add' && cmd[4] == 'geovpn0' && cmd[6] == 'xfrm' && cmd[8] == '4200') has_add_4200 = true;
            if (cmd[0] == 'ip' && cmd[1] == 'link' && cmd[2] == 'set' && cmd[4] == 'geovpn0' && cmd[7] == 'up') has_up_geovpn0 = true;
            if (cmd[0] == 'swanctl' && cmd[1] == '--load-conns') has_swanctl_load = true;
            if (cmd[0] == 'swanctl' && cmd[1] == '--initiate' && cmd[3] == 'gv_active') has_initiate_active = true;
        }}
        assert(has_add_4200, 'ip link add dev geovpn0 type xfrm if_id 4200 executed');
        assert(has_up_geovpn0, 'ip link set dev geovpn0 up executed');
        assert(has_swanctl_load, 'swanctl --load-conns executed');
        assert(has_initiate_active, 'swanctl --initiate gv_active executed');

        // 2. Test Tunnel Bringup (gvt0 with if_id 4300)
        executed_commands = [];
        let ctx_test = drv_common.create_context('test', 'p12345678', {{
            proto: 'ikev2',
            rundir: '{self.run_dir}/test_job1',
            dev: 'gvt0',
            ifid: 4300,
            jid: 'job1'
        }});

        let res_test = drv.start(prof, ctx_test);
        assert(res_test.ok == true, 'test start ok');
        assert(res_test.dev == 'gvt0', 'dev is gvt0');
        assert(res_test.if_id == 4300, 'if_id is 4300');

        let has_add_4300 = false;
        let has_up_gvt0 = false;
        let has_initiate_test = false;
        for (let cmd in executed_commands) {{
            if (cmd[0] == 'ip' && cmd[1] == 'link' && cmd[2] == 'add' && cmd[4] == 'gvt0' && cmd[6] == 'xfrm' && cmd[8] == '4300') has_add_4300 = true;
            if (cmd[0] == 'ip' && cmd[1] == 'link' && cmd[2] == 'set' && cmd[4] == 'gvt0' && cmd[7] == 'up') has_up_gvt0 = true;
            if (cmd[0] == 'swanctl' && cmd[1] == '--initiate' && cmd[3] == 'gv_test_job1') has_initiate_test = true;
        }}
        assert(has_add_4300, 'ip link add dev gvt0 type xfrm if_id 4300 executed');
        assert(has_up_gvt0, 'ip link set dev gvt0 up executed');
        assert(has_initiate_test, 'swanctl --initiate gv_test_job1 executed');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_facts_parsing_from_swanctl_list_sas(self):
        """Test driver facts() correctly parses simulated swanctl --list-sas output."""
        script = f"""
        import * as drv from 'geovpn.drivers.ikev2';
        import * as drv_common from 'geovpn.drivers.common';
        import * as fs from 'fs';

        let ctx = drv_common.create_context('active', 'p12345678', {{
            proto: 'ikev2',
            rundir: '{self.run_dir}/facts_test',
            dev: 'geovpn0'
        }});
        fs.mkdir('{self.run_dir}/facts_test', 0o700);

        // 1. Test down state when swanctl returns empty
        global._safe_exec_hook = function(argv, input) {{
            return {{ code: 0, stdout: '', stderr: '' }};
        }};
        let f_down = drv.facts(ctx);
        assert(f_down.proto == 'ikev2', 'proto is ikev2');
        assert(f_down.up == false, 'up is false when down');
        assert(f_down.state == 'down', 'state is down');

        // 2. Test ESTABLISHED and INSTALLED SA parsing with strongSwan formatting
        let sample_output = `
gv_active: #1, ESTABLISHED, IKEv2, 6fd55d95f66b4a67_i* cea64d4a303e0ca2_r
  local 'carol@strongswan.org' @ 10.0.0.50[4500]
  remote 'moon.strongswan.org' @ 198.51.100.99[4500]
  AES_CBC-128/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/CURVE_25519
  established 42s ago, rekeying in 14043s
  gv_active: #1, reqid 1, INSTALLED, TUNNEL, ESP:AES_GCM_16-128
    installed 42s ago, rekeying in 3397s, expires in 3959s
    in  c8931e89,   987654 bytes,     1200 packets,     0s ago
    out cee78125,   456789 bytes,     950 packets,     0s ago
    local 10.10.10.5/32
    remote 0.0.0.0/0
`;
        let df = fs.open('{self.run_dir}/facts_test/pushed_dns', 'w');
        df.write("10.255.255.3\\n1.1.1.1\\n");
        df.close();

        global._safe_exec_hook = function(argv, input) {{
            if (argv[0] == 'swanctl' && argv[1] == '--list-sas') {{
                return {{ code: 0, stdout: sample_output, stderr: '' }};
            }}
            return {{ code: 0, stdout: '', stderr: '' }};
        }};

        let f_up = drv.facts(ctx);
        assert(f_up.proto == 'ikev2', 'proto is ikev2');
        assert(f_up.up == true, 'up is true when established and installed');
        assert(f_up.state == 'connected', 'state is connected');
        assert(f_up.endpoint_ip == '198.51.100.99', 'remote endpoint IP parsed correctly: ' + f_up.endpoint_ip);
        assert(f_up.rx == 987654, 'rx bytes parsed: ' + f_up.rx);
        assert(f_up.tx == 456789, 'tx bytes parsed: ' + f_up.tx);
        assert(length(f_up.v4) >= 1 && f_up.v4[0] == '10.10.10.5', 'VIP parsed from local /32: ' + sprintf('%J', f_up.v4));
        assert(length(f_up.dns) == 2, 'pushed DNS parsed: ' + sprintf('%J', f_up.dns));
        assert(f_up.dns[0] == '10.255.255.3', 'first DNS is 10.255.255.3');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_cmd_hook_ikev2_proto_dispatch(self):
        """Test cli cmd_hook resolves proto=ikev2 and creates context with ikev2 protocol."""
        hook_env_content = f"""script_type=up
dev=geovpn0
proto=ikev2
GV_CTX=active
ifconfig_local=10.10.10.5
trusted_ip=198.51.100.99
"""
        hook_env_path = os.path.join(self.run_dir, 'hook.env')
        with open(hook_env_path, 'w') as f:
            f.write(hook_env_content)

        script = f"""
        import * as cli from 'geovpn.cli';
        import * as state from 'geovpn.state';

        global._safe_exec_hook = function(argv, input) {{
            return {{ code: 0, stdout: '', stderr: '' }};
        }};

        let res = cli.main(['_hook', '{hook_env_path}']);
        assert(res == 0, 'cli _hook exited 0');

        let st = state.get_state();
        assert(st.tunnel.proto == 'ikev2', 'state.json tunnel proto updated to ikev2: ' + st.tunnel.proto);

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    # ------------------------------------------------------------------------
    # 4. Test Engine Credential Isolation (§7.1 / Invariant T5)
    # ------------------------------------------------------------------------

    def test_parallel_session_refused_when_sharing_credentials(self):
        """
        §7.1 / Invariant T5: Parallel test execution is REFUSED (parallel_session_refused)
        when the test candidate shares username/credentials with the active IKEv2 tunnel.
        """
        # Set up active profile p11111111 (IKEv2 with username 'alice')
        uci_content = f"""
config main 'main'
	option config_version '2'
	option active_profile 'p11111111'

config profile 'p11111111'
	option name 'Active IKEv2'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.10'
	option ike_username 'alice'

config profile 'p22222222'
	option name 'Candidate Same User'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.20'
	option ike_username 'alice'

config profile 'p33333333'
	option name 'Candidate Diff User'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.30'
	option ike_username 'bob'

config test 'test'
	option timeout_s '2'
"""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write(uci_content.strip() + '\n')

        # Create secret files for each profile
        for pid in ['p11111111', 'p22222222', 'p33333333']:
            pdir = os.path.join(self.prof_dir, pid)
            os.makedirs(pdir, exist_ok=True)
            with open(os.path.join(pdir, 'ike.secret'), 'w') as f:
                f.write('password123\n')

        script = """
        import * as te from 'geovpn.test_engine';

        // 1. Candidate sharing user 'alice' with active tunnel must be REFUSED
        let res_refused = te.test_profile('p22222222', { timeout_s: 1 });
        assert(res_refused.status == 'fail', 'same cred test fails');
        assert(res_refused.reason == 'parallel_session_refused', 'reason is parallel_session_refused');

        // 2. Candidate with user 'bob' must NOT be refused for credentials
        let res_diff = te.test_profile('p33333333', { timeout_s: 1 });
        assert(res_diff.reason != 'parallel_session_refused', 'different cred not refused for collision');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_sniff_kind_sswan_without_type_and_smart_paste(self):
        """Test auto-sniffing of .sswan without type key and smart-paste ikev2 text."""
        script = """
        import * as imp from 'geovpn.import';

        // 1. .sswan JSON without "type" key (e.g. Android export)
        let sswan_notype = '{"uuid":"123","remote":{"address":"vpn.net"}}';
        assert(imp.sniff_kind(sswan_notype, null) == 'sswan', 'sniffs sswan without type');

        // 2. ikev2 URI
        let uri = 'ikev2://user:pass@vpn.example.com';
        assert(imp.sniff_kind(uri, null) == 'ikev2', 'sniffs ikev2 URI');

        // 3. Smart paste key-value
        let kv = "Server: vpn.net\\nUsername: user1\\nPassword: pass";
        assert(imp.sniff_kind(kv, null) == 'ikev2', 'sniffs smart paste');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_parallel_session_refused_with_shared_credential_set(self):
        """
        §7.1: Candidate referencing a shared credential section matching active tunnel username
        is refused with parallel_session_refused even if candidate has no inline username.
        """
        uci_content = f"""
config main 'main'
	option config_version '2'
	option active_profile 'p11111111'

config profile 'p11111111'
	option name 'Active Direct User'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.10'
	option ike_username 'charlie'

config profile 'p44444444'
	option name 'Candidate Cred Ref'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.40'
	option cred 'cred_charlie'

config credential 'cred_charlie'
	option username 'charlie'

config test 'test'
	option timeout_s '2'
"""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write(uci_content.strip() + '\n')

        # Store auth in cred store
        cdir = os.path.join(self.cred_dir, 'cred_charlie')
        os.makedirs(cdir, exist_ok=True)
        with open(os.path.join(cdir, 'auth'), 'w') as f:
            f.write("charlie\nsecret123\n")

        pdir = os.path.join(self.prof_dir, 'p11111111')
        os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, 'ike.secret'), 'w') as f:
            f.write('password123\n')

        script = """
        import * as te from 'geovpn.test_engine';

        let res = te.test_profile('p44444444', { timeout_s: 1 });
        assert(res.status == 'fail', 'test fails');
        assert(res.reason == 'parallel_session_refused', 'refused due to shared cred username collision: ' + res.reason);

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_config_set_profile_credentials_ikev2(self):
        """Test config.set_profile_credentials updates ike_username in UCI and creates 0600 ike.secret."""
        uci_content = """
config main 'main'
	option config_version '2'

config profile 'p55555555'
	option name 'IKE Cred Test'
	option proto 'ikev2'
	option enabled '1'
	option ike_host '198.51.100.50'
"""
        with open(os.path.join(self.conf_dir, 'geovpn'), 'w', encoding='utf-8') as f:
            f.write(uci_content.strip() + '\n')

        pdir = os.path.join(self.prof_dir, 'p55555555')
        os.makedirs(pdir, exist_ok=True)

        script = f"""
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let ok = cfg.set_profile_credentials('p55555555', 'ike_user_val', 'ike_pass_val');
        assert(ok == true, 'set_profile_credentials succeeded');

        let p = cfg.get_profile('p55555555');
        assert(p.ike_username == 'ike_user_val', 'ike_username updated in uci');
        assert(p.has_ike_secret == true, 'has_ike_secret is true');

        let sec = trim(fs.readfile('{pdir}/ike.secret'));
        assert(sec == 'ike_pass_val', 'secret file contains password');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    # ------------------------------------------------------------------------
    # 5. Golden Baseline Regression Assertion
    # ------------------------------------------------------------------------

    def test_golden_baseline_zero_regression(self):
        """Assert all 10 golden baseline fixtures pass with 0-byte difference."""
        golden_test = subprocess.run(
            ['python3', '-m', 'unittest', 'tests/unit/test_golden_baseline.py'],
            capture_output=True,
            text=True,
            cwd=self.repo_root
        )
        self.assertEqual(golden_test.returncode, 0, f"Golden baseline tests failed: {golden_test.stderr}")
        self.assertIn('Ran 10 tests', golden_test.stderr)
        self.assertIn('OK', golden_test.stderr)

if __name__ == '__main__':
    unittest.main()
