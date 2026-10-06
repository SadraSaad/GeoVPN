#!/usr/bin/env python3
"""
Unit tests for GeoVPN nftables Ruleset and Sets Generator
"""
import unittest

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

    always4 = ', '.join(geo_cidrs.get('always4', []))
    lines.append(f'  set always4 {{ type ipv4_addr; flags interval; auto-merge; elements = {{ {always4} }}; }}')
    lines.append('  set private4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }; }')

    geo4 = ', '.join(geo_cidrs.get('v4', []))
    lines.append(f'  set geo4 {{ type ipv4_addr; flags interval; auto-merge; elements = {{ {geo4} }}; }}')
    lines.append('  set geo4_dyn { type ipv4_addr; flags timeout; timeout 6h; size 65536; }')

    lines.append(f'  chain set_direct {{ ct mark set ct mark & {clear_mask} | {direct_mark} accept }}')
    lines.append(f'  chain set_vpn {{ ct mark set ct mark & {clear_mask} | {vpn_mark} meta mark set meta mark & {clear_mask} | {vpn_mark} accept }}')

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
        geo_cidrs = {'v4': ['5.1.0.0/16', '185.0.0.0/16'], 'always4': ['198.51.100.1']}
        ruleset = render_ruleset_mock(cfg, geo_cidrs, None)

        self.assertIn('table inet geovpn', ruleset)
        self.assertIn('set lan_ifs { type ifname; elements = { "br-lan" }; }', ruleset)
        self.assertIn('5.1.0.0/16, 185.0.0.0/16', ruleset)
        self.assertIn('ip daddr @geo4 jump set_direct', ruleset)
        self.assertIn('jump set_vpn', ruleset)
        self.assertIn('oifname != "geovpn0" reject with icmpx type admin-prohibited', ruleset)
        self.assertIn('redirect to :53', ruleset)

    def test_include_mode_rendering(self):
        cfg = {
            'main': {
                'mode': 'include',
                'kill_switch': '0',
                'lan_ifs': ['br-lan']
            }
        }
        geo_cidrs = {'v4': ['103.0.0.0/16'], 'always4': []}
        ruleset = render_ruleset_mock(cfg, geo_cidrs, None)

        self.assertIn('ip daddr @geo4 jump set_vpn', ruleset)
        self.assertIn('jump set_direct', ruleset)
        self.assertNotIn('reject with icmpx type admin-prohibited', ruleset)


if __name__ == '__main__':
    unittest.main()
