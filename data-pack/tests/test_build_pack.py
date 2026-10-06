#!/usr/bin/env python3
"""
Unit tests for data pack compiler
"""
import unittest
import tempfile
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
from build_pack import collapse_subdomains, collapse_cidrs, build_data_pack, sha256_file

class TestBuildPack(unittest.TestCase):
    def test_collapse_subdomains(self):
        domains = [
            'example.com',
            'sub.example.com',
            'deep.sub.example.com',
            'other.org',
            'sub.other.org'
        ]
        collapsed = collapse_subdomains(domains)
        self.assertEqual(sorted(collapsed), ['example.com', 'other.org'])

    def test_collapse_cidrs(self):
        cidrs = [
            '192.168.1.0/24',
            '192.168.0.0/24',
            '10.0.0.0/16',
            '10.0.1.0/24' # Subset of 10.0.0.0/16
        ]
        v4, v6 = collapse_cidrs(cidrs)
        self.assertIn('10.0.0.0/16', v4)
        self.assertNotIn('10.0.1.0/24', v4)
        self.assertIn('192.168.0.0/23', v4)

    def test_build_pack_structure(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            build_id = build_data_pack(tmpdir, fixture_mode=True)
            self.assertTrue(os.path.exists(os.path.join(tmpdir, 'MANIFEST')))
            self.assertTrue(os.path.exists(os.path.join(tmpdir, 'catalog', 'geoip.tsv')))
            self.assertTrue(os.path.exists(os.path.join(tmpdir, 'catalog', 'geosite.tsv')))
            self.assertTrue(os.path.exists(os.path.join(tmpdir, 'ip', 'ir.v4.txt')))
            self.assertTrue(os.path.exists(os.path.join(tmpdir, 'site', 'category-ir.txt')))

            # Verify manifest pins catalog hashes
            with open(os.path.join(tmpdir, 'MANIFEST')) as f:
                manifest_text = f.read()

            geoip_hash = sha256_file(os.path.join(tmpdir, 'catalog', 'geoip.tsv'))
            self.assertIn(f"geoip_catalog_sha256={geoip_hash}", manifest_text)


if __name__ == '__main__':
    unittest.main()
