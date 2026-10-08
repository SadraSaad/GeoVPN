#!/usr/bin/env python3
"""
Unit tests for GeoVPN Unified Import Dispatcher, Windscribe Normalizations (N1..N5),
Shared Credential Linking, Batch Imports, Deduplication, and Honest Limitations (§5, §11 A3 / AT-24, AT-26, AT-35, AT-36).
"""
import unittest
import os
import subprocess
import json
import shutil
import tempfile

class TestImport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.plugin_path = os.path.join(cls.repo_root, 'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'ucode', 'geovpn.uc')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_import_test_')
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
    # 1. Single Profile Import (.ovpn and .conf)
    # ------------------------------------------------------------------------

    def test_import_single_ovpn_profile(self):
        """Import single valid .ovpn profile, verifying profile creation and raw file."""
        ovpn_content = """client
dev tun
proto udp
remote vpn.example.com 1194
cipher AES-256-GCM
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
MIIBCAJBAgEAM...
-----END CERTIFICATE-----
</ca>
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let content = {json.dumps(ovpn_content)};
        let res = importer.import_profile({{
            filename: 'My-Office-VPN.ovpn',
            content: content
        }});

        let p = res.ok ? cfg.get_profile(res.id) : null;
        let raw_file = res.ok ? fs.stat(cfg.get_profiles_dir() + '/' + res.id + '/profile.ovpn') : null;

        print(sprintf('%J', {{ res: res, profile: p, has_raw: (raw_file != null) }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        self.assertEqual(out['res']['name'], 'My Office VPN')
        self.assertEqual(out['res']['proto'], 'openvpn')
        self.assertTrue(out['has_raw'])
        self.assertEqual(out['profile']['cipher'], 'AES-256-GCM')
        self.assertIn('vpn.example.com 1194 udp', out['profile']['remotes'])

    def test_import_single_wireguard_profile(self):
        """Import single valid .conf WireGuard profile, verifying keys and parameters."""
        wg_content = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = wg.example.com:51820
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let content = {json.dumps(wg_content)};
        let res = importer.import_profile({{
            filename: 'Windscribe-Toronto.conf',
            content: content
        }});

        let p = res.ok ? cfg.get_profile(res.id) : null;
        let key_file = res.ok ? fs.stat(cfg.get_profiles_dir() + '/' + res.id + '/wg.key') : null;
        let raw_file = res.ok ? fs.stat(cfg.get_profiles_dir() + '/' + res.id + '/profile.conf') : null;

        print(sprintf('%J', {{ res: res, profile: p, has_key: (key_file != null), has_raw: (raw_file != null) }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        self.assertEqual(out['res']['name'], 'Windscribe Toronto')
        self.assertEqual(out['res']['proto'], 'wireguard')
        self.assertTrue(out['has_key'])
        self.assertTrue(out['has_raw'])
        self.assertEqual(out['profile']['wg_endpoint_host'], 'wg.example.com')
        self.assertEqual(out['profile']['wg_endpoint_port'], '51820')
        self.assertEqual(out['profile']['wg_mtu'], '1420')
        self.assertEqual(out['profile']['wg_keepalive'], '25')

    # ------------------------------------------------------------------------
    # 2. Windscribe Presets & Normalizations (N1..N5)
    # ------------------------------------------------------------------------

    def test_windscribe_n1_n2_normalizations(self):
        """Test N1 (ping-exit -> ping-restart) and N2 (keepalive suppression)."""
        ovpn_content = """client
dev tun
remote us-east.windscribe.com 443 udp
cipher AES-256-GCM
ping 10
ping-exit 60
keepalive 10 60
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as drv_ovpn from 'geovpn.drivers.openvpn';

        let content = {json.dumps(ovpn_content)};
        let res = importer.import_profile({{
            name: 'Windscribe US East',
            content: content
        }});

        let p = cfg.get_profile(res.id);
        let rendered = drv_ovpn.render_ovpn(p, cfg.get_profiles_dir() + '/' + res.id);

        print(sprintf('%J', {{
            res: res,
            profile: p,
            rendered: rendered
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        p = out['profile']
        # N1: ping-exit 60 was normalized to ping-restart 60
        self.assertEqual(p['ping_restart'], '60')
        # N2: keepalive was suppressed because ping directives are present
        self.assertEqual(p['keepalive'], '')
        rendered = out['rendered']
        self.assertIn('ping-restart 60', rendered)
        self.assertNotIn('ping-exit', rendered)
        self.assertNotIn('keepalive', rendered)

    def test_windscribe_n3_remote_deduplication(self):
        """Test N3: Remote endpoint parsing & deduplication."""
        ovpn_content = """client
dev tun
remote us.windscribe.com 443 udp
remote US.WINDSCRIBE.COM 443 UDP
remote us.windscribe.com 1194 udp
remote US.WINDSCRIBE.COM 443 UDP
remote us2.windscribe.com 443 udp
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';

        let content = {json.dumps(ovpn_content)};
        let res = importer.import_profile({{
            name: 'Windscribe Multi-Remote',
            content: content
        }});

        let p = cfg.get_profile(res.id);
        print(sprintf('%J', {{ res: res, remotes: p.remotes }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        # 5 remotes had 2 duplicates -> should result in exactly 3 distinct remotes
        self.assertEqual(len(out['remotes']), 3)
        self.assertEqual(out['remotes'][0], 'us.windscribe.com 443 udp')
        self.assertEqual(out['remotes'][1], 'us.windscribe.com 1194 udp')
        self.assertEqual(out['remotes'][2], 'us2.windscribe.com 443 udp')

    def test_windscribe_n4_mtu_mss_clamping(self):
        """Test N4: WireGuard default MTU 1420 & keepalive 25; OpenVPN MTU/MSS clamping."""
        # WireGuard without explicit MTU or keepalive
        wg_content = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24

[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
"""
        # OpenVPN with excessively large or missing MSS
        ovpn_content = """client
dev tun
remote 198.51.100.2 1194 udp
tun-mtu 1500
mssfix 1600
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';

        let res_wg = importer.import_profile({{
            name: 'WG MTU Test',
            content: {json.dumps(wg_content)}
        }});
        let res_ovpn = importer.import_profile({{
            name: 'OVPN MSS Test',
            content: {json.dumps(ovpn_content)}
        }});

        let p_wg = cfg.get_profile(res_wg.id);
        let p_ovpn = cfg.get_profile(res_ovpn.id);

        print(sprintf('%J', {{
            wg_mtu: p_wg.wg_mtu,
            wg_keepalive: p_wg.wg_keepalive,
            ovpn_mtu: p_ovpn.tun_mtu,
            ovpn_mss: p_ovpn.mssfix
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertEqual(out['wg_mtu'], '1420')
        self.assertEqual(out['wg_keepalive'], '25')
        self.assertEqual(out['ovpn_mtu'], '1500')
        # mssfix 1600 clamped down to standard 1450
        self.assertEqual(out['ovpn_mss'], '1450')

    def test_windscribe_n5_pushed_dns_normalization(self):
        """Test N5: Pushed DNS normalization (10.255.255.3 and provider='windscribe')."""
        wg_ws = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
DNS = 10.255.255.3

[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = dallas.windscribe.com:443
AllowedIPs = 0.0.0.0/0
"""
        ovpn_ws = """client
dev tun
remote zurich.windscribe.com 443 udp
# dhcp-option DNS 10.255.255.3
dhcp-option DNS 10.255.255.3
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';

        let res_wg = importer.import_profile({{
            filename: 'ws-dallas.conf',
            content: {json.dumps(wg_ws)}
        }});
        let res_ovpn = importer.import_profile({{
            filename: 'ws-zurich.ovpn',
            content: {json.dumps(ovpn_ws)}
        }});

        let p_wg = cfg.get_profile(res_wg.id);
        let p_ovpn = cfg.get_profile(res_ovpn.id);

        print(sprintf('%J', {{
            wg_provider: p_wg.provider,
            wg_dns: p_wg.wg_dns,
            ovpn_provider: p_ovpn.provider,
            ovpn_notices: res_ovpn.warnings
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertEqual(out['wg_provider'], 'windscribe')
        self.assertIn('10.255.255.3', out['wg_dns'])
        self.assertEqual(out['ovpn_provider'], 'windscribe')
        # Check warning/notice mentions pushed DNS normalization
        has_n5_notice = any('10.255.255.3' in w for w in out['ovpn_notices'])
        self.assertTrue(has_n5_notice)

    # ------------------------------------------------------------------------
    # 3. Shared Credential Linking (§5.4 / FR-34)
    # ------------------------------------------------------------------------

    def test_shared_credential_linking_openvpn(self):
        """Link imported OpenVPN profile to shared credential set (cred_id)."""
        ovpn_content = """client
dev tun
remote host.example.com 1194 udp
auth-user-pass
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as cred from 'geovpn.cred';
        import * as drv_ovpn from 'geovpn.drivers.openvpn';

        // Pre-create shared credential set
        let cid = 'c_ws_openvpn';
        cred.store_userpass(cid, 'windscribe_user', 'windscribe_secret_pass');

        let res = importer.import_profile({{
            name: 'Shared Cred OpenVPN',
            content: {json.dumps(ovpn_content)},
            cred: cid
        }});

        let p = cfg.get_profile(res.id);
        let rendered = drv_ovpn.render_ovpn(p, cfg.get_profiles_dir() + '/' + res.id);

        print(sprintf('%J', {{
            res: res,
            profile: p,
            rendered: rendered,
            has_auth: p.has_auth
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        self.assertEqual(out['profile']['cred'], 'c_ws_openvpn')
        self.assertTrue(out['has_auth'])
        self.assertFalse(out['res']['needs_credentials'])
        # OpenVPN driver renders path to shared credentials
        self.assertIn('credentials/c_ws_openvpn/auth', out['rendered'])

    def test_shared_credential_linking_wireguard(self):
        """Link imported WireGuard profile to shared credential set for key reuse."""
        wg_content = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24

[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as cred from 'geovpn.cred';
        import * as drv_wg from 'geovpn.drivers.wireguard';
        import * as common from 'geovpn.drivers.common';

        let cid = 'c_wg_keyset';
        let res = importer.import_profile({{
            name: 'Shared WG Profile',
            content: {json.dumps(wg_content)},
            cred: cid
        }});

        let p = cfg.get_profile(res.id);
        let has_secret = cred.has_secret(cid, 'wg.key');

        let ctx = common.create_context('active', res.id);
        let prep = drv_wg.prepare(ctx, p);

        print(sprintf('%J', {{
            res: res,
            profile: p,
            cred_has_secret: has_secret,
            prep_ok: prep.ok
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        self.assertEqual(out['profile']['cred'], 'c_wg_keyset')
        self.assertTrue(out['cred_has_secret'])
        self.assertTrue(out['prep_ok'])

    # ------------------------------------------------------------------------
    # 4. Batch Import, Deduplication, and Rollback
    # ------------------------------------------------------------------------

    def test_batch_import_directory(self):
        """Batch import multiple files from directory with naming normalization."""
        batch_dir = os.path.join(self.test_dir, 'batch_files')
        os.makedirs(batch_dir, exist_ok=True)

        with open(os.path.join(batch_dir, 'Windscribe-Dallas-Trinity.conf'), 'w') as f:
            f.write("""[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = dallas.windscribe.com:443
AllowedIPs = 0.0.0.0/0
""")

        with open(os.path.join(batch_dir, 'Windscribe_Paris_Seine.ovpn'), 'w') as f:
            f.write("""client
dev tun
remote paris.windscribe.com 443 udp
cipher AES-256-GCM
""")

        with open(os.path.join(batch_dir, 'ignore_me.txt'), 'w') as f:
            f.write("text file")

        script = f"""
        import * as importer from 'geovpn.import';
        let res = importer.import_batch('{batch_dir}');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['ok'])
        self.assertEqual(out['count'], 2)
        names = [p['name'] for p in out['imported']]
        self.assertIn('Windscribe Dallas Trinity', names)
        self.assertIn('Windscribe Paris Seine', names)

    def test_content_hash_and_endpoint_deduplication(self):
        """Assert identical content hash or endpoint triggers duplicate skip."""
        wg_content = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.99:443
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        import * as importer from 'geovpn.import';

        let res1 = importer.import_profile({{
            filename: 'profile-a.conf',
            content: {json.dumps(wg_content)}
        }});

        let res2 = importer.import_profile({{
            filename: 'profile-b.conf',
            content: {json.dumps(wg_content)},
            dedupe: 'skip'
        }});

        print(sprintf('%J', {{ res1: res1, res2: res2 }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res1']['ok'])
        self.assertTrue(out['res2']['ok'])
        self.assertTrue(out['res2']['skipped'])
        self.assertEqual(out['res2']['duplicate_of'], out['res1']['id'])

    def test_atomic_rollback_on_fatal_batch_error(self):
        """Assert fatal error in atomic batch rolls back all created profiles."""
        valid_wg = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
"""
        hostile_file = "client\ndev tun\n\x00invalid nul byte"

        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';

        let items = [
            {{ filename: 'file1.conf', content: {json.dumps(valid_wg)} }},
            {{ filename: 'file2.ovpn', content: {json.dumps(hostile_file)} }},
            {{ filename: 'file3.conf', content: {json.dumps(valid_wg)} }}
        ];

        let res = importer.import_batch(items, {{ atomic: true }});
        let config = cfg.load_config();
        let profiles = keys(config.profiles);

        print(sprintf('%J', {{ res: res, profiles: profiles }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertFalse(out['res']['ok'])
        self.assertTrue(out['res']['rolled_back'])
        self.assertEqual(out['res']['rollback_count'], 1)
        # file1 was rolled back, leaving 0 profiles
        self.assertEqual(len(out['profiles']), 0)

    # ------------------------------------------------------------------------
    # 5. Limitation Notices & Hostile Input Defenses
    # ------------------------------------------------------------------------

    def test_stealth_wstunnel_detection_notice(self):
        """Assert clear notice generated when Stealth or WStunnel is detected."""
        stealth_ovpn = """client
dev tun
# Windscribe Stealth configuration via wstunnel
proto tcp
remote stealth.windscribe.com 443
# wstunnel encapsulation port 443
"""
        script = f"""
        import * as importer from 'geovpn.import';
        let res = importer.import_profile({{
            filename: 'ws-stealth.ovpn',
            content: {json.dumps(stealth_ovpn)}
        }});
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['ok'])
        has_stealth_notice = any('Stealth/WStunnel' in n for n in out['notices'])
        self.assertTrue(has_stealth_notice)

    def test_hostile_corpus_rejections(self):
        """Test rejection of binary NUL, oversized files, shell hooks, and traversal."""
        # 1. NUL byte
        res_nul = self.run_ucode(r"""
        import * as importer from 'geovpn.import';
        let res = importer.import_profile({ content: "client\n\x00dev tun" });
        print(sprintf('%J', res));
        """)
        self.assertFalse(json.loads(res_nul.stdout)['ok'])

        # 2. Oversized > 128 KB
        res_big = self.run_ucode("""
        import * as importer from 'geovpn.import';
        let big = "client\\n";
        for (let i = 0; i < 20000; i++) big += "# filler line for size check\\n";
        let res = importer.import_profile({ content: big });
        print(sprintf('%J', res));
        """)
        self.assertFalse(json.loads(res_big.stdout)['ok'])

        # 3. PostUp hook in WireGuard
        wg_hook = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
PostUp = /bin/sh -c 'rm -rf /'
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
"""
        res_hook = self.run_ucode(f"""
        import * as importer from 'geovpn.import';
        let res = importer.import_profile({{ content: {json.dumps(wg_hook)} }});
        print(sprintf('%J', res));
        """)
        self.assertFalse(json.loads(res_hook.stdout)['ok'])

        # 4. Path traversal in cred_id
        res_trav = self.run_ucode("""
        import * as importer from 'geovpn.import';
        let res = importer.import_profile({
            content: "client\ndev tun",
            cred: "../../etc/shadow"
        });
        print(sprintf('%J', res));
        """)
        self.assertFalse(json.loads(res_trav.stdout)['ok'])

    # ------------------------------------------------------------------------
    # 6. CLI & RPCD Integration Tests
    # ------------------------------------------------------------------------

    def test_cli_import_verbs(self):
        """Test geovpn import CLI with --proto and --cred options."""
        sample_conf = os.path.join(self.test_dir, 'sample.conf')
        with open(sample_conf, 'w') as f:
            f.write("""[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
""")

        script = f"""
        import {{ main }} from 'geovpn.cli';
        let rc = main(['import', '--proto', 'wg', '--cred', 'c_cli_test', '{sample_conf}', 'CLI Imported Profile']);
        print(sprintf('RC=%d', rc));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('RC=0', proc.stdout)

    def test_rpcd_import_profile_and_batch_methods(self):
        """Test import_profile and import_batch methods via rpcd plugin."""
        wg_content = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.2/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.1:443
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        let plugin = loadfile('{self.plugin_path}')();
        let obj = plugin['luci.geovpn'];

        let res_single = obj.import_profile.call({{
            args: {{
                filename: 'single-rpcd.conf',
                content: {json.dumps(wg_content)}
            }}
        }});

        let res_batch = obj.import_batch.call({{
            args: {{
                items: [
                    {{ filename: 'batch-1.conf', content: {json.dumps(wg_content)} }}
                ]
            }}
        }});

        print(sprintf('%J', {{ single: res_single, batch: res_batch }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['single']['ok'])
        self.assertTrue(out['batch']['ok'])

    # ------------------------------------------------------------------------
    # 7. Additional Edge Cases & Robustness Fixes Verified
    # ------------------------------------------------------------------------

    def test_import_wg_without_private_key_using_shared_cred(self):
        """Import WireGuard profile lacking PrivateKey when pre-stored in shared cred set."""
        wg_no_key = """[Interface]
Address = 10.0.0.5/24
DNS = 1.1.1.1
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.2:443
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as cred from 'geovpn.cred';
        import * as drv_wg from 'geovpn.drivers.wireguard';
        import * as common from 'geovpn.drivers.common';

        let cid = 'c_prestored_wg';
        cred.store_wg_keys(cid, 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=', null);

        let res = importer.import_profile({{
            filename: 'no-key-profile.conf',
            content: {json.dumps(wg_no_key)},
            cred: cid
        }});

        let p = res.ok ? cfg.get_profile(res.id) : null;
        let ctx = res.ok ? common.create_context('active', res.id) : null;
        let prep = (res.ok && p && ctx) ? drv_wg.prepare(ctx, p) : null;

        print(sprintf('%J', {{
            res: res,
            profile: p,
            prep: prep
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'], out['res'].get('error'))
        self.assertEqual(out['profile']['cred'], 'c_prestored_wg')
        self.assertTrue(out['prep']['ok'])

    def test_shared_cred_no_key_duplication_on_disk(self):
        """Verify wg.key is not duplicated into profile directory when linked to shared cred."""
        wg_with_key = """[Interface]
PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
Address = 10.0.0.6/24
[Peer]
PublicKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMzQ=
Endpoint = 198.51.100.3:443
AllowedIPs = 0.0.0.0/0
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cfg from 'geovpn.config';
        import * as fs from 'fs';

        let cid = 'c_key_dedup';
        let res = importer.import_profile({{
            filename: 'dedup-test.conf',
            content: {json.dumps(wg_with_key)},
            cred: cid
        }});

        let pdir = cfg.get_profiles_dir() + '/' + res.id;
        let prof_has_key = fs.stat(pdir + '/wg.key') != null;

        print(sprintf('%J', {{
            res: res,
            prof_has_key: prof_has_key
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['res']['ok'])
        # The key should be stored in credentials/c_key_dedup, NOT duplicated in profiles/<id>/wg.key
        self.assertFalse(out['prof_has_key'])

    def test_needs_credentials_accuracy_with_cred_id(self):
        """Verify needs_credentials correctly reflects whether cred store holds secret."""
        ovpn_content = """client
dev tun
remote 198.51.100.4 1194 udp
auth-user-pass
"""
        script = f"""
        import * as importer from 'geovpn.import';
        import * as cred from 'geovpn.cred';

        // 1. Unpopulated credential set
        let res_empty = importer.import_profile({{
            name: 'Empty Cred Test',
            content: {json.dumps(ovpn_content)},
            cred: 'c_empty_set'
        }});

        // 2. Populated credential set
        cred.store_userpass('c_populated_set', 'user', 'pass');
        let res_pop = importer.import_profile({{
            name: 'Populated Cred Test',
            content: {json.dumps(ovpn_content)},
            cred: 'c_populated_set'
        }});

        print(sprintf('%J', {{
            empty_needs_cred: res_empty.needs_credentials,
            pop_needs_cred: res_pop.needs_credentials
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out['empty_needs_cred'])
        self.assertFalse(out['pop_needs_cred'])

    def test_cli_help_flag_and_stdin(self):
        """Test geovpn import CLI --help and reading from stdin (-)."""
        # 1. --help exit code 0
        script_help = """
        import { main } from 'geovpn.cli';
        let rc = main(['import', '--help']);
        print(sprintf('RC=%d', rc));
        """
        proc_help = self.run_ucode(script_help)
        self.assertEqual(proc_help.returncode, 0)
        self.assertIn('RC=0', proc_help.stdout)

        # 2. stdin (-) import
        sample_ovpn = "client\ndev tun\nremote 198.51.100.5 1194 udp\ncipher AES-256-GCM\n"
        script_stdin = f"""
        import * as importer from 'geovpn.import';
        let res = importer.import_profile({{
            filename: 'stdin',
            content: {json.dumps(sample_ovpn)},
            name: 'Stdin Imported'
        }});
        print(sprintf('%J', res));
        """
        proc_stdin = self.run_ucode(script_stdin)
        self.assertEqual(proc_stdin.returncode, 0)
        out = json.loads(proc_stdin.stdout)
        self.assertTrue(out['ok'])
        self.assertEqual(out['name'], 'Stdin Imported')

    def test_batch_directory_ignores_subdirectories_and_reports_empty(self):
        """Verify batch import ignores subdirs named .conf/.ovpn and reports empty dirs."""
        empty_dir = os.path.join(self.test_dir, 'empty_batch')
        os.makedirs(empty_dir, exist_ok=True)
        # Create a subdirectory named fake.conf
        os.makedirs(os.path.join(empty_dir, 'subfolder.conf'), exist_ok=True)

        script = f"""
        import * as importer from 'geovpn.import';
        let res = importer.import_batch('{empty_dir}');
        print(sprintf('%J', res));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0)
        out = json.loads(proc.stdout)
        # Should return ok: false with informative error because no regular config files exist
        self.assertFalse(out['ok'])
        self.assertIn('No .ovpn or .conf configuration files found', out['error'])

    def test_dedupe_keep_both_numeric_increment(self):
        """Verify keep_both correctly increments existing numeric suffix: (1), (2)."""
        ovpn = "client\ndev tun\nremote 198.51.100.6 1194 udp\n"
        script = f"""
        import * as importer from 'geovpn.import';

        let r1 = importer.import_profile({{ name: 'London City', content: {json.dumps(ovpn)} }});
        let r2 = importer.import_profile({{ name: 'London City', content: {json.dumps(ovpn)}, dedupe: 'keep_both' }});
        let r3 = importer.import_profile({{ name: 'London City', content: {json.dumps(ovpn)}, dedupe: 'keep_both' }});

        print(sprintf('%J', {{
            n1: r1.name,
            n2: r2.name,
            n3: r3.name
        }}));
        """
        proc = self.run_ucode(script)
        self.assertEqual(proc.returncode, 0)
        out = json.loads(proc.stdout)
        self.assertEqual(out['n1'], 'London City')
        self.assertEqual(out['n2'], 'London City (1)')
        self.assertEqual(out['n3'], 'London City (2)')

    def test_api_js_exports_import_methods(self):
        """Verify api.js declares and exports importProfile and importBatch."""
        api_path = os.path.join(self.repo_root, 'openwrt', 'luci-app-geovpn', 'htdocs', 'luci-static', 'resources', 'geovpn', 'api.js')
        with open(api_path) as f:
            code = f.read()
        self.assertIn("method: 'import_profile'", code)
        self.assertIn("method: 'import_batch'", code)
        self.assertIn("importProfile:", code)
        self.assertIn("importBatch:", code)

if __name__ == '__main__':
    unittest.main()
