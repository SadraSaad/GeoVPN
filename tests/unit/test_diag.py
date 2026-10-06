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


if __name__ == '__main__':
    unittest.main()
