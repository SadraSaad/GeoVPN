#!/usr/bin/env python3
"""
Unit tests for GeoVPN Diagnostics and Path Testing Simulator
"""
import unittest

def ip_to_int(ip):
    parts = ip.split('.')
    return (int(parts[0]) << 24) + (int(parts[1]) << 16) + (int(parts[2]) << 8) + int(parts[3])

def match_cidr4(ip, cidr):
    if '/' not in cidr:
        return ip == cidr
    base, prefix_str = cidr.split('/')
    prefix = int(prefix_str)
    if prefix == 0: return True
    mask = ((1 << 32) - (1 << (32 - prefix))) & 0xffffffff
    return (ip_to_int(ip) & mask) == (ip_to_int(base) & mask)

def simulate_test_target(target, config, geo_data):
    mode = config.get('mode', 'bypass')
    is_domain = not target.replace('.', '').isdigit()

    resolved_ip = '185.147.178.1' if is_domain else target

    # 1. Check VPN server
    if target == config.get('vpn_server'):
        return {'verdict': 'direct', 'reason': 'vpn_server'}

    # 2. Check private
    if any(match_cidr4(resolved_ip, pc) for pc in ('10.0.0.0/8', '192.168.0.0/16', '172.16.0.0/12')):
        return {'verdict': 'direct', 'reason': 'private'}

    # 3. Check GeoSite
    if is_domain and target in geo_data.get('sites', {}):
        cat = geo_data['sites'][target]
        verdict = 'direct' if mode == 'bypass' else 'vpn'
        return {'verdict': verdict, 'reason': f'geosite:{cat}'}

    # 4. Check GeoIP
    for code, cidrs in geo_data.get('ips', {}).items():
        if any(match_cidr4(resolved_ip, c) for c in cidrs):
            verdict = 'direct' if mode == 'bypass' else 'vpn'
            return {'verdict': verdict, 'reason': f'geoip:{code}'}

    # 5. Default
    default_verdict = 'vpn' if mode == 'bypass' else 'direct'
    return {'verdict': default_verdict, 'reason': 'default'}


class TestDiag(unittest.TestCase):
    def test_cidr4_matching(self):
        self.assertTrue(match_cidr4('192.168.1.50', '192.168.1.0/24'))
        self.assertFalse(match_cidr4('192.168.2.50', '192.168.1.0/24'))
        self.assertTrue(match_cidr4('10.5.0.1', '10.0.0.0/8'))
        self.assertTrue(match_cidr4('1.2.3.4', '0.0.0.0/0'))

    def test_path_simulator_bypass_mode(self):
        cfg = {'mode': 'bypass', 'vpn_server': 'vpn.myprovider.com'}
        geo = {
            'sites': {'digikala.com': 'category-ir'},
            'ips': {'ir': ['185.0.0.0/16']}
        }

        # Listed domain -> direct
        res = simulate_test_target('digikala.com', cfg, geo)
        self.assertEqual(res['verdict'], 'direct')
        self.assertEqual(res['reason'], 'geosite:category-ir')

        # Unlisted external domain -> VPN
        res_ext = simulate_test_target('wikipedia.org', cfg, geo)
        self.assertEqual(res_ext['verdict'], 'vpn')
        self.assertEqual(res_ext['reason'], 'default')

        # VPN server endpoint -> direct
        res_vpn = simulate_test_target('vpn.myprovider.com', cfg, geo)
        self.assertEqual(res_vpn['verdict'], 'direct')

    def test_real_ucode_diag(self):
        import os, subprocess, json
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
        lib_path = os.path.join(repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        if not os.path.exists(ucode_bin):
            return

        script = """
        import * as diag from 'geovpn.diag';
        let m1 = diag.match_cidr4('192.168.1.50', '192.168.1.0/24');
        let m2 = diag.match_cidr4('192.168.2.50', '192.168.1.0/24');
        let t1 = diag.test_target('10.0.0.1');
        let t2 = diag.test_target('example.com');
        print(sprintf('%J', { m1: m1, m2: m2, t1: t1, t2: t2 }));
        """
        proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, f"ucode error: {proc.stderr}")
        res = json.loads(proc.stdout)
        self.assertTrue(res['m1'])
        self.assertFalse(res['m2'])
        # 10.0.0.1 must be recognized as IPv4 private direct, not domain
        self.assertEqual(res['t1']['kind'], 'ipv4')
        self.assertEqual(res['t1']['verdict'], 'direct')
        self.assertEqual(res['t1']['reason']['layer'], 'private')
        # example.com must be recognized as domain
        self.assertEqual(res['t2']['kind'], 'domain')


if __name__ == '__main__':
    unittest.main()
