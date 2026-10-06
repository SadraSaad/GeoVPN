#!/usr/bin/env python3
"""
Unit tests for Firewall4 Zone and Forwarding UCI integration
"""
import unittest

def build_fw_sections(main_cfg):
    tun_dev = main_cfg.get('tun_dev', 'geovpn0')
    lan_zones = main_cfg.get('lan_zones', ['lan'])
    if not isinstance(lan_zones, list): lan_zones = [lan_zones]

    sections = {}
    sections['geovpn_zone'] = {
        'name': 'geovpn',
        'device': [tun_dev],
        'input': 'REJECT',
        'output': 'ACCEPT',
        'forward': 'REJECT',
        'masq': '1',
        'mtu_fix': '1'
    }

    for lz in lan_zones:
        sections[f'geovpn_fwd_{lz}'] = {
            'src': lz,
            'dest': 'geovpn'
        }

    return sections


class TestFwZone(unittest.TestCase):
    def test_firewall_zone_and_forwarding_structure(self):
        cfg = {'tun_dev': 'geovpn0', 'lan_zones': ['lan', 'guest']}
        sections = build_fw_sections(cfg)

        self.assertIn('geovpn_zone', sections)
        self.assertEqual(sections['geovpn_zone']['masq'], '1')
        self.assertEqual(sections['geovpn_zone']['mtu_fix'], '1')
        self.assertEqual(sections['geovpn_zone']['device'], ['geovpn0'])

        self.assertIn('geovpn_fwd_lan', sections)
        self.assertIn('geovpn_fwd_guest', sections)
        self.assertEqual(sections['geovpn_fwd_guest']['dest'], 'geovpn')


if __name__ == '__main__':
    unittest.main()
