#!/usr/bin/env python3
"""
Unit test asserting that current rendering exactly reproduces the golden baseline fixtures.
Guarantees zero regression on baseline OpenVPN and split tunneling logic (AT-22 baseline check).
"""
import unittest
import os
import subprocess
import json
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

class TestGoldenBaseline(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.fixtures_dir = os.path.join(cls.repo_root, 'tests', 'fixtures', 'golden_baseline')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def test_golden_nft_bypass(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as nft from 'geovpn.nftgen';
        let cfg = { main: { mode: 'bypass', tun_dev: 'geovpn0', mark_shift: 24, kill_switch: 0, private_direct: 1, block_dot: 1, dns_hijack: 1, lan_ifs: ['br-lan'] } };
        let geo = { v4: ['5.160.0.0/12', '31.2.128.0/17'], v6: ['2a01:5ec0::/32'], always4: ['1.1.1.1'], always6: [] };
        let prof = { remotes: ['198.51.100.1 1194 udp'] };
        print(nft.render_ruleset(cfg, geo, prof));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'nft_bypass.golden.nft')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_nft_killswitch(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as nft from 'geovpn.nftgen';
        let cfg = { main: { mode: 'bypass', tun_dev: 'geovpn0', mark_shift: 24, kill_switch: 1, private_direct: 1, block_dot: 1, dns_hijack: 1, lan_ifs: ['br-lan'] } };
        let geo = { v4: ['5.160.0.0/12', '31.2.128.0/17'], v6: ['2a01:5ec0::/32'], always4: ['1.1.1.1'], always6: [] };
        let prof = { remotes: ['198.51.100.1 1194 udp'] };
        print(nft.render_ruleset(cfg, geo, prof));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'nft_bypass_killswitch.golden.nft')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_dnsmasq_bypass(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as dns from 'geovpn.dnsgen';
        let cfg = { main: { mode: 'bypass', dns_mode: 'follow', dns_direct_servers: ['192.168.1.1'], dns_vpn_servers: ['1.1.1.1', '9.9.9.9'], dns_canary: 1 }, rules: [] };
        let geosite = ['varzesh3.com', 'digikala.com'];
        let prof = { remotes: ['vpn.example.com 1194 udp'] };
        print(dns.render_dnsmasq_conf(cfg, geosite, prof));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'dnsmasq_bypass.golden.conf')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_ovpn_render(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as render from 'geovpn.ovpn_render';
        let prof = {
            remotes: ['vpn.example.com 1194 udp'],
            remote_cert_tls: 'server',
            cipher: 'AES-256-GCM',
            mssfix: 1450,
            tun_mtu: 1500,
            keepalive: '10 60',
            tls_kind: 'tls-crypt',
            auth_user_pass: true
        };
        let main = { tun_dev: 'geovpn0' };
        print(render.render_ovpn(prof, '/etc/geovpn/profiles/p12345678', main));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'ovpn_client.golden.conf')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_nft_include(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as nft from 'geovpn.nftgen';
        let cfg = { main: { mode: 'include', tun_dev: 'geovpn0', mark_shift: 24, kill_switch: 0, private_direct: 1, block_dot: 1, dns_hijack: 1, lan_ifs: ['br-lan'] } };
        let geo = { v4: ['5.160.0.0/12', '31.2.128.0/17'], v6: ['2a01:5ec0::/32'], always4: ['1.1.1.1'], always6: [] };
        let prof = { remotes: ['198.51.100.1 1194 udp'] };
        print(nft.render_ruleset(cfg, geo, prof));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'nft_include.golden.nft')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_dnsmasq_include(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as dns from 'geovpn.dnsgen';
        let cfg = { main: { mode: 'include', dns_mode: 'follow', dns_direct_servers: ['192.168.1.1'], dns_vpn_servers: ['1.1.1.1', '9.9.9.9'], dns_canary: 1 }, rules: [] };
        let geosite = ['varzesh3.com', 'digikala.com'];
        let prof = { remotes: ['vpn.example.com 1194 udp'] };
        print(dns.render_dnsmasq_conf(cfg, geosite, prof));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'dnsmasq_include.golden.conf')
        with open(golden_file) as f:
            expected = f.read()
        self.assertEqual(res.stdout, expected)

    def test_golden_route_killswitch_off(self):
        from test_route import build_route_commands
        cfg = {'rule_priority': 700, 'rt_table': 4200, 'mark_shift': 24, 'kill_switch': False}
        cmds, undo = build_route_commands(cfg)
        golden_file = os.path.join(self.fixtures_dir, 'route_killswitch_off.golden.json')
        with open(golden_file) as f:
            expected = json.load(f)
        self.assertEqual({'commands': cmds, 'undo': undo}, expected)

    def test_golden_route_killswitch_on(self):
        from test_route import build_route_commands
        cfg = {'rule_priority': 700, 'rt_table': 4200, 'mark_shift': 24, 'kill_switch': True}
        cmds, undo = build_route_commands(cfg)
        golden_file = os.path.join(self.fixtures_dir, 'route_killswitch_on.golden.json')
        with open(golden_file) as f:
            expected = json.load(f)
        self.assertEqual({'commands': cmds, 'undo': undo}, expected)

    def test_golden_status(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        script = '''
        import * as state from 'geovpn.state';
        print(sprintf('%J', state.get_state()));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'status.golden.json')
        with open(golden_file) as f:
            expected = json.load(f)
        self.assertEqual(json.loads(res.stdout), expected)

    def test_golden_rpcd_schema(self):
        if not self.has_ucode:
            self.skipTest("ucode binary not available")
        plugin_path = os.path.join(self.repo_root, 'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'ucode', 'geovpn.uc')
        script = f'''
        let plugin = loadfile('{plugin_path}')();
        let obj = plugin['luci.geovpn'];
        let schema = {{}};
        for (let m in keys(obj)) {{
            schema[m] = obj[m].args || {{}};
        }}
        print(sprintf('%J', schema));
        '''
        res = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        golden_file = os.path.join(self.fixtures_dir, 'rpcd_schema.golden.json')
        with open(golden_file) as f:
            expected = json.load(f)
        self.assertEqual(json.loads(res.stdout), expected)

if __name__ == '__main__':
    unittest.main()
