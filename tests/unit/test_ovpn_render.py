#!/usr/bin/env python3
"""
Unit tests for OpenVPN Config Renderer (Golden File verification)
"""
import unittest

def render_ovpn(profile, profile_dir, main_cfg):
    tun_dev = main_cfg.get('tun_dev', 'geovpn0')
    lines = [
        '# Managed by GeoVPN — do not edit manually',
        'client',
        f'dev {tun_dev}',
        'dev-type tun',
        'nobind',
        'persist-key',
        'persist-tun'
    ]

    for r in profile.get('remotes', []):
        lines.append(f'remote {r}')

    if profile.get('remote_random'):
        lines.append('remote-random')

    if profile.get('remote_cert_tls') and profile['remote_cert_tls'] != 'none':
        lines.append(f"remote-cert-tls {profile['remote_cert_tls']}")

    lines.extend([
        'resolv-retry infinite',
        'connect-retry 5',
        f"keepalive {profile.get('keepalive', '10 60')}",
        'route-nopull',
        'pull-filter ignore "redirect-gateway"',
        'pull-filter ignore "block-outside-dns"',
        'script-security 2',
        'up /usr/libexec/geovpn/ovpn-hook',
        'down /usr/libexec/geovpn/ovpn-hook',
        'up-restart',
        'syslog geovpn',
        'verb 3'
    ])

    if profile.get('cipher'):
        lines.append(f"cipher {profile['cipher']}")
    if profile.get('mssfix'):
        lines.append(f"mssfix {profile['mssfix']}")
    if profile.get('tun_mtu'):
        lines.append(f"tun-mtu {profile['tun_mtu']}")

    if profile_dir:
        lines.append(f'ca {profile_dir}/ca.crt')
        if profile.get('tls_kind') == 'tls-crypt':
            lines.append(f'tls-crypt {profile_dir}/tls.key')
        if profile.get('auth_user_pass'):
            lines.append(f'auth-user-pass {profile_dir}/auth')

    return '\n'.join(lines) + '\n'


class TestOvpnRender(unittest.TestCase):
    def test_golden_config_rendering(self):
        profile = {
            'remotes': ['vpn.example.com 1194 udp'],
            'remote_cert_tls': 'server',
            'cipher': 'AES-256-GCM',
            'mssfix': 1450,
            'tls_kind': 'tls-crypt',
            'auth_user_pass': True
        }
        main_cfg = {'tun_dev': 'geovpn0'}
        rendered = render_ovpn(profile, '/etc/geovpn/profiles/p12345678', main_cfg)

        self.assertIn('client\n', rendered)
        self.assertIn('dev geovpn0\n', rendered)
        self.assertIn('remote vpn.example.com 1194 udp\n', rendered)
        self.assertIn('route-nopull\n', rendered)
        self.assertIn('pull-filter ignore "redirect-gateway"\n', rendered)
        self.assertIn('script-security 2\n', rendered)
        self.assertIn('up /usr/libexec/geovpn/ovpn-hook\n', rendered)
        self.assertIn('ca /etc/geovpn/profiles/p12345678/ca.crt\n', rendered)
        self.assertIn('tls-crypt /etc/geovpn/profiles/p12345678/tls.key\n', rendered)
        self.assertIn('auth-user-pass /etc/geovpn/profiles/p12345678/auth\n', rendered)


if __name__ == '__main__':
    unittest.main()
