import os
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))

class TestPackagingAndDistribution(unittest.TestCase):
    def test_package_makefiles(self):
        makefiles = [
            'openwrt/geovpn/Makefile',
            'openwrt/geovpn-core/Makefile',
            'openwrt/luci-app-geovpn/Makefile',
            'openwrt/geovpn-data-seed/Makefile'
        ]
        for rel in makefiles:
            full = os.path.join(REPO_ROOT, rel)
            self.assertTrue(os.path.exists(full), f"{rel} must exist")
            with open(full, 'r', encoding='utf-8') as f:
                content = f.read()
                self.assertIn('PKGARCH:=all', content, f"{rel} must be architecture-independent (all)")
                self.assertTrue('Apache-2.0' in content or 'CC0-1.0' in content, f"{rel} must have valid license")

    def test_geovpn_core_dependencies(self):
        core_mf = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/Makefile')
        with open(core_mf, 'r', encoding='utf-8') as f:
            content = f.read()
            self.assertIn('+openvpn-openssl', content)
            self.assertIn('+kmod-tun', content)
            self.assertIn('+firewall4', content)
            self.assertIn('+nftables-json', content)
            self.assertIn('+ip-full', content)
            self.assertIn('+dnsmasq-full', content)
            self.assertIn('+usign', content)
            self.assertIn('/etc/config/geovpn', content)
            self.assertIn('define Package/geovpn-core/postinst', content)
            self.assertIn('define Package/geovpn-core/prerm', content)
            self.assertIn('define Package/geovpn-core/postrm', content)

    def test_sysupgrade_keep_settings(self):
        keep_path = os.path.join(REPO_ROOT, 'openwrt/geovpn-core/files/lib/upgrade/keep.d/geovpn')
        self.assertTrue(os.path.exists(keep_path), "keep.d/geovpn must exist")
        with open(keep_path, 'r', encoding='utf-8') as f:
            lines = [l.strip() for l in f.readlines() if l.strip() and not l.startswith('#')]
            self.assertIn('/etc/config/geovpn', lines)
            self.assertIn('/etc/geovpn/profiles', lines)

    def test_readmes_exist_and_consistent(self):
        en_path = os.path.join(REPO_ROOT, 'README.md')
        fa_path = os.path.join(REPO_ROOT, 'README.fa.md')
        self.assertTrue(os.path.exists(en_path), "README.md must exist")
        self.assertTrue(os.path.exists(fa_path), "README.fa.md must exist")

        with open(en_path, 'r', encoding='utf-8') as f:
            en = f.read()
            self.assertIn('apk add geovpn', en)
            self.assertIn('dnsmasq-full', en)
            self.assertIn('geovpn panic', en)
            self.assertIn('geovpn purge', en)

        with open(fa_path, 'r', encoding='utf-8') as f:
            fa = f.read()
            self.assertIn('apk add geovpn', fa)
            self.assertIn('dnsmasq-full', fa)
            self.assertIn('geovpn panic', fa)
            self.assertIn('geovpn purge', fa)

if __name__ == '__main__':
    unittest.main()
