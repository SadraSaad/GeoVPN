import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
POT_PATH = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/templates/geovpn.pot')
PO_PATH = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/fa/geovpn.po')
CSS_PATH = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/htdocs/luci-static/resources/geovpn/geovpn.css')

class TestTranslationsAndRTL(unittest.TestCase):
    def test_pot_and_po_exist(self):
        self.assertTrue(os.path.exists(POT_PATH), "geovpn.pot must exist")
        self.assertTrue(os.path.exists(PO_PATH), "geovpn.po must exist")

    def test_persian_translation_completeness(self):
        with open(POT_PATH, 'r', encoding='utf-8') as f:
            pot_content = f.read()
        with open(PO_PATH, 'r', encoding='utf-8') as f:
            po_content = f.read()

        msgids = set(re.findall(r'msgid \"((?:[^\"\\\\]|\\\\.)*)\"', pot_content))
        translated = dict(re.findall(r'msgid \"((?:[^\"\\\\]|\\\\.)*)\"\s+msgstr \"((?:[^\"\\\\]|\\\\.)*)\"', po_content))

        # Filter header msgid ""
        content_msgids = {m for m in msgids if m.strip() != ''}
        missing = [m for m in content_msgids if m not in translated or translated[m].strip() == '']

        self.assertEqual(len(missing), 0, f"Found untranslated strings in Persian po: {missing}")
        self.assertGreater(len(content_msgids), 200, "Should have more than 200 translatable strings")

    def test_rtl_css_logical_properties(self):
        with open(CSS_PATH, 'r', encoding='utf-8') as f:
            css = f.read()

        # Check for logical properties
        self.assertIn('margin-inline-start', css)
        self.assertIn('[dir="rtl"]', css)
        self.assertIn('.gv-ltr', css)
        self.assertIn('unicode-bidi: isolate', css)

        # Confirm technical tokens class exists
        self.assertIn('direction: ltr !important;', css)

if __name__ == '__main__':
    unittest.main()
