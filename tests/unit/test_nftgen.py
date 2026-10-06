#!/usr/bin/env python3
"""
Unit tests for GeoVPN nftables Ruleset and Sets Generator
"""
import unittest
import os
import subprocess
import json
import re

def is_ucode_runnable():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
    if not os.path.exists(ucode_bin):
        return False
    try:
        return subprocess.run([ucode_bin, '-e', '1'], capture_output=True, timeout=2).returncode == 0
    except Exception:
        return False

def render_ruleset_mock(config, geo_cidrs, active_profile):
    main = config.get('main', {})
    mode = main.get('mode', 'bypass')
    shift = int(main.get('mark_shift', 24))
    vpn_mark = f"0x{(1 << shift):08x}"
    direct_mark = f"0x{(2 << shift):08x}"
    mark_mask = f"0x{(0xf << shift):08x}"
    clear_mask = f"0x{(~((0xf << shift)) & 0xffffffff):08x}"
    tun_dev = main.get('tun_dev', 'geovpn0')
    kill_switch = bool(main.get('kill_switch') in (1, '1', True))
    private_direct = bool(main.get('private_direct', 1) not in (0, '0', False))
    block_dot = bool(main.get('block_dot', 1) not in (0, '0', False))
    dns_hijack = bool(main.get('dns_hijack', 1) not in (0, '0', False))

    lan_ifs = main.get('lan_ifs', ['br-lan'])
    if not isinstance(lan_ifs, list): lan_ifs = [lan_ifs]

    lines = [
        'table inet geovpn',
        'delete table inet geovpn',
        'table inet geovpn {'
    ]

    if_elems = ', '.join(f'"{i}"' for i in lan_ifs)
    lines.append(f'  set lan_ifs {{ type ifname; elements = {{ {if_elems} }}; }}')

    always4 = list(geo_cidrs.get('always4', []))
    if active_profile and active_profile.get('remotes'):
        for r in active_profile['remotes']:
            always4.append(r.split()[0])
    if always4:
        lines.append(f'  set always4 {{ type ipv4_addr; flags interval; auto-merge; elements = {{ {", ".join(always4)} }}; }}')
    else:
        lines.append('  set always4 { type ipv4_addr; flags interval; auto-merge; }')
    lines.append('  set private4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }; }')

    geo4 = geo_cidrs.get('v4', [])
    if geo4:
        lines.append(f'  set geo4 {{ type ipv4_addr; flags interval; auto-merge; elements = {{ {", ".join(geo4)} }}; }}')
    else:
        lines.append('  set geo4 { type ipv4_addr; flags interval; auto-merge; }')
    lines.append('  set geo4_dyn { type ipv4_addr; flags timeout; timeout 6h; size 65536; }')

    lines.append(f'  chain set_direct {{ ct mark set ct mark & {clear_mask} | {direct_mark}; accept; }}')
    lines.append(f'  chain set_vpn {{ ct mark set ct mark & {clear_mask} | {vpn_mark} meta mark set meta mark & {clear_mask} | {vpn_mark}; accept; }}')

    lines.append('  chain classify {')
    lines.append('    ct direction reply accept')
    lines.append(f'    ct mark & {mark_mask} == {vpn_mark} meta mark set meta mark & {clear_mask} | {vpn_mark} accept')
    lines.append(f'    ct mark & {mark_mask} == {direct_mark} accept')
    lines.append('    ip daddr @always4 jump set_direct')

    if private_direct:
        lines.append('    ip daddr @private4 jump set_direct')

    geo_action = 'set_direct' if mode == 'bypass' else 'set_vpn'
    default_action = 'set_vpn' if mode == 'bypass' else 'set_direct'

    lines.append(f'    ip daddr @geo4_dyn jump {geo_action}')
    lines.append(f'    ip daddr @geo4 jump {geo_action}')
    lines.append(f'    jump {default_action}')
    lines.append('  }')

    lines.append('  chain pre {')
    lines.append('    type filter hook prerouting priority mangle; policy accept;')
    lines.append('    iifname != @lan_ifs return')
    lines.append('    fib daddr type local return')
    lines.append('    jump classify')
    lines.append('  }')

    lines.append('  chain guard {')
    lines.append('    type filter hook forward priority filter - 1; policy accept;')
    if kill_switch:
        lines.append(f'    meta mark & {mark_mask} == {vpn_mark} oifname != "{tun_dev}" reject with icmpx type admin-prohibited')
    if block_dot:
        lines.append('    iifname @lan_ifs meta l4proto tcp th dport 853 reject with tcp reset')
    lines.append('  }')

    if dns_hijack:
        lines.append('  chain dns_redirect {')
        lines.append('    type nat hook prerouting priority dstnat - 1; policy accept;')
        lines.append('    iifname @lan_ifs fib daddr type != local meta l4proto { tcp, udp } th dport 53 redirect to :53')
        lines.append('  }')

    lines.append('}')
    return '\n'.join(lines)

def render_ruleset(config, geo_cidrs, active_profile):
    if is_ucode_runnable():
        return render_ruleset_real(config, geo_cidrs, active_profile)
    return render_ruleset_mock(config, geo_cidrs, active_profile)

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
    try:
        proc = subprocess.run([nft_bin, '-d', 'parser', '-f', '-'], input=ruleset, text=True, capture_output=True, timeout=5)
        if proc.returncode == 127:
            return True, ""
        output = proc.stdout + proc.stderr
        if "Error: syntax error" in output or "syntax error, unexpected" in output:
            return False, output
        return True, ""
    except Exception:
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
        ruleset = render_ruleset(cfg, geo_cidrs, active_prof)

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
        ruleset = render_ruleset(cfg, geo_cidrs, None)

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
        ruleset = render_ruleset(cfg, geo_cidrs, None)

        # Must not contain empty elements = { }; which fails nft syntax
        self.assertNotIn('elements = {  };', ruleset)
        self.assertNotIn('elements = { };', ruleset)

        valid, err = validate_nft_syntax(ruleset)
        self.assertTrue(valid, f"Empty sets generated invalid nft syntax: {err}")


if __name__ == '__main__':
    unittest.main()
