#!/usr/bin/env python3
"""
Unit tests for GeoVPN nftables Ruleset and Sets Generator
"""
import unittest
import os
import subprocess
import json
import re

def render_ruleset_real(config, geo_cidrs, active_profile):
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
    lib_path = os.path.join(repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
    script = """
    import * as nftgen from 'geovpn.nftgen';
    import * as fs from 'fs';
    let input_data = json(fs.readfile('/dev/stdin'));
    let rules = nftgen.render_ruleset(input_data.config, input_data.geo_cidrs, input_data.active_profile);
    print(rules);
    """
    payload = json.dumps({'config': config, 'geo_cidrs': geo_cidrs, 'active_profile': active_profile})
    proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], input=payload, text=True, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ucode failed: {proc.stderr}")
    return proc.stdout

def validate_nft_syntax(ruleset):
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    nft_bin = os.path.join(repo_root, 'tools', 'bin', 'nft')
    proc = subprocess.run([nft_bin, '-d', 'parser', '-f', '-'], input=ruleset, text=True, capture_output=True)
    # Check if bison parser encountered any syntax error
    output = proc.stdout + proc.stderr
    if "Error: syntax error" in output or "syntax error, unexpected" in output:
        return False, output
    return True, ""


class TestNftGen(unittest.TestCase):
    def test_bypass_mode_rendering(self):
        cfg = {
            'main': {
                'mode': 'bypass',
                'kill_switch': '1',
                'lan_ifs': ['br-lan'],
                'mark_shift': '24'
            }
        }
        geo_cidrs = {'v4': ['5.1.0.0/16', '185.0.0.0/16'], 'v6': []}
        active_prof = {'remotes': ['198.51.100.1 1194 udp']}
        ruleset = render_ruleset_real(cfg, geo_cidrs, active_prof)

        self.assertIn('table inet geovpn', ruleset)
        self.assertIn('set lan_ifs { type ifname; elements = { "br-lan" }; }', ruleset)
        self.assertIn('5.1.0.0/16, 185.0.0.0/16', ruleset)
        self.assertTrue(re.search(r'ip\s+daddr\s+@geo4\s+jump\s+set_direct', ruleset))
        self.assertIn('jump set_vpn', ruleset)
        self.assertIn('oifname != "geovpn0" reject with icmpx type admin-prohibited', ruleset)
        self.assertIn('redirect to :53', ruleset)

        valid, err = validate_nft_syntax(ruleset)
        self.assertTrue(valid, f"nft syntax error: {err}")

    def test_include_mode_rendering(self):
        cfg = {
            'main': {
                'mode': 'include',
                'kill_switch': '0',
                'lan_ifs': ['br-lan']
            }
        }
        geo_cidrs = {'v4': ['103.0.0.0/16'], 'v6': []}
        ruleset = render_ruleset_real(cfg, geo_cidrs, None)

        self.assertTrue(re.search(r'ip\s+daddr\s+@geo4\s+jump\s+set_vpn', ruleset))
        self.assertIn('jump set_direct', ruleset)
        self.assertNotIn('reject with icmpx type admin-prohibited', ruleset)

        valid, err = validate_nft_syntax(ruleset)
        self.assertTrue(valid, f"nft syntax error: {err}")

    def test_empty_sets_valid_nft_syntax(self):
        cfg = {
            'main': {
                'mode': 'bypass',
                'kill_switch': '1',
                'lan_ifs': ['br-lan']
            }
        }
        geo_cidrs = {'v4': [], 'v6': []}
        ruleset = render_ruleset_real(cfg, geo_cidrs, None)

        # Must not contain empty elements = { }; which fails nft syntax
        self.assertNotIn('elements = {  };', ruleset)
        self.assertNotIn('elements = { };', ruleset)

        valid, err = validate_nft_syntax(ruleset)
        self.assertTrue(valid, f"Empty sets generated invalid nft syntax: {err}")


if __name__ == '__main__':
    unittest.main()
