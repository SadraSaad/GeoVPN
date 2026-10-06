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

    def test_rpcd_runtime_evaluation(self):
        import subprocess
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
        lib_path = os.path.join(repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        plugin_path = os.path.join(repo_root, 'openwrt', 'luci-app-geovpn', 'root', 'usr', 'share', 'rpcd', 'ucode', 'geovpn.uc')
        try:
            if not os.path.exists(ucode_bin) or subprocess.run([ucode_bin, '-e', '1'], capture_output=True, timeout=2).returncode != 0:
                self.skipTest("ucode runtime not available")
        except Exception:
            self.skipTest("ucode runtime not available")

        script = f"""
        let plugin = loadfile('{plugin_path}')();
        let obj = plugin['luci.geovpn'];
        let methods = keys(obj);
        let catalog = obj.geo_catalog.call();
        print(sprintf('%J', {{ methods: methods, catalog: catalog }}));
        """
        proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, f"Failed to evaluate rpcd plugin: {proc.stderr}")
        res = json.loads(proc.stdout)
        self.assertEqual(set(res['methods']), EXPECTED_METHODS)
        self.assertIn('pack', res['catalog'])
        self.assertIn('items', res['catalog'])


if __name__ == '__main__':
    unittest.main()
