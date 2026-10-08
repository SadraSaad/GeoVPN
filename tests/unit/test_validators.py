#!/usr/bin/env python3
"""
Unit tests for GeoVPN validators (mirroring util.uc logic)
"""
import unittest
import re

RE_IFNAME = re.compile(r'^[A-Za-z0-9_.@-]{1,15}$')
RE_PROFILE_ID = re.compile(r'^p[0-9a-f]{8}$')
RE_CATEGORY = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
RE_GEOSITE = re.compile(r'^[a-z0-9][a-z0-9@._-]{0,63}$')
RE_MAC = re.compile(r'^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$')
RE_CRON = re.compile(r'^[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+$')
RE_TIMEOUT = re.compile(r'^[0-9]{1,4}[smhd]$')

def is_ifname(s):
    return bool(isinstance(s, str) and RE_IFNAME.match(s))

def is_profile_id(s):
    return bool(isinstance(s, str) and RE_PROFILE_ID.match(s))

def is_category_code(s):
    return bool(isinstance(s, str) and RE_CATEGORY.match(s))

def is_geosite_name(s):
    return bool(isinstance(s, str) and RE_GEOSITE.match(s))

def is_mac(s):
    return bool(isinstance(s, str) and RE_MAC.match(s))

def is_port(n):
    try:
        val = int(n)
        return 1 <= val <= 65535
    except (ValueError, TypeError):
        return False

def is_cron_expr(s):
    return bool(isinstance(s, str) and RE_CRON.match(s))

def is_dyn_timeout(s):
    return bool(isinstance(s, str) and RE_TIMEOUT.match(s))

def is_ipv4(s):
    if not isinstance(s, str): return False
    parts = s.split('.')
    if len(parts) != 4: return False
    for p in parts:
        if not p.isdigit(): return False
        if len(p) > 1 and p.startswith('0'): return False
        n = int(p)
        if not (0 <= n <= 255): return False
    return True

def is_ipv6(s):
    if not isinstance(s, str) or len(s) < 2 or len(s) > 39: return False
    if not re.match(r'^[0-9a-fA-F:]+$', s): return False
    colons = s.split(':')
    return 3 <= len(colons) <= 8

def is_cidr4(s):
    if not isinstance(s, str) or '/' not in s: return False
    parts = s.split('/')
    if len(parts) != 2: return False
    if not is_ipv4(parts[0]): return False
    if not parts[1].isdigit(): return False
    return 0 <= int(parts[1]) <= 32

def is_cidr6(s):
    if not isinstance(s, str) or '/' not in s: return False
    parts = s.split('/')
    if len(parts) != 2: return False
    if not is_ipv6(parts[0]): return False
    if not parts[1].isdigit(): return False
    return 0 <= int(parts[1]) <= 128

def is_domain(s):
    if not isinstance(s, str) or not (1 <= len(s) <= 253): return False
    if s.startswith('.'): s = s[1:]
    labels = s.split('.')
    if not labels: return False
    for l in labels:
        if not (1 <= len(l) <= 63): return False
        if not re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$', l): return False
    return True

def is_url(s):
    if not isinstance(s, str) or not s.startswith('https://'): return False
    if not re.match(r'^https://[A-Za-z0-9._~:/?#@!$&\'()*+,;=%-]+$', s): return False
    if any(x in s for x in ('127.0.0.1', 'localhost', '169.254.')): return False
    return True

def scrub_secrets(text):
    text = re.sub(r'-----BEGIN [A-Z0-9 _-]+-----[\s\S]*?-----END [A-Z0-9 _-]+-----', '[REDACTED PEM BLOCK]', text)
    text = re.sub(r'("?(?:password|passwd|auth-user-pass|PrivateKey|PresharedKey|private[-_]?key|preshared[-_]?key|secret)"?\s*[:=]\s*")[^"\r\n]+"', r'\1[REDACTED]"', text, flags=re.IGNORECASE)
    text = re.sub(r'("?(?:password|passwd|auth-user-pass|PrivateKey|PresharedKey|private[-_]?key|preshared[-_]?key|secret)"?\s*[:=]\s*)([^"\[ \t\r\n,}]+)', r'\1[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(r'(password[ \t]+)[^\r\n]+', r'\1[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(r'(auth-user-pass[ \t]+)[^\r\n]+', r'\1[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(r'(private-key[ \t]+)[^ \t\r\n]+', r'\1[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(r'(preshared-key[ \t]+)[^ \t\r\n]+', r'\1[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(r'\b0x[0-9a-fA-F]{16,}\b', '[REDACTED HEX SECRET]', text)
    return text


class TestValidators(unittest.TestCase):
    def test_ifname(self):
        self.assertTrue(is_ifname('br-lan'))
        self.assertTrue(is_ifname('geovpn0'))
        self.assertTrue(is_ifname('eth0.1'))
        self.assertFalse(is_ifname(''))
        self.assertFalse(is_ifname('this_interface_name_is_way_too_long_for_linux'))
        self.assertFalse(is_ifname('eth0;rm -rf'))

    def test_profile_id(self):
        self.assertTrue(is_profile_id('p01234567'))
        self.assertTrue(is_profile_id('pdeadbeef'))
        self.assertFalse(is_profile_id('p123'))
        self.assertFalse(is_profile_id('pG0000000'))
        self.assertFalse(is_profile_id('root'))

    def test_category_and_geosite(self):
        self.assertTrue(is_category_code('ir'))
        self.assertTrue(is_category_code('private'))
        self.assertTrue(is_category_code('category-ir'))
        self.assertTrue(is_geosite_name('apple@cn'))
        self.assertTrue(is_geosite_name('google'))
        self.assertFalse(is_category_code('../escape'))
        self.assertFalse(is_category_code('IRAN'))

    def test_mac(self):
        self.assertTrue(is_mac('aa:bb:cc:dd:ee:ff'))
        self.assertTrue(is_mac('00:11:22:33:44:55'))
        self.assertFalse(is_mac('aabbccddeeff'))
        self.assertFalse(is_mac('aa:bb:cc:dd:ee'))

    def test_ipv4(self):
        self.assertTrue(is_ipv4('192.168.1.1'))
        self.assertTrue(is_ipv4('1.1.1.1'))
        self.assertTrue(is_ipv4('0.0.0.0'))
        self.assertTrue(is_ipv4('255.255.255.255'))
        self.assertFalse(is_ipv4('256.0.0.1'))
        self.assertFalse(is_ipv4('192.168.01.1'))  # Leading zero
        self.assertFalse(is_ipv4('1.2.3'))
        self.assertFalse(is_ipv4('1.2.3.4.5'))
        self.assertFalse(is_ipv4('cat'))

    def test_cidr4(self):
        self.assertTrue(is_cidr4('192.168.1.0/24'))
        self.assertTrue(is_cidr4('10.0.0.0/8'))
        self.assertTrue(is_cidr4('0.0.0.0/0'))
        self.assertFalse(is_cidr4('192.168.1.0/33'))
        self.assertFalse(is_cidr4('192.168.1.0'))

    def test_domain(self):
        self.assertTrue(is_domain('example.com'))
        self.assertTrue(is_domain('sub.example.co.uk'))
        self.assertTrue(is_domain('.example.com'))  # Leading dot stripped
        self.assertFalse(is_domain(''))
        self.assertFalse(is_domain('-bad.com'))
        self.assertFalse(is_domain('bad..com'))
        self.assertFalse(is_domain('a'*64 + '.com'))

    def test_url(self):
        self.assertTrue(is_url('https://example.com/pack/'))
        self.assertTrue(is_url('https://raw.githubusercontent.com/ipverse/country-ip-blocks/master/'))
        self.assertFalse(is_url('http://insecure.com'))
        self.assertFalse(is_url('https://127.0.0.1/malicious'))
        self.assertFalse(is_url('https://localhost/test'))

    def test_scrub_secrets(self):
        secret = "ca\n-----BEGIN CERTIFICATE-----\nMIIB...data==\n-----END CERTIFICATE-----\nauth-user-pass mypass"
        scrubbed = scrub_secrets(secret)
        self.assertNotIn("MIIB...data==", scrubbed)
        self.assertNotIn("mypass", scrubbed)
        self.assertIn("[REDACTED PEM BLOCK]", scrubbed)
        self.assertIn("[REDACTED]", scrubbed)

        # JSON quoted secrets
        json_sample = '{"password": "secret123", "PrivateKey": "MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=", "secret": "psk123"}'
        json_scrubbed = scrub_secrets(json_sample)
        self.assertNotIn("secret123", json_scrubbed)
        self.assertNotIn("MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=", json_scrubbed)
        self.assertNotIn("psk123", json_scrubbed)
        self.assertIn('[REDACTED]', json_scrubbed)

        # Bare 0x hex secret in log line
        hex_sample = "Log message: charon generated 0xdeadbeef1234567890abcdef12345678 internal key"
        hex_scrubbed = scrub_secrets(hex_sample)
        self.assertNotIn("0xdeadbeef1234567890abcdef12345678", hex_scrubbed)
        self.assertIn('[REDACTED HEX SECRET]', hex_scrubbed)

        # WireGuard CLI / INI sample
        wg_sample = "Config: PrivateKey = MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=, peer preshared-key /etc/geovpn/psk.key"
        wg_scrubbed = scrub_secrets(wg_sample)
        self.assertNotIn("MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=", wg_scrubbed)
        self.assertNotIn("/etc/geovpn/psk.key", wg_scrubbed)
        self.assertIn('[REDACTED]', wg_scrubbed)


if __name__ == '__main__':
    unittest.main()
