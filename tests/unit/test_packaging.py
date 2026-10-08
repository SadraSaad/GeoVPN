#!/usr/bin/env python3
"""
Packaging, distribution and release feeds unit tests (Phase A8 / §11 A8).
Validates package Makefiles, versions (1.1.0), dependencies, conffiles,
install directives, file permissions, sysupgrade keep.d completeness,
and golden baseline regression (0-byte difference).
"""
import os
import stat
import unittest
import subprocess
import json
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))

class TestPackagingAndDistribution(unittest.TestCase):
    def setUp(self):
        self.makefiles = [
            'openwrt/geovpn/Makefile',
            'openwrt/geovpn-core/Makefile',
            'openwrt/geovpn-wireguard/Makefile',
            'openwrt/geovpn-ikev2/Makefile',
            'openwrt/geovpn-full/Makefile',
            'openwrt/luci-app-geovpn/Makefile',
            'openwrt/geovpn-data-seed/Makefile'
        ]

    def test_package_makefiles_exist_and_metadata(self):
        """Assert all 7 package Makefiles exist, define valid metadata and licenses."""
        for rel in self.makefiles:
            full = os.path.join(REPO_ROOT, rel)
            self.assertTrue(os.path.exists(full), f"{rel} must exist")
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
                self.assertTrue(
                    'PKGARCH:=all' in content or 'LUCI_PKGARCH:=all' in content,
                    f"{rel} must be architecture-independent (PKGARCH:=all)"
                )
                self.assertTrue(
                    'Apache-2.0' in content or 'CC0-1.0' in content,
                    f"{rel} must have valid license"
                )
                self.assertIn('GeoVPN Developers', content, f"{rel} must define maintainer")

    def test_package_versions_v1_1_0(self):
        """Assert all v1.1 packages define PKG_VERSION:=1.1.0 and seed package is 1.0.0."""
        v1_1_packages = [
            'openwrt/geovpn/Makefile',
            'openwrt/geovpn-core/Makefile',
            'openwrt/geovpn-wireguard/Makefile',
            'openwrt/geovpn-ikev2/Makefile',
            'openwrt/geovpn-full/Makefile',
            'openwrt/luci-app-geovpn/Makefile'
        ]
        for rel in v1_1_packages:
            full = os.path.join(REPO_ROOT, rel)
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
                self.assertIn('PKG_VERSION:=1.1.0', content, f"{rel} must have version 1.1.0")

        # geovpn-data-seed is kept compatible and intact at 1.0.0
        seed_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-data-seed/Makefile')
        with open(seed_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('PKG_VERSION:=1.0.0', content, "geovpn-data-seed must have version 1.0.0")

    def test_geovpn_core_dependencies_and_lifecycle(self):
        """Assert geovpn-core dependencies, conffiles, install dirs and lifecycle hooks."""
        core_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/Makefile')
        with open(core_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            # Runtime dependencies
            self.assertIn('+openvpn-openssl', content)
            self.assertIn('+kmod-tun', content)
            self.assertIn('+firewall4', content)
            self.assertIn('+nftables-json', content)
            self.assertIn('+ip-full', content)
            self.assertIn('+dnsmasq-full', content)
            self.assertIn('+usign', content)
            self.assertIn('+ucode', content)
            self.assertIn('+ucode-mod-fs', content)
            self.assertIn('+ucode-mod-uci', content)
            self.assertIn('+ucode-mod-ubus', content)
            self.assertIn('+ucode-mod-uloop', content)
            self.assertIn('+ucode-mod-resolv', content)
            self.assertIn('+uclient-fetch', content)
            # Conffiles
            self.assertIn('define Package/geovpn-core/conffiles', content)
            self.assertIn('/etc/config/geovpn', content)
            # Install directives & permissions
            self.assertIn('/etc/geovpn/credentials', content)
            self.assertIn('chmod 0700', content)
            self.assertIn('chmod 0755', content)
            self.assertIn('chmod 0600 $(1)/etc/config/geovpn', content)
            # Idempotent lifecycle hooks
            self.assertIn('define Package/geovpn-core/postinst', content)
            self.assertIn('90-geovpn', content)
            self.assertIn('91-geovpn-migrate', content)
            self.assertIn('define Package/geovpn-core/prerm', content)
            self.assertIn('geovpn test-cleanup', content)
            self.assertIn('geovpn panic', content)
            self.assertIn('define Package/geovpn-core/postrm', content)

    def test_geovpn_wireguard_dependencies(self):
        """Assert geovpn-wireguard dependencies (+geovpn-core +kmod-wireguard +wireguard-tools)."""
        wg_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-wireguard/Makefile')
        with open(wg_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn-core', content)
            self.assertIn('+kmod-wireguard', content)
            self.assertIn('+wireguard-tools', content)

    def test_geovpn_ikev2_dependencies(self):
        """Assert geovpn-ikev2 dependencies on core, xfrm interface and strongswan."""
        ike_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-ikev2/Makefile')
        with open(ike_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn-core', content)
            self.assertIn('+kmod-xfrm-interface', content)
            self.assertIn('+strongswan-charon', content)
            self.assertIn('+strongswan-swanctl', content)
            self.assertIn('+strongswan-mod-kernel-netlink', content)
            self.assertIn('+strongswan-mod-socket-default', content)
            self.assertIn('+strongswan-mod-eap-mschapv2', content)
            self.assertIn('+strongswan-mod-xauth-generic', content)
            self.assertIn('+strongswan-mod-openssl', content)
            self.assertIn('+strongswan-mod-vici', content)

    def test_luci_app_geovpn_dependencies(self):
        """Assert luci-app-geovpn dependencies on core, luci-base and rpcd."""
        luci_mf = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/Makefile')
        with open(luci_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn-core', content)
            self.assertIn('+luci-base', content)
            self.assertIn('+rpcd', content)
            self.assertIn('+rpcd-mod-ucode', content)

    def test_geovpn_meta_package_dependencies(self):
        """Assert geovpn meta-package depends on core + openvpn + luci + seed."""
        mf = os.path.join(REPO_ROOT, 'openwrt/geovpn/Makefile')
        with open(mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn-core', content)
            self.assertIn('+openvpn-openssl', content)
            self.assertIn('+luci-app-geovpn', content)
            self.assertIn('+geovpn-data-seed', content)

    def test_geovpn_full_meta_package_dependencies(self):
        """Assert geovpn-full meta-package depends on geovpn + wireguard + ikev2."""
        mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-full/Makefile')
        with open(mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn', content)
            self.assertIn('+geovpn-wireguard', content)
            self.assertIn('+geovpn-ikev2', content)

    def test_geovpn_data_seed_compatibility(self):
        """Assert geovpn-data-seed depends on geovpn-core and installs seed files."""
        mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-data-seed/Makefile')
        with open(mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+geovpn-core', content)
            self.assertIn('/etc/geovpn/data/ip', content)
            self.assertIn('/etc/geovpn/data/catalog', content)

    def test_sysupgrade_keep_settings_completeness(self):
        """Assert /lib/upgrade/keep.d/geovpn preserves config, profiles, credentials, backups, custom catalogs."""
        keep_path = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/files/lib/upgrade/keep.d/geovpn')
        self.assertTrue(os.path.exists(keep_path), "keep.d/geovpn must exist")
        with open(keep_path, 'r', encoding='utf-8') as f:
            lines = [l.strip() for l in f.readlines() if l.strip() and not l.startswith('#')]
            self.assertIn('/etc/config/geovpn', lines)
            self.assertIn('/etc/geovpn/profiles', lines)
            self.assertIn('/etc/geovpn/credentials', lines)
            self.assertIn('/etc/geovpn/backup', lines)
            self.assertIn('/etc/geovpn/keys', lines)
            self.assertIn('/etc/geovpn/data/catalog', lines)
            self.assertIn('/etc/geovpn/data/custom', lines)

    def test_file_permissions_in_source_tree(self):
        """Assert file modes: 0755 for bin/init/libexec/hooks, 0644 for configs/ucode/json/etc."""
        files_root = os.path.join(REPO_ROOT, 'openwrt', 'geovpn-core', 'files')
        executable_prefixes = [
            'usr/bin/',
            'usr/libexec/',
            'etc/init.d/',
            'etc/uci-defaults/',
            'etc/hotplug.d/'
        ]
        for root, _, files in os.walk(files_root):
            for fname in files:
                fpath = os.path.join(root, fname)
                mode = stat.S_IMODE(os.stat(fpath).st_mode)
                rel = os.path.relpath(fpath, files_root)
                is_exec = any(rel.startswith(p) for p in executable_prefixes)
                if is_exec:
                    self.assertEqual(
                        mode, 0o755,
                        f"Executable {rel} must have mode 0755 (got {oct(mode)})"
                    )
                else:
                    self.assertEqual(
                        mode, 0o644,
                        f"Non-executable file {rel} must have mode 0644 (got {oct(mode)})"
                    )

    def test_golden_baseline_fixtures_zero_difference(self):
        """Assert all 10 golden baseline fixtures pass with 0-byte difference."""
        unit_dir = os.path.dirname(os.path.abspath(__file__))
        if unit_dir not in sys.path:
            sys.path.insert(0, unit_dir)
        try:
            from test_golden_baseline import TestGoldenBaseline
        except ImportError:
            from tests.unit.test_golden_baseline import TestGoldenBaseline

        suite = unittest.TestLoader().loadTestsFromTestCase(TestGoldenBaseline)
        result = unittest.TestResult()
        suite.run(result)
        self.assertEqual(len(result.failures), 0, f"Failures in golden baseline: {result.failures}")
        self.assertEqual(len(result.errors), 0, f"Errors in golden baseline: {result.errors}")
        self.assertEqual(result.testsRun, 10, f"Expected 10 golden baseline tests, ran {result.testsRun}")

    def test_readmes_exist_and_consistent(self):
        """Assert README.md and README.fa.md exist and document installation and core commands."""
        en_path = os.path.join(REPO_ROOT, 'README.md')
        fa_path = os.path.join(REPO_ROOT, 'README.fa.md')
        self.assertTrue(os.path.exists(en_path), "README.md must exist")
        self.assertTrue(os.path.exists(fa_path), "README.fa.md must exist")

        with open(en_path, 'r', encoding='utf-8') as f:
            en = f.read()
            self.assertIn('apk add geovpn', en)
            self.assertIn('apk add geovpn-full', en)
            self.assertIn('dnsmasq-full', en)
            self.assertIn('geovpn panic', en)
            self.assertIn('geovpn purge', en)
            self.assertIn('geovpn-wireguard', en)
            self.assertIn('geovpn-ikev2', en)

        with open(fa_path, 'r', encoding='utf-8') as f:
            fa = f.read()
            self.assertIn('apk add geovpn', fa)
            self.assertIn('apk add geovpn-full', fa)
            self.assertIn('dnsmasq-full', fa)
            self.assertIn('geovpn panic', fa)
            self.assertIn('geovpn purge', fa)
            self.assertIn('geovpn-wireguard', fa)
            self.assertIn('geovpn-ikev2', fa)

    def test_mk_feed_generates_checksums_and_copies_packages(self):
        """Assert tools/mk-feed.sh copies APKs and generates SHA256SUMS inside the feed directory."""
        import tempfile
        import hashlib

        with tempfile.TemporaryDirectory() as td:
            pkg_dir = os.path.join(td, 'out_pkgs')
            feed_dir = os.path.join(td, 'feed_2512')
            os.makedirs(pkg_dir, exist_ok=True)

            dummy_name = 'geovpn-test_1.1.0-1_all.apk'
            dummy_content = b'PK\x03\x04mock-apk-payload'
            with open(os.path.join(pkg_dir, dummy_name), 'wb') as f:
                f.write(dummy_content)

            script = os.path.join(REPO_ROOT, 'tools', 'mk-feed.sh')
            res = subprocess.run([script, pkg_dir, feed_dir], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"mk-feed.sh failed: {res.stderr}\n{res.stdout}")

            copied_apk = os.path.join(feed_dir, dummy_name)
            self.assertTrue(os.path.exists(copied_apk), f"{dummy_name} must be copied to feed_dir")

            sums_file = os.path.join(feed_dir, 'SHA256SUMS')
            self.assertTrue(os.path.exists(sums_file), "SHA256SUMS must be generated in feed_dir")
            with open(sums_file, 'r', encoding='utf-8') as f:
                sums_content = f.read()
                expected_hash = hashlib.sha256(dummy_content).hexdigest()
                self.assertIn(expected_hash, sums_content)
                self.assertIn(dummy_name, sums_content)

    def test_at37_optional_packages_absent_hints_and_safety(self):
        """AT-37: Assert optional packages absent handling (hints, no crash, driver_missing)."""
        common_uc = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/files/usr/share/ucode/geovpn/drivers/common.uc')
        with open(common_uc, 'r', encoding='utf-8') as f:
            c = f.read()
            self.assertIn('function list_drivers()', c)
            self.assertIn('function available(proto)', c)

        te_uc = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/files/usr/share/ucode/geovpn/test_engine.uc')
        with open(te_uc, 'r', encoding='utf-8') as f:
            c = f.read()
            self.assertIn("reason: 'driver_missing'", c)

        prof_js = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/htdocs/luci-static/resources/view/geovpn/profiles.js')
        with open(prof_js, 'r', encoding='utf-8') as f:
            c = f.read()
            self.assertIn('apk add geovpn-wireguard', c)
            self.assertIn('apk add geovpn-ikev2', c)

    def test_at39_translation_coverage_and_rtl_token_isolation(self):
        """AT-39: Assert complete Persian translations and bidirectional token isolation."""
        import re

        pot_path = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/templates/geovpn.pot')
        po_path = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/fa/geovpn.po')
        self.assertTrue(os.path.exists(pot_path))
        self.assertTrue(os.path.exists(po_path))

        with open(pot_path, 'r', encoding='utf-8') as f:
            pot_content = f.read()
        with open(po_path, 'r', encoding='utf-8') as f:
            po_content = f.read()

        msgids = set(re.findall(r'msgid "((?:[^"\\]|\\.)*)"', pot_content))
        translated = dict(re.findall(r'msgid "((?:[^"\\]|\\.)*)"\s+msgstr "((?:[^"\\]|\\.)*)"', po_content))
        missing = [m for m in msgids if (m not in translated or translated[m] == '') and m != '']
        self.assertEqual(len(missing), 0, f"Untranslated strings found in po: {missing}")

        css_path = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/htdocs/luci-static/resources/geovpn/geovpn.css')
        with open(css_path, 'r', encoding='utf-8') as f:
            css = f.read()
            self.assertIn('direction: ltr', css)
            self.assertIn('unicode-bidi', css)

    def test_at40_prerm_and_postrm_lifecycle_cleanliness(self):
        """AT-40: Assert lifecycle prerm and postrm scripts across all packages leave no orphan artifacts."""
        # geovpn-core prerm and postrm
        core_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/Makefile')
        with open(core_mf, 'r', encoding='utf-8') as f:
            core = f.read()
            self.assertIn('geovpn test-cleanup', core)
            self.assertIn('geovpn panic', core)
            self.assertIn('geovpn-test stop', core)
            self.assertIn('/# geovpn health begin/', core)
            self.assertIn('/# geovpn update begin/', core)
            self.assertIn('cron restart', core)
            self.assertIn('rm -f /tmp/dnsmasq.d/geovpn.conf', core)
            self.assertIn('rm -rf /var/run/geovpn', core)

        # geovpn-wireguard prerm
        wg_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-wireguard/Makefile')
        with open(wg_mf, 'r', encoding='utf-8') as f:
            wg = f.read()
            self.assertIn('Package/geovpn-wireguard/prerm', wg)
            self.assertIn('ip link del dev geovpn0', wg)

        # geovpn-ikev2 prerm
        ike_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-ikev2/Makefile')
        with open(ike_mf, 'r', encoding='utf-8') as f:
            ike = f.read()
            self.assertIn('Package/geovpn-ikev2/prerm', ike)
            self.assertIn('swanctl --terminate --ike gv_active', ike)
            self.assertIn('swanctl --unload-conn --name gv_active', ike)
            self.assertIn('ip link del dev geovpn0', ike)

if __name__ == '__main__':
    unittest.main()
