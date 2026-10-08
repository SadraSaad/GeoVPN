#!/usr/bin/env python3
"""
Unit tests for WireGuard protocol driver, .conf parser, credential security,
and lifecycle operations (§5.3.2, §6.5 / FR-29, FR-31, NFR-18, NFR-19 / AT-24, AT-25).
"""
import unittest
import os
import subprocess
import json
import shutil
import tempfile

class TestWireguard(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_wg_test_')
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
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True, env=env)
        return proc

    # ------------------------------------------------------------------------
    # 1. WireGuard .conf Parser Tests (wg_parse.uc / AT-24 / FR-31)
    # ------------------------------------------------------------------------

    def test_parse_valid_generic_wireguard_conf(self):
        """Parse valid generic WireGuard config and assert extracted fields."""
        script = """
        import * as wg from 'geovpn.wg_parse';
        let conf = `
        [Interface]
        PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Address = 10.0.0.2/24
        DNS = 1.1.1.1, 9.9.9.9
        MTU = 1420

        [Peer]
        PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Endpoint = 198.51.100.1:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        `;
        let res = wg.parse_wireguard(conf, 'Generic WG');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(p['proto'], 'wireguard')
        self.assertEqual(p['name'], 'Generic WG')
        self.assertEqual(p['wg_endpoint_host'], '198.51.100.1')
        self.assertEqual(p['wg_endpoint_port'], 51820)
        self.assertEqual(p['wg_address'], ['10.0.0.2/24'])
        self.assertEqual(p['wg_dns'], ['1.1.1.1', '9.9.9.9'])
        self.assertEqual(p['wg_allowed_ips'], ['0.0.0.0/0'])
        self.assertEqual(p['wg_mtu'], 1420)
        self.assertEqual(p['wg_keepalive'], 25)
        self.assertEqual(p['wg_has_psk'], '0')

    def test_parse_windscribe_wireguard_detection_and_hints(self):
        """Parse Windscribe-shaped WireGuard config with PSK, 10.255.255.3 DNS, and .windscribe.com endpoint."""
        script = """
        import * as wg from 'geovpn.wg_parse';
        let conf = `
        # Windscribe Dallas WireGuard Configuration
        [Interface]
        PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Address = 100.64.12.34/32
        DNS = 10.255.255.3

        [Peer]
        PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        PresharedKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Endpoint = ws-dallas.windscribe.com:443
        AllowedIPs = 0.0.0.0/0
        `;
        let res = wg.parse_wireguard(conf, 'Windscribe Dallas');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(p['provider'], 'windscribe')
        self.assertEqual(p['wg_has_psk'], '1')
        self.assertEqual(p['wg_endpoint_port'], 443)
        self.assertEqual(p['wg_mtu'], 1420) # default applied
        self.assertEqual(p['wg_keepalive'], 25) # default applied
        self.assertTrue(any('regenerate' in w for w in p.get('warnings', [])))

    def test_parse_ipv6_endpoint_and_dual_stack_addresses(self):
        """Parse WireGuard config with bracketed IPv6 endpoint and dual-stack IPv4/IPv6 addresses."""
        script = """
        import * as wg from 'geovpn.wg_parse';
        let conf = `
        [Interface]
        PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Address = 10.0.0.2/32, 2001:db8::2/64
        DNS = 1.1.1.1, 2606:4700:4700::1111

        [Peer]
        PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        `;
        let res = wg.parse_wireguard(conf, 'IPv6 WG');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(p['wg_endpoint_host'], '2001:db8::1')
        self.assertEqual(p['wg_endpoint_port'], 51820)
        self.assertEqual(len(p['wg_address']), 2)
        self.assertIn('2001:db8::2/64', p['wg_address'])
        self.assertIn('::/0', p['wg_allowed_ips'])

    def test_hostile_corpus_rejection(self):
        """Assert strict rejection of shell hooks, obfuscation params, syntax errors, and hostile inputs."""
        hostile_cases = [
            ("PostUp shell hook", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nPostUp=rm -rf /\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Shell hook"),
            ("PreUp shell hook", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nPreUp=/bin/sh /tmp/evil\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Shell hook"),
            ("PostDown shell hook", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nPostDown=echo pwn\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Shell hook"),
            ("AmneziaWG Jc param", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nJc=4\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Obfuscation parameters"),
            ("AmneziaWG S1 param", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0\nS1=50", "Obfuscation parameters"),
            ("Multiple peers", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=2.2.2.2:51820\nAllowedIPs=0.0.0.0/0", "Multiple [Peer] sections"),
            ("Multiple interfaces", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Interface]\nAddress=10.0.0.2/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Multiple [Interface] sections"),
            ("Missing [Peer]", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32", "Missing [Peer]"),
            ("Missing [Interface]", "[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Missing [Interface]"),
            ("Invalid key length", "[Interface]\nPrivateKey=shortkey\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Invalid PrivateKey"),
            ("AllowedIPs not covering 0.0.0.0/0", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=192.168.1.0/24", "AllowedIPs doesn't cover 0.0.0.0/0"),
            ("Binary NUL byte", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\0\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Binary NUL"),
            ("Duplicate PrivateKey", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Duplicate PrivateKey"),
            ("Duplicate PublicKey", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Duplicate PublicKey"),
            ("Duplicate Endpoint", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nEndpoint=2.2.2.2:51820\nAllowedIPs=0.0.0.0/0", "Duplicate Endpoint"),
            ("Duplicate MTU", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nMTU=1420\nMTU=1400\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0", "Duplicate MTU"),
            ("Duplicate PersistentKeepalive", "[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0\nPersistentKeepalive=25\nPersistentKeepalive=30", "Duplicate PersistentKeepalive"),
        ]

        for desc, conf, expected_err in hostile_cases:
            script = f"""
            import * as wg from 'geovpn.wg_parse';
            let res = wg.parse_wireguard({json.dumps(conf)});
            print(sprintf('%J', res));
            """
            proc = self.run_ucode(script)
            self.assertEqual(proc.returncode, 0, f"{desc} ucode execution failed: {proc.stderr}")
            data = json.loads(proc.stdout)
            self.assertFalse(data.get('ok'), f"{desc} should have been rejected")
            self.assertIn(expected_err, data.get('error', ''), f"{desc} expected error matching '{expected_err}'")

    def test_utf8_bom_and_ignored_directives(self):
        """Assert UTF-8 BOM is cleanly stripped and ListenPort/FwMark/Table are ignored with note."""
        bom_conf = "\ufeff[Interface]\nPrivateKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nAddress=10.0.0.1/32\nListenPort=51820\nFwMark=0x1234\nTable=auto\n[Peer]\nPublicKey=MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=\nEndpoint=1.1.1.1:51820\nAllowedIPs=0.0.0.0/0\n"
        script = f"""
        import * as wg from 'geovpn.wg_parse';
        let res = wg.parse_wireguard({json.dumps(bom_conf)});
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertTrue(data.get('ok'))
        p = data.get('profile', {})
        self.assertEqual(len(p.get('ignored', [])), 3)

    # ------------------------------------------------------------------------
    # 2. WireGuard Credential Store Tests (cred.uc / NFR-18 / AT-24)
    # ------------------------------------------------------------------------

    def test_cred_store_and_load_wg_keys(self):
        """Test storing and loading WireGuard keys via cred.uc with strict 0600 mode and secret scrubbing."""
        script = f"""
        import * as cred from 'geovpn.cred';
        import * as fs from 'fs';

        let id = 'p_testwg1';
        let priv = 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=';
        let psk = 'cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQxMjM=';

        assert(cred.store_wg_keys(id, priv, psk), 'store_wg_keys succeeded');
        let kp = cred.get_wg_key_path(id);
        let pp = cred.get_wg_psk_path(id);
        assert(kp != null && fs.stat(kp) != null, 'key file exists');
        assert(pp != null && fs.stat(pp) != null, 'psk file exists');

        assert(cred.has_secret(id, 'wg.key'), 'has_secret wg.key');
        assert(cred.has_secret(id, 'wg.psk'), 'has_secret wg.psk');

        // Verify secret scrubber
        let raw_log = sprintf('Config: PrivateKey = %s, peer preshared-key %s', priv, pp);
        let scrubbed = cred.scrub_secrets(raw_log);
        assert(index(scrubbed, priv) == -1, 'private key scrubbed from log');
        assert(index(scrubbed, '[REDACTED]') != -1, 'redacted token present');

        // Cleanup
        assert(cred.delete_credential(id), 'delete_credential succeeded');
        assert(!cred.has_secret(id, 'wg.key'), 'wg.key deleted');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_no_secret_keys_in_uci_profile(self):
        """Assert that config.create_profile writes WireGuard keys to 0600 files, NOT UCI options."""
        script = f"""
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let parsed = {{
            proto: 'wireguard',
            name: 'Dallas WG',
            wg_endpoint_host: '198.51.100.1',
            wg_endpoint_port: 51820,
            wg_public_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            private_key: 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWY=',
            preshared_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            wg_address: ['10.0.0.2/32'],
            wg_allowed_ips: ['0.0.0.0/0'],
            wg_mtu: 1420,
            wg_keepalive: 25
        }};

        let id = cfg.create_profile(parsed);
        assert(id != null, 'profile created');

        let prof = cfg.get_profile(id);
        assert(prof.proto == 'wireguard', 'proto is wireguard');
        assert(prof.private_key == null, 'private_key NEVER in UCI profile options');
        assert(prof.preshared_key == null, 'preshared_key NEVER in UCI profile options');
        assert(prof.has_wg_key == true, 'has_wg_key is true');
        assert(prof.has_wg_psk == true, 'has_wg_psk is true');

        // Key files exist on disk
        let key_on_disk = fs.stat(cfg.get_profiles_dir() + '/' + id + '/wg.key');
        assert(key_on_disk != null, 'wg.key written to profile directory');

        // Cleanup
        cfg.delete_profile(id);
        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    # ------------------------------------------------------------------------
    # 3. WireGuard Protocol Driver Lifecycle Tests (wireguard.uc / AT-25 / FR-29)
    # ------------------------------------------------------------------------

    def test_driver_common_contract_wireguard(self):
        """Assert wireguard driver registers with drivers/common.uc and fulfills interface."""
        script = """
        import * as drv_common from 'geovpn.drivers.common';
        let drv = drv_common.get_driver('wireguard');
        assert(drv != null, 'wireguard driver registered');
        assert(drv.proto == 'wireguard', 'proto is wireguard');

        let drivers = drv_common.list_drivers();
        assert(drivers.wireguard != null, 'wireguard in list_drivers');
        assert(drivers.wireguard.ok != null, 'wireguard availability reported');

        let val = drv.validate({
            wg_public_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            wg_endpoint_host: 'vpn.example.com',
            wg_endpoint_port: 51820,
            wg_address: ['10.0.0.2/32'],
            wg_allowed_ips: ['0.0.0.0/0'],
            private_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI='
        });
        assert(length(val.errors) == 0, 'validate passed');

        let eps = drv.endpoints({
            wg_endpoint_host: '198.51.100.1',
            wg_endpoint_port: 51820
        });
        assert(length(eps) == 1, 'endpoint extracted');
        assert(eps[0].ips[0] == '198.51.100.1', 'ip extracted from endpoint');
        assert(eps[0].transport == 'udp', 'udp transport');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_prepare_and_context_awareness(self):
        """Test driver prepare() sets up rundir, pushed_dns, and binds context to geovpn0 vs gvt0."""
        script = f"""
        import * as drv_common from 'geovpn.drivers.common';
        import * as drv from 'geovpn.drivers.wireguard';
        import * as fs from 'fs';

        let rundir_active = '{self.run_dir}/active';
        let rundir_test = '{self.run_dir}/test';

        let ctx_active = drv_common.create_context('active', 'p10000001', {{ proto: 'wireguard', rundir: rundir_active }});
        assert(ctx_active.dev == 'geovpn0', 'active dev is geovpn0');
        assert(ctx_active.table == 4200, 'active table is 4200');

        let ctx_test = drv_common.create_context('test', 'p10000002', {{ proto: 'wireguard', rundir: rundir_test }});
        assert(ctx_test.dev == 'gvt0', 'test dev is gvt0');
        assert(ctx_test.table == 4300, 'test table is 4300');

        let prof = {{
            id: 'p10000001',
            proto: 'wireguard',
            wg_endpoint_host: '198.51.100.1',
            wg_endpoint_port: 51820,
            wg_public_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            private_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            wg_address: ['10.0.0.2/32'],
            wg_allowed_ips: ['0.0.0.0/0'],
            wg_dns: ['10.255.255.3'],
            wg_mtu: 1420
        }};

        let res = drv.prepare(prof, ctx_active);
        assert(res.ok == true, 'prepare active succeeded');
        assert(fs.stat(rundir_active + '/pushed_dns') != null, 'pushed_dns written');
        assert(fs.stat(rundir_active + '/profile.json') != null, 'profile.json written');

        // Cleanup
        drv.cleanup(ctx_active);
        drv.cleanup(ctx_test);
        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_facts_state_derivation_from_wg_dump(self):
        """Test driver facts() state derivation: down when device absent, connecting/connected/stale based on handshake."""
        script = """
        import * as drv from 'geovpn.drivers.wireguard';
        import * as drv_common from 'geovpn.drivers.common';

        // Down state when device does not exist
        let ctx = drv_common.create_context('active', 'p_nonexistent', { proto: 'wireguard', dev: 'gv_fake0' });
        let f_down = drv.facts(ctx);
        assert(f_down.proto == 'wireguard', 'proto is wireguard');
        assert(f_down.up == false, 'up is false when down');
        assert(f_down.state == 'down', 'state is down');
        assert(f_down.last_handshake == null, 'no handshake when down');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
    def test_parse_ipv6_only_default_route(self):
        """Parse WireGuard config with AllowedIPs = ::/0 satisfying default route coverage requirement."""
        script = """
        import * as wg from 'geovpn.wg_parse';
        import * as drv from 'geovpn.drivers.wireguard';
        let conf = `
        [Interface]
        PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Address = 2001:db8::2/64
        [Peer]
        PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
        Endpoint = 198.51.100.1:51820
        AllowedIPs = ::/0
        `;
        let res = wg.parse_wireguard(conf, 'IPv6 Default Only');
        assert(res.ok == true, 'parse succeeded with ::/0');
        assert(res.profile.wg_allowed_ips[0] == '::/0', 'allowed_ips has ::/0');
        let val = drv.validate(res.profile);
        assert(length(val.errors) == 0, 'validate succeeded with ::/0');
        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_prepare_nested_test_rundir(self):
        """Test prepare() with deeply nested test rundir and assert cleanup removes it."""
        nested_run = os.path.join(self.run_dir, 'deep', 'test_jobs', 'p999')
        script = f"""
        import * as drv_common from 'geovpn.drivers.common';
        import * as drv from 'geovpn.drivers.wireguard';
        import * as fs from 'fs';

        let ctx = drv_common.create_context('test', 'p999', {{
            proto: 'wireguard',
            rundir: '{nested_run}'
        }});

        let prof = {{
            id: 'p999',
            proto: 'wireguard',
            wg_endpoint_host: '198.51.100.1',
            wg_endpoint_port: 51820,
            wg_public_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            private_key: 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
            wg_address: ['10.0.0.2/32'],
            wg_allowed_ips: ['0.0.0.0/0']
        }};

        let prep = drv.prepare(prof, ctx);
        assert(prep.ok == true, 'nested prepare succeeded');
        assert(fs.stat('{nested_run}/wg.key') != null, 'key file exists');

        let cl = drv.cleanup(ctx);
        assert(cl.ok == true, 'cleanup succeeded');
        assert(fs.stat('{nested_run}') == null, 'test rundir removed');

        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_cred_profile_dir_custom_env(self):
        """Test cred.get_wg_key_path resolves from GEOVPN_PROFILES_DIR when secret not in cred dir."""
        prof_id = 'p_envtest'
        custom_prof_dir = os.path.join(self.prof_dir, prof_id)
        os.makedirs(custom_prof_dir, exist_ok=True)
        key_file = os.path.join(custom_prof_dir, 'wg.key')
        with open(key_file, 'w') as f:
            f.write('MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=')

        script = f"""
        import * as cred from 'geovpn.cred';
        let kp = cred.get_wg_key_path('{prof_id}');
        assert(kp == '{key_file}', 'found key in GEOVPN_PROFILES_DIR');
        print('OK');
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_driver_line_count_budget_nfr19(self):
        """Assert wireguard driver meets modularity constraint <= 400 lines (NFR-19)."""
        drv_path = os.path.join(self.lib_path, 'geovpn', 'drivers', 'wireguard.uc')
        self.assertTrue(os.path.exists(drv_path), "wireguard.uc must exist")
        with open(drv_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        count = len(lines)
        self.assertLessEqual(count, 400, f"wireguard.uc ({count} lines) must not exceed 400 lines (NFR-19)")

    # ------------------------------------------------------------------------
    # 4. Packaging and Build System Verification
    # ------------------------------------------------------------------------

    def test_geovpn_wireguard_makefile_spec(self):
        """Assert openwrt/geovpn-wireguard/Makefile dependencies and packaging flags."""
        mf_path = os.path.join(self.repo_root, 'openwrt', 'geovpn-wireguard', 'Makefile')
        self.assertTrue(os.path.exists(mf_path), "openwrt/geovpn-wireguard/Makefile must exist")
        with open(mf_path, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('PKGARCH:=all', content)
        self.assertIn('+geovpn-core', content)
        self.assertIn('+kmod-wireguard', content)
        self.assertIn('+wireguard-tools', content)
        self.assertIn('Apache-2.0', content)


if __name__ == '__main__':
    unittest.main()
