# GeoVPN — OpenVPN client with geo-based split tunneling for OpenWrt

[English](README.md) · [فارسی](README.fa.md)

GeoVPN turns an OpenWrt router into an **OpenVPN client that sends only the traffic you choose through the VPN**.
Pick countries (GeoIP) and domain categories (GeoSite) in LuCI: matching traffic goes **directly** through your normal
internet connection, everything else goes **through the VPN** — or the other way round. It is managed entirely from the web
interface, runs on small routers, and installs with one command.

> Status: v1.0 · Requires **OpenWrt 25.12+** (apk-based) · Primary test device: **Google WiFi (AC-1304)**

## Features
- Multiple OpenVPN client profiles; **import `.ovpn`** by upload or paste (certificates, keys, `tls-crypt`, `auth-user-pass` handled safely).
- Start / stop / restart, live status (IP, uptime, traffic), logs, automatic reconnect, autostart at boot.
- **Geo split tunneling**: GeoIP (country codes) and GeoSite (domain categories), custom IP/CIDR and domain rules,
  per-device policies (IP or MAC), always-direct VPN server (no routing loops).
- Two modes: **Bypass listed** (listed → direct, rest → VPN) or **Only listed via VPN**.
- **DNS that follows the route** (no DNS leaks for VPN-routed names), optional DNS hijack and DoT blocking.
- IPv4 **and** IPv6, with IPv6 leak prevention when the VPN has no IPv6.
- Optional **kill switch** that blocks VPN-bound traffic while the tunnel is down (direct traffic keeps working).
- Selective, signed, atomic geo-data updates with rollback; tiny footprint (scripts only, no extra daemon).
- English and Persian (فارسی) interface, RTL-aware.

## Supported devices and versions
| Item | Support |
|---|---|
| OpenWrt | **25.12.x** (apk, fw4/nftables). Not supported: 24.10 and older (opkg). |
| Primary device | **Google WiFi AC-1304** (`ipq40xx/chromium`, 512 MB RAM, 4 GB eMMC) |
| Other devices | Packages are architecture-independent and expected to work on any 25.12 device with ≥ 128 MB RAM (best effort) |
| Browser | Current Chrome/Firefox/Safari (LuCI JS views) |

## How it works
```
                 ┌────────────── LAN clients ───────────────┐
                 │ DNS query                    traffic       │
                 ▼                                 ▼          │
          dnsmasq-full (router)              nftables "geovpn" table
   • geo domain list → which DNS to ask   • decides per connection: DIRECT or VPN
   • fills nft sets with the answers      • GeoIP lists + DNS-filled sets + your rules
                 │                                 │
        direct DNS ◄── listed domains    VPN-marked ─► routing table 4200 ─► tun (OpenVPN) ─► Internet
        VPN DNS    ◄── all others (bypass mode)      DIRECT ─────────────► WAN (normal route) ─► Internet
```
1. You choose the **mode** and the lists (e.g. GeoIP `ir`, GeoSite `category-ir`).
2. dnsmasq resolves names for your devices; for listed domains it **adds the resolved IPs to nftables sets**.
3. Every new connection is classified once (rules in order: VPN server → device policy → your rules → private
   networks → GeoSite → GeoIP → default) and remembered in the connection-tracking mark.
4. VPN-marked traffic is routed into the OpenVPN tunnel by policy routing; everything else uses your normal WAN route.
5. DNS queries take the same path as the traffic they belong to.

Limits you should know: domain matching is **suffix-based** (dnsmasq); `keyword:`/`regexp:` GeoSite rules are not supported.
Devices that use their own DNS-over-HTTPS bypass the router's DNS — see *Security notes*.

## Prerequisites
- OpenWrt **25.12** with working internet access and SSH.
- Free resources: ~1 MB flash for the app + data, **≥ 64 MB free RAM** (large country lists need more; the UI shows estimates).
- **`dnsmasq-full`** (the default `dnsmasq` lacks `nftset`). Swap safely — *download first, then replace*, so DNS keeps working:
  ```sh
  cd /tmp
  apk update
  apk fetch dnsmasq-full                 # downloads dnsmasq-full-*.apk into /tmp
  apk del dnsmasq
  apk add --allow-untrusted ./dnsmasq-full-*.apk
  /etc/init.d/dnsmasq restart
  ```
  Verify: `dnsmasq --version | head -3` must list `nftset`.
- Everything else (OpenVPN, kmod-tun, ucode modules, …) is pulled in automatically.

## Installation
### A) From the package feed (recommended, SSH)
```sh
# 1. trust the feed key (check the fingerprint on the project page first)
wget -O /etc/apk/keys/geovpn.pem https://geovpn.github.io/geovpn/keys/geovpn.pem
echo /etc/apk/keys/geovpn.pem >> /etc/sysupgrade.conf          # keep the key across sysupgrade

# 2. add the feed
echo 'https://geovpn.github.io/geovpn/25.12/packages.adb' > /etc/apk/repositories.d/geovpn.list

# 3. install everything with one command
apk update
apk add geovpn
```
### B) From LuCI
*System → Software* → **Update lists** → search `geovpn` → install. (The feed and key must be added once via SSH as above,
because LuCI cannot add third-party feeds or keys.)
### C) From a pre-built release file
```sh
cd /tmp
# download the .apk files and SHA256SUMS from the GitHub Release, then:
sha256sum -c SHA256SUMS
apk add --allow-untrusted ./geovpn-core-*.apk ./luci-app-geovpn-*.apk ./luci-i18n-geovpn-fa-*.apk ./geovpn-*.apk
```
`--allow-untrusted` skips signature verification — use it only for files whose checksum you verified.

### Verify the installation
```sh
apk info -e geovpn geovpn-core luci-app-geovpn      # all three listed
geovpn version && geovpn diag                        # all checks "ok" (data not yet downloaded is a warning)
/etc/init.d/rpcd restart                             # only if LuCI doesn't show the menu yet
```
Open LuCI → **VPN → GeoVPN**.

## First-time setup
1. **Connections** tab → **Import** → choose your `.ovpn` (or paste it). Read the import report; if it asks for
   username/password, click **Credentials**. Click **Make active**.
2. **Split Tunneling** tab → tick **Enable**, choose the mode, then **Add…** GeoIP (e.g. `ir`, `private`) and GeoSite
   (e.g. `category-ir`). The page shows the estimated RAM.
3. Click **Update now** (first data download; a few hundred KB) and wait for the green check.
4. **Save & Apply**, then on the **Connections** tab press **Start**. State should become **Connected**.
5. Verify (from a device on your LAN):
   ```sh
   curl -s https://ifconfig.me ; echo          # in bypass mode: your VPN's IP (non-listed site)
   curl -s https://ifconfig.co/country ; echo
   ```
   Then on the router:
   ```sh
   geovpn test example.com        # → VPN (default path)
   geovpn test <a-listed-domain>  # → DIRECT, reason: geosite:category-ir
   nft list table inet geovpn | head -40
   ip rule show | grep 4200 ; ip route show table 4200
   ```
   In LuCI the **Test a domain or IP** box shows the same answer.

## Configuration reference (`/etc/config/geovpn`)
`main` section:

| Option | Default | Values / meaning |
|---|---|---|
| `enabled` | `0` | Start at boot and keep running |
| `active_profile` | | Profile id to use |
| `split_enabled` | `1` | `0` = full tunnel |
| `mode` | `bypass` | `bypass` (listed→direct) / `include` (listed→VPN) |
| `private_direct` | `1` | Private networks always direct |
| `ipv6` | `auto` | `auto` / `block` / `vpn` / `direct` |
| `kill_switch` | `0` | Block VPN-bound traffic while tunnel down |
| `router_traffic` | `dns` | `dns` / `direct` / `vpn` |
| `lan_ifs` | `br-lan` | LAN devices to police |
| `lan_zones` | `lan` | Firewall zones allowed to forward into the tunnel |
| `tun_dev` | `geovpn0` | Tunnel device name |
| `mark_shift` | `24` | Bit position of the packet mark (16–28) |
| `rt_table` | `4200` | Policy routing table id |
| `rule_priority` | `700` | `ip rule` priority |
| `dns_mode` | `follow` | `follow` / `direct` / `vpn` / `off` |
| `dns_direct_servers` | `auto` | Resolvers for direct domains (`auto` = WAN DNS) |
| `dns_vpn_servers` | `1.1.1.1 9.9.9.9` | Resolvers reached through the tunnel; token `pushed` = server-pushed DNS |
| `dns_hijack` | `1` | Redirect LAN port 53 to the router |
| `block_dot` | `1` | Block LAN → port 853 |
| `block_doh` | `0` | Block known DoH resolver IPs |
| `dns_canary` | `1` | NXDOMAIN for `use-application-dns.net` |
| `dyn_timeout` | `6h` | Lifetime of DNS-learned IPs |
| `max_cidrs` / `max_domains` | `150000` / `60000` | Safety caps |
| `allow_large` | `0` | Allow exceeding caps |
| `flush_conntrack` | `0` | Drop tracked connections on reload |
| `log_level` | `info` | `error` / `warn` / `info` / `debug` |

`profile` sections: `name`, `enabled`, `remote` (list `"host port proto"`), `remote_random`, `auth_user_pass`, `tls_kind`,
`key_direction`, `cipher`, `data_ciphers`, `data_ciphers_fallback`, `auth`, `tls_version_min`, `verify_x509_name`,
`peer_fingerprint`, `remote_cert_tls`, `mssfix`, `tun_mtu`, `keepalive`, `compress`, `extra` (allowlisted directives).
`data` section: `source_url`, `verify`, `pack_pubkey`, `auto_update`, `update_cron`, `update_via`, `keep_prev`.
Selections and rules: `config geoip` (`code`, `enabled`), `config geosite` (`name`, `enabled`),
`config rule` (`name`, `type` cidr|domain, `value`, `action` direct|vpn, `enabled`), `config client`
(`name`, `match` ip|cidr|mac, `value`, `policy` direct_all|vpn_all, `enabled`).

Example:
```
config main 'main'
	option enabled '1'
	option active_profile 'p3a9f21c'
	option mode 'bypass'
	option kill_switch '0'
config geoip
	option code 'ir'
	option enabled '1'
config geosite
	option name 'category-ir'
	option enabled '1'
```
Apply changes with `/etc/init.d/geovpn reload` (or **Save & Apply** in LuCI).

## Usage examples
**Send Iranian IPs and domains directly, everything else through the VPN**
Mode *Bypass listed*; GeoIP `ir` + `private`; GeoSite `category-ir`.

**Route only streaming-related categories through the VPN**
Mode *Only listed via VPN*; GeoSite e.g. `netflix`, `disney`, `hulu` (pick the names the catalog offers); no GeoIP needed.

**Keep one device off the VPN**
*Client policies → Add* → MAC of the TV → **Direct only**.

**Strict privacy**
Enable **Kill switch**; keep **DNS hijack** and **Block DoT** on; set IPv6 to *Auto*.

## Updating data, upgrading, uninstalling
- **Data**: *Split Tunneling → Update now*, or `geovpn update`. Daily automatic update is on by default (04:17 ± 30 min). Updates are verified (signature +
  hashes), installed atomically and rolled back on any failure. Only the categories you selected are downloaded.
- **Upgrade GeoVPN**: `apk update && apk upgrade geovpn geovpn-core luci-app-geovpn`. Configuration migrates automatically.
- **Sysupgrade**: `/etc/config/geovpn` and `/etc/geovpn/profiles` are kept with *keep settings* (profiles contain your VPN keys — they are in your backups).
  Downloaded data is re-fetched after sysupgrade. Re-add the feed key if you did not append it to `/etc/sysupgrade.conf`.
- **Uninstall**: `apk del geovpn luci-app-geovpn geovpn-core` removes firewall rules, routes, the dnsmasq snippet and cron entries.
  Your config and profiles remain; remove them completely with `geovpn purge`.

## Troubleshooting
| Symptom | Check / fix |
|---|---|
| Menu missing in LuCI | `/etc/init.d/rpcd restart`; log out/in; `apk info -e luci-app-geovpn` |
| "dnsmasq lacks nftset" / GeoSite inactive | Install `dnsmasq-full` (see Prerequisites); `dnsmasq --version` must show `nftset` |
| `apk add geovpn` complains about `dnsmasq` conflict | Do the safe swap in Prerequisites first |
| TUN device missing | `apk add kmod-tun`; `ls /dev/net/tun`; `lsmod \| grep tun` |
| No internet after Start | `geovpn panic` (removes all GeoVPN rules); then `geovpn diag`. Kill switch on + tunnel down blocks VPN-bound traffic by design |
| Everything goes direct | `ip rule show` (rule 700 present?), `ip route show table 4200`, `geovpn test <site>`; check mode (bypass/include) |
| Everything goes through the VPN | Data not downloaded (`Update now`), or domain not resolved by the router (device uses its own DNS / DoH) |
| DNS leaks | Keep *DNS hijack* on; disable "Secure DNS" in browsers; `nft list table inet geovpn`; `tcpdump -ni wan port 53` |
| Works for IPv4 but sites hang | IPv6 set to `direct`/`vpn` while the tunnel lacks IPv6 → use `auto` |
| Routing loop / tunnel flaps | VPN server must be in the always-direct set: `nft list set inet geovpn always4`; check that the `remote` host resolves |
| Out of memory | Reduce categories; check estimates; `free -m`; lower `max_cidrs/max_domains` |
| Conflicts with pbr / mwan3 | `geovpn diag` shows overlaps; don't give the same destinations to both; change `mark_shift`/`rule_priority` |
| Slow VPN | OpenVPN is single-threaded; try `CHACHA20-POLY1305` or AES-GCM on the server side; check CPU with `top` |

Useful commands: `geovpn status --json`, `logread -e geovpn`, `nft list table inet geovpn`, `ip -6 rule`, `ip -6 route show table 4200`.

## Security notes
- Imported `.ovpn` files are **parsed with an allowlist**; script/plugin/management/log directives are dropped. Keys and passwords are stored only under `/etc/geovpn/profiles` (root, mode 0600) and are never shown in the UI or logs.
- Data packs are verified with a signature and hashes; do not disable verification unless you host your own pack.
- Clients that use DNS-over-HTTPS to a public resolver bypass the router's DNS and therefore GeoSite matching; GeoVPN blocks plain/DoT bypass and can block known DoH IPs, but cannot stop DoH to arbitrary hosts.
- Backups made with *Generate archive* contain your VPN keys — store them securely.

## Performance notes (Google WiFi AC-1304)
OpenVPN runs in userspace on a 716 MHz Cortex-A7, so expect **tens of Mbit/s** through the tunnel (varies with cipher); direct traffic is not affected by the VPN.
Default selections (country + a few categories) need only a few MB of RAM. The classifier is evaluated once per connection.

## FAQ
**Does GeoVPN replace `luci-app-openvpn`?** No, it is independent; you can have both, but don't run the same tunnel twice.
**Can I use WireGuard?** Not in v1. **Can I run two VPNs?** Not in v1 (one active tunnel).
**Why not geosite.dat directly?** It is 10+ MB; the router would need to parse it. We compile small per-category lists in CI.
**Does it block ads?** No. Use a dedicated blocker; ad categories can only be *routed*.
**Is my traffic logged by GeoVPN?** No; there is no telemetry. Only syslog lines about connection state.

## Contributing
Issues and PRs welcome. Read `PLAN.md` and `DECISIONS.md` first. Run `tools/lint.sh` and `python3 -m unittest discover tests/unit` before opening a PR; integration tests: `tests/integration/run.sh`.
Translations: edit `openwrt/luci-app-geovpn/po/<lang>/geovpn.po`. Data pack issues: see `data-pack/`.

## License
Code: Apache-2.0 (see `LICENSE`). Geo data: see `LICENSES/` in the data pack — IP lists CC0 (ipverse), domain lists MIT (v2fly/domain-list-community).
