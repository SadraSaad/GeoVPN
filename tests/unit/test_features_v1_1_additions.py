#!/usr/bin/env python3
"""
Unit tests for GeoVPN v1.1 feature additions:
1. Manual IKEv2 / IPsec Profile Creation & Management (+ Add Profile modal)
2. Bilingual Persian & English UI Language Switcher
3. In-App GitHub Update Checker & One-Click Updater
4. GitHub Release & Packaging Documentation (GITHUB_RELEASE_GUIDE.md)
"""
import unittest
import os
import json
import re

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
LUCI_APP = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn')

class TestFeaturesV11Additions(unittest.TestCase):
    def test_github_release_guide_exists_and_content(self):
        """Verify docs/GITHUB_RELEASE_GUIDE.md exists and contains required sections."""
        guide_path = os.path.join(REPO_ROOT, 'docs', 'GITHUB_RELEASE_GUIDE.md')
        self.assertTrue(os.path.exists(guide_path), "docs/GITHUB_RELEASE_GUIDE.md must exist")

        with open(guide_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Both English and Persian sections
        self.assertIn('راهنمای جامع انتشار نسخه در گیت‌هاب', content)
        self.assertIn('GeoVPN GitHub Release & Automated Packaging Guide', content)

        # Version bumping in package Makefiles
        self.assertIn('PKG_VERSION', content)
        self.assertIn('openwrt/geovpn/Makefile', content)
        self.assertIn('openwrt/geovpn-core/Makefile', content)
        self.assertIn('openwrt/geovpn-ikev2/Makefile', content)
        self.assertIn('openwrt/luci-app-geovpn/Makefile', content)

        # Git tag and push instructions
        self.assertIn('git tag', content)
        self.assertIn('git push origin', content)

        # GitHub Actions and APK release assets
        self.assertIn('.github/workflows/release.yml', content)
        self.assertIn('build-sdk.sh', content)
        self.assertIn('softprops/action-gh-release', content)
        self.assertIn('.apk', content)

        # GitHub repository permissions (contents: write)
        self.assertIn('contents: write', content)
        self.assertIn('Workflow permissions', content)
        self.assertIn('Read and write permissions', content)

        # Router update and LuCI
        self.assertIn('به‌روزرسانی خودکار', content)
        self.assertIn('apk add --allow-untrusted', content)

    def test_profiles_view_add_profile_modal(self):
        """Verify profiles.js includes + Add Profile button and modal implementation."""
        profiles_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(profiles_js, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('+ Add Profile', content)
        self.assertIn('showAddProfileModal', content)
        self.assertIn('IKEv2 / IPsec (strongSwan)', content)
        self.assertIn('Server Hostname / IP', content)
        self.assertIn('autocomplete\': \'new-password\'', content)
        self.assertIn('Write-only: password is saved securely with 0600 permissions.', content)
        self.assertIn('geovpn-isrg-x1.pem', content)
        self.assertIn('api.addProfile', content)

    def test_settings_view_bilingual_switcher(self):
        """Verify settings.js includes Interface Language card with English and Persian."""
        settings_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/settings.js')
        with open(settings_js, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('Interface Language', content)
        self.assertIn('Display Language', content)
        self.assertIn('Apply Language', content)
        self.assertIn("'en'", content)
        self.assertIn("'fa'", content)
        self.assertIn('فارسی (Persian)', content)
        self.assertIn("uci.set('luci', 'main', 'lang'", content)
        self.assertIn("document.documentElement.setAttribute('dir', 'rtl')", content)
        self.assertIn("document.documentElement.setAttribute('dir', 'ltr')", content)

    def test_settings_view_updates_card(self):
        """Verify settings.js includes Updates & Version card and updater."""
        settings_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/view/geovpn/settings.js')
        with open(settings_js, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('Updates & Version', content)
        self.assertIn('Installed Version', content)
        self.assertIn('GitHub Repository', content)
        self.assertIn('https://github.com/SadraSaad/GeoVPN', content)
        self.assertIn('Check for Updates', content)
        self.assertIn('Update Now', content)
        self.assertIn('api.checkUpdate', content)
        self.assertIn('api.applyUpdate', content)

    def test_api_js_declares_new_methods(self):
        """Verify api.js declares profile_add, check_update, and apply_update."""
        api_js = os.path.join(LUCI_APP, 'htdocs/luci-static/resources/geovpn/api.js')
        with open(api_js, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('profile_add', content)
        self.assertIn('check_update', content)
        self.assertIn('apply_update', content)
        self.assertIn('addProfile:', content)
        self.assertIn('checkUpdate:', content)
        self.assertIn('applyUpdate:', content)

    def test_rpcd_acl_grants_new_methods_and_luci_uci(self):
        """Verify luci-app-geovpn.json ACL grants appropriate permissions."""
        acl_path = os.path.join(LUCI_APP, 'root/usr/share/rpcd/acl.d/luci-app-geovpn.json')
        with open(acl_path, 'r', encoding='utf-8') as f:
            acl = json.load(f)

        extra = acl.get('luci-app-geovpn-extra', {})
        self.assertIn('profile_add', extra.get('write', {}).get('ubus', {}).get('luci.geovpn', []))
        self.assertIn('check_update', extra.get('read', {}).get('ubus', {}).get('luci.geovpn', []))
        self.assertIn('apply_update', extra.get('write', {}).get('ubus', {}).get('luci.geovpn', []))
        self.assertIn('luci', extra.get('read', {}).get('uci', []))
        self.assertIn('luci', extra.get('write', {}).get('uci', []))

    def test_rpcd_ucode_implements_new_methods(self):
        """Verify geovpn.uc implements profile_add, check_update, and apply_update."""
        uc_path = os.path.join(LUCI_APP, 'root/usr/share/rpcd/ucode/geovpn.uc')
        with open(uc_path, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('profile_add:', content)
        self.assertIn('check_update:', content)
        self.assertIn('apply_update:', content)
        self.assertIn('--allow-untrusted', content)
        self.assertIn('SadraSaad/GeoVPN', content)
        self.assertIn('api.github.com', content)

    def test_release_workflow_has_write_permissions(self):
        """Verify .github/workflows/release.yml has contents: write permission."""
        wf_path = os.path.join(REPO_ROOT, '.github', 'workflows', 'release.yml')
        with open(wf_path, 'r', encoding='utf-8') as f:
            content = f.read()

        self.assertIn('permissions:', content)
        self.assertIn('contents: write', content)


if __name__ == '__main__':
    unittest.main()
