import json
import os
import subprocess
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
LUCI_APP = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn')

class TestLuciViews(unittest.TestCase):
    def test_menu_json_validity_and_routes(self):
        menu_path = os.path.join(LUCI_APP, 'root/usr/share/luci/menu.d/luci-app-geovpn.json')
        self.assertTrue(os.path.exists(menu_path), "menu.d json must exist")
        with open(menu_path, 'r', encoding='utf-8') as f:
            menu = json.load(f)

        expected_views = {
            "admin/vpn/geovpn/profiles": "geovpn/profiles",
            "admin/vpn/geovpn/split": "geovpn/split",
            "admin/vpn/geovpn/settings": "geovpn/settings",
            "admin/vpn/geovpn/logs": "geovpn/logs"
        }
        for route, view_path in expected_views.items():
            self.assertIn(route, menu, f"Route {route} must be defined")
            self.assertEqual(menu[route]['action']['path'], view_path)

    def test_all_js_syntax_clean(self):
        js_files = [
            'htdocs/luci-static/resources/geovpn/api.js',
            'htdocs/luci-static/resources/geovpn/widgets.js',
            'htdocs/luci-static/resources/geovpn/picker.js',
            'htdocs/luci-static/resources/view/geovpn/profiles.js',
            'htdocs/luci-static/resources/view/geovpn/split.js',
            'htdocs/luci-static/resources/view/geovpn/settings.js',
            'htdocs/luci-static/resources/view/geovpn/logs.js'
        ]
        for rel in js_files:
            full = os.path.join(LUCI_APP, rel)
            self.assertTrue(os.path.exists(full), f"{rel} must exist")
            res = subprocess.run(['node', '--check', full], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"node --check failed on {rel}: {res.stderr}")

    def test_no_inner_html_xss_vectors(self):
        js_files = [
            'htdocs/luci-static/resources/geovpn/api.js',
            'htdocs/luci-static/resources/geovpn/widgets.js',
            'htdocs/luci-static/resources/geovpn/picker.js',
            'htdocs/luci-static/resources/view/geovpn/profiles.js',
            'htdocs/luci-static/resources/view/geovpn/split.js',
            'htdocs/luci-static/resources/view/geovpn/settings.js',
            'htdocs/luci-static/resources/view/geovpn/logs.js'
        ]
        for rel in js_files:
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

if __name__ == '__main__':
    unittest.main()
