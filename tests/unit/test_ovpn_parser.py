#!/usr/bin/env python3
"""
Unit tests for GeoVPN OpenVPN Config Parser (.ovpn) and Hostile Corpus Defense
"""
import unittest
import re

MAX_CONFIG_SIZE = 131072
MAX_LINE_LEN = 4096
MAX_REMOTES = 64

DENIED_DIRECTIVES = {
    'up', 'down', 'route-up', 'route-pre-down', 'up-delay', 'tls-verify',
    'ipchange', 'learn-address', 'client-connect', 'client-disconnect',
    'auth-user-pass-verify', 'plugin', 'script-security', 'management',
    'management-client', 'management-query-passwords', 'management-hold',
    'daemon', 'log', 'log-append', 'syslog', 'writepid', 'status', 'status-version',
    'cd', 'chroot', 'setcon', 'config', 'askpass', 'ifconfig-noexec',
    'route-noexec', 'iproute', 'engine', 'providers', 'echo', 'lladdr',
    'bind-dev', 'mark', 'setenv', 'dev-node', 'genkey', 'secret'
}

ROUTING_DIRECTIVES = {
    'redirect-gateway', 'route', 'route-ipv6', 'route-metric',
    'route-delay', 'route-gateway', 'dhcp-option', 'block-outside-dns',
    'ifconfig', 'ifconfig-ipv6'
}

INLINE_TAGS = {
    'ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2',
    'extra-certs', 'crl-verify', 'peer-fingerprint'
}

def tokenize_line(line):
    tokens = []
    i = 0
    length = len(line)
    while i < length:
        while i < length and line[i] in ' \t':
            i += 1
        if i >= length or line[i] in '#;':
            break
        token = ''
        if line[i] in ('"', "'"):
            quote = line[i]
            i += 1
            while i < length and line[i] != quote:
                if line[i] == '\\' and i + 1 < length:
                    token += line[i + 1]
                    i += 2
                else:
                    token += line[i]
                    i += 1
            if i < length and line[i] == quote:
                i += 1
        else:
            while i < length and line[i] not in ' \t#;':
                if line[i] == '\\' and i + 1 < length:
                    token += line[i + 1]
                    i += 2
                else:
                    token += line[i]
                    i += 1
        if token:
            tokens.append(token)
    return tokens

def parse_ovpn(content, profile_name='Imported Profile'):
    if not isinstance(content, str):
        return {'ok': False, 'error': 'Content must be string'}
    if len(content.encode('utf-8')) > MAX_CONFIG_SIZE:
        return {'ok': False, 'error': 'Config size exceeds 128 KB limit'}

    if content.startswith('\ufeff'):
        content = content[1:]

    content = content.replace('\r\n', '\n').replace('\r', '\n')
    lines = content.split('\n')

    profile = {
        'name': profile_name,
        'remotes': [],
        'auth_user_pass': False,
        'tls_kind': 'none',
        'key_direction': '',
        'cipher': '',
        'data_ciphers': '',
        'auth': '',
        'remote_cert_tls': 'server',
        'mssfix': 1450,
        'tun_mtu': 1500,
        'keepalive': '10 60',
        'compress': 'none',
        'materials': {},
        'ignored': [],
        'warnings': [],
        'incomplete': []
    }

    in_tag = None
    tag_content = ''

    for line_num, line in enumerate(lines):
        if len(line) > MAX_LINE_LEN:
            profile['warnings'].append(f'Line {line_num + 1} exceeds 4096 characters (truncated)')
            line = line[:MAX_LINE_LEN]

        trimmed = line.strip()

        if in_tag:
            close_tag = f'</{in_tag}>'
            if trimmed == close_tag:
                profile['materials'][in_tag] = tag_content
                in_tag = None
                tag_content = ''
            else:
                tag_content += line + '\n'
                if len(tag_content) > 65536:
                    return {'ok': False, 'error': f'Inline <{in_tag}> block exceeds 64 KB limit'}
            continue

        tag_match = re.match(r'^<([a-z0-9_-]+)>$', trimmed)
        if tag_match:
            tag_name = tag_match.group(1)
            if tag_name in INLINE_TAGS:
                in_tag = tag_name
                tag_content = ''
                continue
            else:
                profile['ignored'].append({'directive': trimmed, 'reason': 'unknown inline tag'})
                continue

        if not trimmed or trimmed[0] in '#;':
            continue

        tokens = tokenize_line(trimmed)
        if not tokens:
            continue

        cmd = tokens[0].lower()

        if cmd in DENIED_DIRECTIVES:
            profile['ignored'].append({'directive': trimmed, 'reason': 'denied security risk'})
            continue

        if cmd in ROUTING_DIRECTIVES:
            profile['ignored'].append({'directive': trimmed, 'reason': 'routing handled by GeoVPN'})
            continue

        if cmd in ('dev', 'dev-type') and len(tokens) > 1 and 'tap' in tokens[1].lower():
            return {'ok': False, 'error': 'TAP mode unsupported'}

        file_refs = {'ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'pkcs12'}
        if cmd in file_refs:
            if cmd == 'pkcs12':
                return {'ok': False, 'error': 'PKCS#12 unsupported'}
            profile['incomplete'].append(cmd)
            profile['ignored'].append({'directive': trimmed, 'reason': 'external file reference'})
            continue

        if cmd == 'remote':
            if len(profile['remotes']) >= MAX_REMOTES:
                profile['warnings'].append('Max 64 remotes reached')
                continue
            if len(tokens) >= 2:
                r_host = tokens[1]
                r_port = tokens[2] if len(tokens) >= 3 else '1194'
                r_proto = tokens[3].lower() if len(tokens) >= 4 else 'udp'
                profile['remotes'].append(f'{r_host} {r_port} {r_proto}')
        elif cmd == 'auth-user-pass':
            profile['auth_user_pass'] = True
        elif cmd == 'cipher' and len(tokens) > 1:
            profile['cipher'] = tokens[1]
        elif cmd == 'remote-cert-tls' and len(tokens) > 1:
            profile['remote_cert_tls'] = tokens[1].lower()

    if 'tls-crypt' in profile['materials']:
        profile['tls_kind'] = 'tls-crypt'
    elif 'tls-auth' in profile['materials']:
        profile['tls_kind'] = 'tls-auth'

    return {'ok': True, 'profile': profile}


class TestOvpnParser(unittest.TestCase):
    def test_valid_profile_with_inline_blocks(self):
        ovpn = """
# Valid OpenVPN Profile
client
dev tun
proto udp
remote vpn.example.com 1194
remote-cert-tls server
cipher AES-256-GCM
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
MIIBCAJBAgEAM...
-----END CERTIFICATE-----
</ca>
<tls-crypt>
-----BEGIN OpenVPN Static key V1-----
e8a...
-----END OpenVPN Static key V1-----
</tls-crypt>
"""
        res = parse_ovpn(ovpn, 'Test VPN')
        self.assertTrue(res['ok'])
        p = res['profile']
        self.assertEqual(p['name'], 'Test VPN')
        self.assertEqual(len(p['remotes']), 1)
        self.assertEqual(p['remotes'][0], 'vpn.example.com 1194 udp')
        self.assertTrue(p['auth_user_pass'])
        self.assertEqual(p['cipher'], 'AES-256-GCM')
        self.assertEqual(p['tls_kind'], 'tls-crypt')
        self.assertIn('ca', p['materials'])
        self.assertIn('tls-crypt', p['materials'])

    def test_hostile_corpus_denied_directives(self):
        hostile = """
client
dev tun
remote 192.0.2.1 1194
up "/usr/bin/touch /tmp/pwned"
down "/bin/sh -c 'rm -rf /'"
plugin /tmp/evil.so
script-security 3
log /etc/shadow
log-append /tmp/log
management 127.0.0.1 9999
config /etc/openvpn/extra.conf
"""
        res = parse_ovpn(hostile)
        self.assertTrue(res['ok'])
        p = res['profile']
        ignored_cmds = [item['directive'] for item in p['ignored']]
        self.assertTrue(any('up ' in d for d in ignored_cmds))
        self.assertTrue(any('down ' in d for d in ignored_cmds))
        self.assertTrue(any('plugin ' in d for d in ignored_cmds))
        self.assertTrue(any('script-security' in d for d in ignored_cmds))
        self.assertTrue(any('log /etc/shadow' in d for d in ignored_cmds))
        self.assertTrue(any('management' in d for d in ignored_cmds))
        self.assertTrue(any('config ' in d for d in ignored_cmds))

    def test_rejection_of_tap(self):
        tap_ovpn = "client\ndev tap\nremote vpn.example.com 1194\n"
        res = parse_ovpn(tap_ovpn)
        self.assertFalse(res['ok'])
        self.assertIn('TAP', res['error'])

    def test_external_file_references_flagged(self):
        ext_ovpn = """
client
dev tun
remote vpn.example.com 1194
ca /etc/ssl/certs/ca-certificates.crt
cert /etc/openvpn/client.crt
key /etc/openvpn/client.key
"""
        res = parse_ovpn(ext_ovpn)
        self.assertTrue(res['ok'])
        p = res['profile']
        self.assertIn('ca', p['incomplete'])
        self.assertIn('cert', p['incomplete'])
        self.assertIn('key', p['incomplete'])

    def test_oversized_file_rejected(self):
        large = "remote 1.2.3.4 1194\n" * 10000
        res = parse_ovpn(large)
        self.assertFalse(res['ok'])
        self.assertIn('128 KB', res['error'])

    def test_oversized_inline_block_rejected(self):
        big_block = "<ca>\n" + ("A" * 1000 + "\n") * 70 + "</ca>\n"
        res = parse_ovpn(big_block)
        self.assertFalse(res['ok'])
        self.assertIn('64 KB', res['error'])

    def test_utf8_bom_and_crlf(self):
        bom_ovpn = "\ufeffclient\r\ndev tun\r\nremote vpn.test 1194\r\n"
        res = parse_ovpn(bom_ovpn)
        self.assertTrue(res['ok'])
        self.assertEqual(len(res['profile']['remotes']), 1)


if __name__ == '__main__':
    unittest.main()
