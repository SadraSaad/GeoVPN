#!/usr/bin/env python3
"""
Unit tests for GeoVPN dnsmasq Integration and Configuration Generator
"""
import unittest

MAX_DOMAINS_PER_LINE = 48
MAX_LINE_BYTES = 900

def chunk_domains(domains, max_count=MAX_DOMAINS_PER_LINE, max_bytes_prefix=40):
    chunks = []
    current = []
    current_len = 0
    for d in domains:
        d_len = len(d) + 1
        if len(current) >= max_count or (current_len + d_len + max_bytes_prefix) > MAX_LINE_BYTES:
            if current:
                chunks.append(current)
            current = [d]
            current_len = d_len
        else:
            current.append(d)
            current_len += d_len
    if current:
        chunks.append(current)
    return chunks

def render_dnsmasq_conf_mock(config, geosite_domains, active_profile):
    main = config.get('main', {})
    mode = main.get('mode', 'bypass')
    direct_dns = '192.0.2.1'
    vpn_dns = '1.1.1.1'

    lines = [
        '# Managed by GeoVPN — do not edit manually'
    ]

    if mode == 'bypass':
        lines.append('no-resolv')
        lines.append(f'server={vpn_dns}')

    # 1. Infra domains (VPN server hostnames)
    infra_domains = []
    if active_profile:
        for r in active_profile.get('remotes', []):
            host = r.split()[0]
            if not host.replace('.', '').isdigit():
                infra_domains.append(host)

    for chunk in chunk_domains(infra_domains):
        d_spec = '/' + '/'.join(chunk) + '/'
        lines.append(f'server={d_spec}{direct_dns}')
        lines.append(f'nftset={d_spec}4#inet#geovpn#always4_dyn,6#inet#geovpn#always6_dyn')

    # 2. GeoSite domains
    geo_dns = direct_dns if mode == 'bypass' else vpn_dns
    for chunk in chunk_domains(geosite_domains or []):
        d_spec = '/' + '/'.join(chunk) + '/'
        lines.append(f'server={d_spec}{geo_dns}')
        lines.append(f'nftset={d_spec}4#inet#geovpn#geo4_dyn,6#inet#geovpn#geo6_dyn')

    if main.get('dns_canary', 1) not in (0, '0', False):
        lines.append('address=/use-application-dns.net/')

    return '\n'.join(lines) + '\n'


class TestDnsGen(unittest.TestCase):
    def test_chunking_domains_bounds(self):
        domains = [f"domain{i:03d}.example.com" for i in range(120)]
        chunks = chunk_domains(domains)

        self.assertTrue(len(chunks) >= 3)
        for c in chunks:
            self.assertTrue(len(c) <= MAX_DOMAINS_PER_LINE)
            total_len = sum(len(d) + 1 for d in c) + 40
            self.assertTrue(total_len <= MAX_LINE_BYTES)

    def test_dnsmasq_conf_bypass_mode(self):
        cfg = {'main': {'mode': 'bypass', 'dns_canary': '1'}}
        geosites = ['digikala.com', 'varzesh3.com']
        active_prof = {'remotes': ['vpn.server.net 1194 udp']}

        conf = render_dnsmasq_conf_mock(cfg, geosites, active_prof)

        self.assertIn('no-resolv\n', conf)
        self.assertIn('server=1.1.1.1\n', conf)
        self.assertIn('server=/vpn.server.net/192.0.2.1\n', conf)
        self.assertIn('nftset=/vpn.server.net/4#inet#geovpn#always4_dyn,6#inet#geovpn#always6_dyn\n', conf)
        self.assertIn('server=/digikala.com/varzesh3.com/192.0.2.1\n', conf)
        self.assertIn('address=/use-application-dns.net/\n', conf)

    def test_real_ucode_dnsgen(self):
        import os, subprocess
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
        lib_path = os.path.join(repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        try:
            if not os.path.exists(ucode_bin) or subprocess.run([ucode_bin, '-e', '1'], capture_output=True, timeout=2).returncode != 0:
                self.skipTest("ucode runtime not available")
        except Exception:
            self.skipTest("ucode runtime not available")

        script = """
        import * as dnsgen from 'geovpn.dnsgen';
        let cfg = { main: { mode: 'bypass', dns_canary: '1' } };
        let domains = ['digikala.com', 'varzesh3.com'];
        let prof = { remotes: ['vpn.server.net 1194 udp'] };
        let conf = dnsgen.render_dnsmasq_conf(cfg, domains, prof);
        print(conf);
        """
        proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, f"ucode error: {proc.stderr}")
        conf = proc.stdout
        self.assertIn('no-resolv\n', conf)
        self.assertIn('nftset=/vpn.server.net/4#inet#geovpn#always4_dyn,6#inet#geovpn#always6_dyn\n', conf)
        self.assertIn('nftset=/digikala.com/varzesh3.com/4#inet#geovpn#geo4_dyn,6#inet#geovpn#geo6_dyn\n', conf)
        self.assertIn('address=/use-application-dns.net/\n', conf)


if __name__ == '__main__':
    unittest.main()
