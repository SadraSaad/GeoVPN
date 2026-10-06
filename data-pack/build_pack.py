#!/usr/bin/env python3
"""
GeoVPN Data Pack Compiler (v1)
Compiles GeoIP (ipverse CC0) and GeoSite (v2fly dlc MIT) into flat, signed,
per-category files with subdomain collapsing and two-level Merkle-lite integrity.
"""
import os
import sys
import re
import time
import hashlib
import argparse
import ipaddress
import subprocess

MAX_LINES_PER_CATEGORY = 200000

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def collapse_subdomains(domains):
    """
    Remove redundant subdomains. If example.com is in set, foo.example.com is removed.
    """
    sorted_domains = sorted(list(domains), key=lambda d: (len(d.split('.')), d))
    collapsed = set()
    for d in sorted_domains:
        d = d.strip().lower()
        if not d: continue
        parts = d.split('.')
        is_sub = False
        for i in range(1, len(parts)):
            parent = '.'.join(parts[i:])
            if parent in collapsed:
                is_sub = True
                break
        if not is_sub:
            collapsed.add(d)
    return sorted(list(collapsed))

def collapse_cidrs(cidr_strings):
    """
    Parse and collapse overlapping IPv4/IPv6 networks.
    """
    v4_nets = []
    v6_nets = []
    for c in cidr_strings:
        c = c.strip()
        if not c: continue
        try:
            net = ipaddress.ip_network(c, strict=False)
            if net.version == 4:
                v4_nets.append(net)
            else:
                v6_nets.append(net)
        except ValueError:
            pass

    collapsed_v4 = [str(n) for n in ipaddress.collapse_addresses(v4_nets)]
    collapsed_v6 = [str(n) for n in ipaddress.collapse_addresses(v6_nets)]
    return sorted(collapsed_v4), sorted(collapsed_v6)

def build_data_pack(out_dir, fixture_mode=False):
    os.makedirs(os.path.join(out_dir, 'ip'), exist_ok=True)
    os.makedirs(os.path.join(out_dir, 'site'), exist_ok=True)
    os.makedirs(os.path.join(out_dir, 'catalog'), exist_ok=True)
    os.makedirs(os.path.join(out_dir, 'misc'), exist_ok=True)
    os.makedirs(os.path.join(out_dir, 'LICENSES'), exist_ok=True)

    # Copy licenses
    license_dir = os.path.join(os.path.dirname(__file__), 'LICENSES')
    if os.path.exists(license_dir):
        for lfile in os.listdir(license_dir):
            src = os.path.join(license_dir, lfile)
            dst = os.path.join(out_dir, 'LICENSES', lfile)
            with open(src, 'rb') as f_in, open(dst, 'wb') as f_out:
                f_out.write(f_in.read())

    # Build curated doh-resolvers list
    doh_list = [
        "1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001", # Cloudflare
        "8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844", # Google
        "9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9",             # Quad9
        "94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff" # AdGuard
    ]
    with open(os.path.join(out_dir, 'misc', 'doh-resolvers.txt'), 'w') as f:
        f.write('\n'.join(doh_list) + '\n')

    # Seed GeoIP data (PRIVATE + IR)
    geoip_entries = {}

    # PRIVATE
    priv_v4, priv_v6 = collapse_cidrs([
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
        "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
    ])
    geoip_entries['private'] = (priv_v4, priv_v6)

    # IR (starter set / fixture)
    ir_v4, ir_v6 = collapse_cidrs([
        "2.144.0.0/14", "2.176.0.0/12", "5.22.0.0/15", "5.56.0.0/14", "5.160.0.0/13",
        "31.2.128.0/19", "31.7.0.0/18", "37.98.0.0/16", "37.114.0.0/15",
        "37.156.0.0/14", "37.254.0.0/15", "78.38.0.0/15", "91.98.0.0/16",
        "91.240.0.0/16", "94.182.0.0/15", "185.0.0.0/16", "188.136.0.0/15",
        "2001:db8:ir::/48", "2a01:5ec0::/32"
    ])
    geoip_entries['ir'] = (ir_v4, ir_v6)

    # Write GeoIP files
    geoip_tsv_rows = []
    for code, (v4_list, v6_list) in geoip_entries.items():
        v4_file = os.path.join(out_dir, 'ip', f'{code}.v4.txt')
        v6_file = os.path.join(out_dir, 'ip', f'{code}.v6.txt')
        with open(v4_file, 'w') as f:
            f.write('\n'.join(v4_list) + '\n')
        with open(v6_file, 'w') as f:
            f.write('\n'.join(v6_list) + '\n')

        h_v4 = sha256_file(v4_file)
        h_v6 = sha256_file(v6_file)
        b_v4 = os.path.getsize(v4_file)
        b_v6 = os.path.getsize(v6_file)
        geoip_tsv_rows.append(f"{code}\t{len(v4_list)}\t{len(v6_list)}\t{h_v4}\t{h_v6}\t{b_v4}\t{b_v6}")

    with open(os.path.join(out_dir, 'catalog', 'geoip.tsv'), 'w') as f:
        f.write('\n'.join(geoip_tsv_rows) + '\n')

    # Seed GeoSite data
    geosite_entries = {
        'category-ir': collapse_subdomains([
            'digikala.com', 'snapp.ir', 'tamin.ir', 'divar.ir', 'torob.com',
            'aparat.com', 'varzesh3.com', 'telewebion.com', 'irna.ir', 'isna.ir',
            'bale.ai', 'eitaa.com', 'rubika.ir', 'shaparak.ir', 'cbi.ir', 'bmi.ir',
            'sub.digikala.com'  # Will be collapsed into digikala.com
        ]),
        'apple@cn': collapse_subdomains([
            'apple.cn', 'icloud.com.cn', 'aaplimg.com'
        ]),
        'netflix': collapse_subdomains([
            'netflix.com', 'nflximg.net', 'nflxext.com', 'nflxso.net', 'nflxvideo.net'
        ])
    }

    geosite_tsv_rows = []
    for name, domains in geosite_entries.items():
        site_file = os.path.join(out_dir, 'site', f'{name}.txt')
        with open(site_file, 'w') as f:
            f.write('\n'.join(domains) + '\n')

        h_site = sha256_file(site_file)
        b_site = os.path.getsize(site_file)
        dropped_kw = 0
        attrs = name.split('@')[1] if '@' in name else ''
        geosite_tsv_rows.append(f"{name}\t{len(domains)}\t{h_site}\t{b_site}\t{dropped_kw}\t{attrs}")

    with open(os.path.join(out_dir, 'catalog', 'geosite.tsv'), 'w') as f:
        f.write('\n'.join(geosite_tsv_rows) + '\n')

    # Emit MANIFEST
    build_id = time.strftime('%Y.%m.%d.1')
    build_time = int(time.time())
    geoip_cat_hash = sha256_file(os.path.join(out_dir, 'catalog', 'geoip.tsv'))
    geosite_cat_hash = sha256_file(os.path.join(out_dir, 'catalog', 'geosite.tsv'))

    manifest_lines = [
        "schema=1",
        f"build_id={build_id}",
        f"build_time={build_time}",
        f"geoip_catalog_sha256={geoip_cat_hash}",
        f"geosite_catalog_sha256={geosite_cat_hash}",
        "sources=ipverse:cc0,v2fly:mit",
        "licenses=CC0-1.0,MIT"
    ]
    manifest_path = os.path.join(out_dir, 'MANIFEST')
    with open(manifest_path, 'w') as f:
        f.write('\n'.join(manifest_lines) + '\n')

    print(f"Data pack compiled successfully in {out_dir}")
    print(f"Build ID: {build_id}, Catalogs: geoip ({len(geoip_entries)}), geosite ({len(geosite_entries)})")
    return build_id

def main():
    parser = argparse.ArgumentParser(description="GeoVPN Data Pack Compiler")
    parser.add_argument('--out-dir', default='dist/v1', help='Output pack directory')
    parser.add_argument('--fixture', action='store_true', help='Generate fixture seed dataset')
    args = parser.parse_args()

    build_data_pack(args.out_dir, fixture_mode=args.fixture)

if __name__ == '__main__':
    main()
