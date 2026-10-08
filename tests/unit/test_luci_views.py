import json
import os
import re
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
LUCI_APP = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn')

ALL_JS_FILES = [
    'htdocs/luci-static/resources/geovpn/api.js',
    'htdocs/luci-static/resources/geovpn/widgets.js',
    'htdocs/luci-static/resources/geovpn/picker.js',
    'htdocs/luci-static/resources/view/geovpn/profiles.js',
    'htdocs/luci-static/resources/view/geovpn/importer.js',
    'htdocs/luci-static/resources/view/geovpn/testpanel.js',
    'htdocs/luci-static/resources/view/geovpn/autoconnect.js',
    'htdocs/luci-static/resources/view/geovpn/split.js',
    'htdocs/luci-static/resources/view/geovpn/settings.js',
    'htdocs/luci-static/resources/view/geovpn/logs.js'
]

class TestLuciViews(unittest.TestCase):
    def test_menu_json_validity_and_routes(self):
        menu_path = os.path.join(LUCI_APP, 'root/usr/share/luci/menu.d/luci-app-geovpn.json')
        self.assertTrue(os.path.exists(menu_path), "menu.d json must exist")
        with open(menu_path, 'r', encoding='utf-8') as f:
            menu = json.load(f)

        expected_views = {
            "admin/vpn/geovpn/profiles": "geovpn/profiles",
            "admin/vpn/geovpn/importer": "geovpn/importer",
            "admin/vpn/geovpn/testpanel": "geovpn/testpanel",
            "admin/vpn/geovpn/autoconnect": "geovpn/autoconnect",
            "admin/vpn/geovpn/split": "geovpn/split",
            "admin/vpn/geovpn/settings": "geovpn/settings",
            "admin/vpn/geovpn/logs": "geovpn/logs"
        }
        for route, view_path in expected_views.items():
            self.assertIn(route, menu, f"Route {route} must be defined")
            self.assertEqual(menu[route]['action']['path'], view_path)

    def test_all_js_syntax_clean(self):
        for rel in ALL_JS_FILES:
            full = os.path.join(LUCI_APP, rel)
            self.assertTrue(os.path.exists(full), f"{rel} must exist")
            res = subprocess.run(['node', '--check', full], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"node --check failed on {rel}: {res.stderr}")

    def test_no_inner_html_xss_vectors(self):
        for rel in ALL_JS_FILES:
            full = os.path.join(LUCI_APP, rel)
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
                self.assertNotIn('innerHTML', content, f"Forbidden innerHTML found in {rel}")
                self.assertNotIn('eval(', content, f"Forbidden eval found in {rel}")

    def test_css_rtl_logical_properties(self):
        css_path = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/geovpn/geovpn.css')
        self.assertTrue(os.path.exists(css_path))
        with open(css_path, 'r', encoding='utf-8') as f:
            css = f.read()
            self.assertIn('direction: ltr', css)
            self.assertIn('unicode-bidi', css)
            self.assertIn('margin-inline-start', css)

    def test_all_js_return_baseclass_or_view_subclass(self):
        for rel in ALL_JS_FILES:
            full = os.path.join(LUCI_APP, rel)
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
            self.assertRegex(
                content,
                r'return\s+(baseclass|view)\.extend\(',
                f"{rel} must return baseclass.extend or view.extend to be a valid LuCI constructor"
            )

    def test_po_translation_coverage_100_percent(self):
        pot_path = os.path.join(LUCI_APP, 'po/templates/geovpn.pot')
        po_path = os.path.join(LUCI_APP, 'po/fa/geovpn.po')
        self.assertTrue(os.path.exists(pot_path))
        self.assertTrue(os.path.exists(po_path))

        with open(pot_path, 'r', encoding='utf-8') as f:
            pot = f.read()
        with open(po_path, 'r', encoding='utf-8') as f:
            po = f.read()

        msgids = set(re.findall(r'msgid "((?:[^"\\]|\\.)*)"', pot))
        translated = dict(re.findall(r'msgid "((?:[^"\\]|\\.)*)"\s+msgstr "((?:[^"\\]|\\.)*)"', po))

        missing = [m for m in msgids if (m not in translated or translated[m] == '') and m != '']
        self.assertEqual(len(missing), 0, f"Persian translation must be 100% complete. Missing: {missing[:10]}")

    def test_write_only_secret_inputs_in_profiles_and_importer(self):
        profiles_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(profiles_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('autocomplete\': \'new-password\'', content)
        self.assertIn('Write-only', content)

    def test_testpanel_polling_lifecycle_and_connect_best(self):
        tp_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/testpanel.js')
        with open(tp_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('testStatus', content)
        self.assertIn('testCancel', content)
        self.assertIn('testCleanup', content)
        self.assertIn('connectToBestProfile', content)
        self.assertIn('stopPolling', content)

    def test_importer_honest_limitations_notice(self):
        imp_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/importer.js')
        with open(imp_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('Stealth', content)
        self.assertIn('WStunnel', content)
        self.assertIn('importBatch', content)

    def test_all_js_ui_strings_present_in_pot(self):
        pot_path = os.path.join(LUCI_APP, 'po/templates/geovpn.pot')
        with open(pot_path, 'r', encoding='utf-8') as f:
            pot_content = f.read()
        pot_msgids = {m.replace(r'\"', '"') for m in re.findall(r'msgid "((?:[^"\\]|\\.)*)"', pot_content)}

        js_strings = set()
        for rel in ALL_JS_FILES:
            full = os.path.join(LUCI_APP, rel)
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
            for m in re.finditer(r'_\(\s*([\"\'])(.*?)\1\s*\)', content, re.DOTALL):
                js_strings.add(m.group(2))

        missing_in_pot = [s for s in js_strings if s not in pot_msgids]
        self.assertEqual(len(missing_in_pot), 0, f"All JS UI strings must be in geovpn.pot: {missing_in_pot}")

    def test_rpcd_extra_methods_evaluation(self):
        ucode_bin = os.path.join(REPO_ROOT, 'tools', 'bin', 'ucode')
        lib_path = os.path.join(REPO_ROOT, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        plugin_path = os.path.join(LUCI_APP, 'root/usr/share/rpcd/ucode/geovpn.uc')

        if not os.path.exists(ucode_bin) or subprocess.run([ucode_bin, '-e', '1'], capture_output=True).returncode != 0:
            self.skipTest("ucode binary not available")

        script = f"""
        let plugin = loadfile('{plugin_path}')();
        let obj = plugin['luci.geovpn'];
        let req_methods = [
            'test_start', 'test_status', 'test_cancel', 'test_cleanup',
            'test_results', 'import_batch', 'import_profile',
            'list_credentials', 'save_credential', 'delete_credential',
            'autoconnect_status'
        ];
        let missing = [];
        for (let m in req_methods) {{
            if (!obj[m] || type(obj[m].call) != 'function') push(missing, m);
        }}
        print(sprintf('%J', {{ missing: missing }}));
        """
        proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertEqual(len(out['missing']), 0, f"Missing rpcd extra methods: {out['missing']}")

    def test_profiles_js_openvpn_cred_and_save_raw_extra_args(self):
        profiles_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(profiles_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('ovpnCredSelect', content)
        self.assertIn('Shared Credential Set', content)

        api_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/geovpn/api.js')
        with open(api_js, 'r', encoding='utf-8') as f:
            api_content = f.read()
        self.assertIn('callProfileSaveRawRpc', api_content)

    def test_importer_preset_propagation_and_batch_chunking(self):
        imp_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/importer.js')
        with open(imp_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('selectedPreset', content)
        self.assertIn('CHUNK_SIZE = 50', content)
        self.assertIn('showImportReport', content)

    def test_latency_median_ms_handling(self):
        tp_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/testpanel.js')
        with open(tp_js, 'r', encoding='utf-8') as f:
            tp_content = f.read()
        self.assertIn('median_ms', tp_content)

        profiles_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(profiles_js, 'r', encoding='utf-8') as f:
            prof_content = f.read()
        self.assertIn('median_ms', prof_content)

    def test_missing_driver_warning_banners_in_profiles_view(self):
        """Assert profiles.js displays polite package installation notices for missing drivers (AT-37)."""
        profiles_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(profiles_js, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn('apk add geovpn-wireguard', content)
        self.assertIn('apk add geovpn-ikev2', content)
        self.assertIn('statusData.drivers.wireguard', content)
        self.assertIn('statusData.drivers.ikev2', content)

if __name__ == '__main__':
    unittest.main()
