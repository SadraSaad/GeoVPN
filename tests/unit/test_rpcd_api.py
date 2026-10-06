#!/usr/bin/env python3
"""
Unit tests for rpcd API contract and ACL configuration
"""
import unittest
import json
import os

EXPECTED_METHODS = {
    'status', 'logs', 'import_ovpn', 'profile_set_credentials',
    'profile_put_material', 'profile_delete', 'service', 'panic',
    'geo_catalog', 'geo_update', 'geo_update_status', 'test_target', 'diag'
}

class TestRpcdApi(unittest.TestCase):
    def test_acl_json_completeness(self):
        acl_path = os.path.join(os.path.dirname(__file__), '..', '..',
                                'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-geovpn.json')
        with open(acl_path) as f:
            acl = json.load(f)

        self.assertIn('luci-app-geovpn', acl)
        entry = acl['luci-app-geovpn']

        read_methods = set(entry.get('read', {}).get('ubus', {}).get('luci.geovpn', []))
        write_methods = set(entry.get('write', {}).get('ubus', {}).get('luci.geovpn', []))
        all_covered = read_methods.union(write_methods)

        self.assertEqual(all_covered, EXPECTED_METHODS)
        self.assertIn('geovpn', entry.get('read', {}).get('uci', []))
        self.assertIn('geovpn', entry.get('write', {}).get('uci', []))

    def test_rpcd_ucode_has_all_methods(self):
        uc_path = os.path.join(os.path.dirname(__file__), '..', '..',
                               'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'ucode', 'geovpn.uc')
        with open(uc_path) as f:
            code = f.read()

        for m in EXPECTED_METHODS:
            self.assertIn(f"{m}:", code, f"Method {m} missing from geovpn.uc")


if __name__ == '__main__':
    unittest.main()
