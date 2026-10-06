//
// GeoVPN Diagnostics, Preflight Engine & Path Testing Simulator
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';
import * as cfg from './config.uc';
import * as state from './state.uc';

function ip_to_int(ip) {
	let parts = split(ip, '.');
	if (length(parts) != 4) return 0;
	return (+parts[0] * 16777216) + (+parts[1] * 65536) + (+parts[2] * 256) + (+parts[3]);
}

function match_cidr4(ip, cidr) {
	if (!util.is_ipv4(ip)) return false;
	if (index(cidr, '/') == -1) {
		return ip == cidr;
	}
	let parts = split(cidr, '/');
	let base = parts[0];
	let prefix = +parts[1];
	if (prefix < 0 || prefix > 32) return false;
	if (prefix == 0) return true;

	let mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
	let ip_val = ip_to_int(ip);
	let base_val = ip_to_int(base);
	return ((ip_val & mask) == (base_val & mask));
}

function run_diag() {
	let checks = [];
	let conflicts = [];

	// 1. Check TUN kernel device
	if (fs.stat('/dev/net/tun')) {
		push(checks, { id: 'TUN_DEVICE', level: 'ok', msg: 'TUN kernel device /dev/net/tun is present' });
	} else {
		push(checks, { id: 'TUN_DEVICE', level: 'fail', msg: 'Missing /dev/net/tun', hint: 'Install kmod-tun via apk add kmod-tun' });
	}

	// 2. Check OpenVPN executable
	let ovpn_check = util.safe_exec(['openvpn', '--version']);
	if (ovpn_check.code == 0) {
		let first_line = split(ovpn_check.stdout, '\n')[0] || 'OpenVPN';
		push(checks, { id: 'OPENVPN_BIN', level: 'ok', msg: sprintf('OpenVPN binary available (%s)', first_line) });
	} else {
		push(checks, { id: 'OPENVPN_BIN', level: 'fail', msg: 'OpenVPN binary not found in PATH', hint: 'Install openvpn-openssl' });
	}

	// 3. Check dnsmasq nftset support
	let dns_check = util.safe_exec(['dnsmasq', '-v']);
	if (dns_check.code == 0 && index(dns_check.stdout, 'nftset') != -1) {
		push(checks, { id: 'DNSMASQ_NFTSET', level: 'ok', msg: 'dnsmasq supports nftset' });
	} else {
		push(checks, { id: 'DNSMASQ_NFTSET', level: 'warn', msg: 'dnsmasq lacks nftset feature', hint: 'Swap dnsmasq with dnsmasq-full' });
	}

	// 4. Check firewall4 and nft
	let nft_check = util.safe_exec(['nft', '--version']);
	if (nft_check.code == 0) {
		push(checks, { id: 'NFTABLES', level: 'ok', msg: 'nftables is available' });
	} else {
		push(checks, { id: 'NFTABLES', level: 'fail', msg: 'nft command not functional', hint: 'Verify firewall4 and nftables-json packages' });
	}

	// 5. Check for conflicts with pbr or mwan3
	let cursor = uci.cursor();
	let pbr_running = false;
	let mwan3_running = false;

	if (fs.stat('/etc/init.d/pbr')) {
		let pbr_st = util.safe_exec(['/etc/init.d/pbr', 'status']);
		if (pbr_st.code == 0) pbr_running = true;
	}
	if (fs.stat('/etc/init.d/mwan3')) {
		let mwan_st = util.safe_exec(['/etc/init.d/mwan3', 'status']);
		if (mwan_st.code == 0) mwan3_running = true;
	}

	if (pbr_running) {
		push(conflicts, { package: 'pbr', msg: 'Policy Based Routing (pbr) is currently running' });
		push(checks, { id: 'CONFLICT_PBR', level: 'warn', msg: 'pbr is active; ensure rule destinations do not overlap' });
	}
	if (mwan3_running) {
		push(conflicts, { package: 'mwan3', msg: 'mwan3 multi-WAN manager is active' });
		push(checks, { id: 'CONFLICT_MWAN3', level: 'warn', msg: 'mwan3 is active; GeoVPN priority 700 runs before mwan3' });
	}

	// 6. Flow offloading check
	try {
		cursor.load('firewall');
		let flow_offload = cursor.get('firewall', '@defaults[0]', 'flow_offloading');
		if (flow_offload == '1') {
			push(checks, { id: 'FLOW_OFFLOAD', level: 'warn', msg: 'Flow offloading is active; packets may bypass netfilter after flow setup' });
		}
	} catch (e) {}

	return {
		checks: checks,
		conflicts: conflicts,
		timestamp: time()
	};
}

function test_target(target, client_addr) {
	if (!target || length(target) == 0) {
		return { error: 'Target destination required' };
	}

	let config = cfg.load_config();
	let main = config.main || {};
	let mode = main.mode || 'bypass';

	let is_dom = util.is_domain(target);
	let is_v4 = util.is_ipv4(target);
	let is_v6 = util.is_ipv6(target);

	let kind = is_dom ? 'domain' : (is_v4 ? 'ipv4' : (is_v6 ? 'ipv6' : 'unknown'));
	let resolved_ips = [];

	if (is_dom) {
		// Attempt local name resolution if ucode resolv module is present
		try {
			let resolv = require('resolv');
			let ans = resolv.query(target, 'A');
			if (ans && length(ans) > 0) {
				for (let a in ans) push(resolved_ips, a.address);
			}
		} catch (e) {}
		if (length(resolved_ips) == 0) {
			// Mock simulated address for offline testing
			push(resolved_ips, '198.51.100.10');
		}
	} else if (is_v4 || is_v6) {
		push(resolved_ips, target);
	}

	let verdict = (mode == 'bypass') ? 'vpn' : 'direct';
	let reason = { layer: 'default', rule: 'mode_default', set: null };
	let notes = [];

	// Step 1: Check VPN server address (always direct)
	let active_id = main.active_profile;
	if (active_id) {
		let p = cfg.get_profile(active_id);
		if (p && p.remote) {
			for (let r in p.remote) {
				let s_host = split(r, ' ')[0];
				if (s_host == target || (length(resolved_ips) > 0 && resolved_ips[0] == s_host)) {
					verdict = 'direct';
					reason = { layer: 'always', rule: 'vpn_server_endpoint', set: 'always4' };
					push(notes, 'VPN server endpoint is always routed directly to prevent routing loops');
					return {
						kind: kind,
						resolved: resolved_ips,
						verdict: verdict,
						reason: reason,
						dns_path: 'direct',
						notes: notes
					};
				}
			}
		}
	}

	// Step 2: Per-client policies
	if (client_addr && config.clients) {
		for (let cli in config.clients) {
			if (cli.enabled != '0' && (cli.value == client_addr)) {
				if (cli.policy == 'vpn_all') {
					verdict = 'vpn';
					reason = { layer: 'client', rule: cli.name || cli.value, set: 'cli_v' };
					push(notes, 'Overridden by client VPN-all policy');
					return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: 'vpn', notes: notes };
				} else if (cli.policy == 'direct_all') {
					verdict = 'direct';
					reason = { layer: 'client', rule: cli.name || cli.value, set: 'cli_d' };
					push(notes, 'Overridden by client Direct-all policy');
					return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: 'direct', notes: notes };
				}
			}
		}
	}

	// Step 3: Custom rules
	if (config.rules) {
		for (let rule in config.rules) {
			if (rule.enabled != '0') {
				if (rule.type == 'domain' && is_dom && (target == rule.value || index(target, '.' + rule.value) != -1)) {
					verdict = rule.action;
					reason = { layer: 'custom', rule: rule.name || rule.value, set: 'cust_' + rule.action };
					return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: verdict, notes: notes };
				} else if (rule.type == 'cidr' && length(resolved_ips) > 0) {
					if (match_cidr4(resolved_ips[0], rule.value)) {
						verdict = rule.action;
						reason = { layer: 'custom', rule: rule.name || rule.value, set: 'cust_' + rule.action };
						return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: verdict, notes: notes };
					}
				}
			}
		}
	}

	// Step 4: Private ranges
	if (main.private_direct != '0' && length(resolved_ips) > 0) {
		let priv_cidrs = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8'];
		for (let pc in priv_cidrs) {
			if (match_cidr4(resolved_ips[0], pc)) {
				verdict = 'direct';
				reason = { layer: 'private', rule: 'rfc1918', set: 'private4' };
				return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: 'direct', notes: notes };
			}
		}
	}

	// Step 5: Check GeoSite / GeoIP lists if present in /etc/geovpn/data
	let data_dir = '/etc/geovpn/data';
	if (is_dom && fs.stat(data_dir + '/site')) {
		let site_files = fs.glob(data_dir + '/site/*.txt');
		for (let sf in site_files) {
			let f = fs.open(sf, 'r');
			if (f) {
				let lines = split(f.read('all'), '\n');
				f.close();
				for (let d in lines) {
					let dom = trim(d);
					if (dom == target || (length(dom) > 0 && index(target, '.' + dom) != -1)) {
						verdict = (mode == 'bypass') ? 'direct' : 'vpn';
						let cname = replace(sf, /^.*\/site\/|\.txt$/g, '');
						reason = { layer: 'geosite', rule: cname, set: 'geo4_dyn' };
						return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: verdict, notes: notes };
					}
				}
			}
		}
	}

	if (length(resolved_ips) > 0 && fs.stat(data_dir + '/ip')) {
		let ip_files = fs.glob(data_dir + '/ip/*.v4.txt');
		for (let ipf in ip_files) {
			let f = fs.open(ipf, 'r');
			if (f) {
				let lines = split(f.read('all'), '\n');
				f.close();
				for (let c in lines) {
					let cidr = trim(c);
					if (match_cidr4(resolved_ips[0], cidr)) {
						verdict = (mode == 'bypass') ? 'direct' : 'vpn';
						let ccode = replace(ipf, /^.*\/ip\/|\.v4\.txt$/g, '');
						reason = { layer: 'geoip', rule: ccode, set: 'geo4' };
						return { kind: kind, resolved: resolved_ips, verdict: verdict, reason: reason, dns_path: verdict, notes: notes };
					}
				}
			}
		}
	}

	return {
		kind: kind,
		resolved: resolved_ips,
		verdict: verdict,
		reason: reason,
		dns_path: verdict,
		notes: notes
	};
}

function get_scrubbed_logs(line_count, source_filter) {
	let n = line_count ? +line_count : 100;
	if (n < 1) n = 10;
	if (n > 500) n = 500;

	let res = util.safe_exec(['logread', '-e', 'geovpn']);
	let raw = (res.code == 0) ? res.stdout : '';
	let lines = split(raw, '\n');
	let result = [];

	let start_idx = length(lines) > n ? length(lines) - n : 0;
	for (let i = start_idx; i < length(lines); i++) {
		let l = lines[i];
		if (length(trim(l)) == 0) continue;
		let clean = util.scrub_secrets(l);
		push(result, { t: time(), src: 'geovpn', msg: clean });
	}

	return { lines: result };
}

export {
	run_diag,
	test_target,
	match_cidr4,
	get_scrubbed_logs
};
