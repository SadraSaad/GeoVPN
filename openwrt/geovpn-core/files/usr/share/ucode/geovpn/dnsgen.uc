//
// GeoVPN dnsmasq Integration & Config Generator
//
'use strict';

import * as fs from 'fs';
import * as util from './util.uc';

const MAX_DOMAINS_PER_LINE = 48;
const MAX_LINE_BYTES = 900;

function find_confdir() {
	// 1. Look for instance conf-dir setting in /var/etc/dnsmasq.conf.*
	let var_etc = fs.glob('/var/etc/dnsmasq.conf.*');
	if (var_etc && length(var_etc) > 0) {
		for (let conf_file in var_etc) {
			let f = fs.open(conf_file, 'r');
			if (f) {
				let content = f.read('all');
				f.close();
				let lines = split(content, '\n');
				for (let line in lines) {
					let m = match(line, /^conf-dir=([^, \t\r\n]+)/);
					if (m && fs.stat(m[1])) {
						return m[1];
					}
				}
			}
		}
	}

	// 2. Check standard runtime locations
	let candidates = fs.glob('/tmp/dnsmasq.*.d');
	if (candidates && length(candidates) > 0) {
		return candidates[0];
	}
	if (fs.stat('/tmp/dnsmasq.d')) {
		return '/tmp/dnsmasq.d';
	}

	// Fallback tmpfs directory
	let fallback = '/tmp/dnsmasq.d';
	fs.mkdir(fallback, 0o755);
	return fallback;
}

function get_direct_dns_servers(main_cfg) {
	let servers = main_cfg.dns_direct_servers || ['auto'];
	if (type(servers) != 'array') servers = [servers];

	let result = [];
	let has_auto = false;

	for (let s in servers) {
		if (s == 'auto') has_auto = true;
		else if (util.is_ip(s)) push(result, s);
	}

	if (has_auto) {
		// Read resolv.conf.auto
		let resolv_files = ['/tmp/resolv.conf.d/resolv.conf.auto', '/tmp/resolv.conf.auto'];
		for (let rf in resolv_files) {
			let f = fs.open(rf, 'r');
			if (f) {
				let content = f.read('all');
				f.close();
				let lines = split(content, '\n');
				for (let line in lines) {
					let m = match(line, /^nameserver\s+([0-9a-fA-F.:]+)/);
					if (m && util.is_ip(m[1]) && m[1] != '127.0.0.1' && m[1] != '::1') {
						push(result, m[1]);
					}
				}
				if (length(result) > 0) break;
			}
		}
	}

	if (length(result) == 0) {
		push(result, '1.1.1.1');
	}
	return result;
}

function get_vpn_dns_servers(main_cfg) {
	let servers = main_cfg.dns_vpn_servers || ['1.1.1.1', '9.9.9.9'];
	if (type(servers) != 'array') servers = [servers];

	let result = [];
	for (let s in servers) {
		if (s == 'pushed') {
			let f = fs.open('/var/run/geovpn/pushed_dns', 'r');
			if (f) {
				let content = f.read('all');
				f.close();
				let lines = split(content, '\n');
				for (let line in lines) {
					let ip = trim(line);
					if (util.is_ip(ip)) push(result, ip);
				}
			}
		} else if (util.is_ip(s)) {
			push(result, s);
		}
	}

	if (length(result) == 0) {
		push(result, '1.1.1.1');
		push(result, '9.9.9.9');
	}
	return result;
}

function chunk_domains(domains, max_count, max_bytes_prefix) {
	let chunks = [];
	let current = [];
	let current_len = 0;

	for (let d in domains) {
		let d_len = length(d) + 1; // '/domain'
		if (length(current) >= max_count || (current_len + d_len + max_bytes_prefix) > MAX_LINE_BYTES) {
			if (length(current) > 0) {
				push(chunks, current);
			}
			current = [d];
			current_len = d_len;
		} else {
			push(current, d);
			current_len += d_len;
		}
	}
	if (length(current) > 0) {
		push(chunks, current);
	}
	return chunks;
}

function render_dnsmasq_conf(config, geosite_domains, active_profile) {
	let main = config.main || {};
	let mode = main.mode || 'bypass';
	let dns_mode = main.dns_mode || 'follow';
	let dns_canary = (main.dns_canary != '0' && main.dns_canary != false);

	if (dns_mode == 'off') {
		return '# GeoVPN DNS mode is off — dnsmasq not configured\n';
	}

	let lines = [];
	push(lines, '# Managed by GeoVPN — do not edit manually');

	let direct_dns = get_direct_dns_servers(main);
	let vpn_dns = get_vpn_dns_servers(main);
	let primary_direct_dns = direct_dns[0];
	let primary_vpn_dns = vpn_dns[0];

	// In bypass mode, default resolver path is tunnel (no-resolv + vpn servers)
	if (mode == 'bypass') {
		push(lines, 'no-resolv');
		for (let s in vpn_dns) {
			push(lines, sprintf('server=%s', s));
		}
	}

	// 1. Infrastructure hosts (VPN server hostnames) -> always direct
	if (active_profile && active_profile.remotes) {
		let infra_domains = [];
		for (let r in active_profile.remotes) {
			let host = split(r, ' ')[0];
			if (util.is_domain(host)) {
				push(infra_domains, host);
			}
		}
		if (length(infra_domains) > 0) {
			for (let chunk in chunk_domains(infra_domains, MAX_DOMAINS_PER_LINE, 40)) {
				let d_spec = '/' + join('/', chunk) + '/';
				push(lines, sprintf('server=%s%s', d_spec, primary_direct_dns));
				push(lines, sprintf('nftset=%s4#inet#geovpn#always4_dyn,6#inet#geovpn#always6_dyn', d_spec));
			}
		}
	}

	// 2. Custom rules (domains)
	let cust_direct = [];
	let cust_vpn = [];
	if (config.rules) {
		for (let rule in config.rules) {
			if (rule.enabled != '0' && rule.type == 'domain' && util.is_domain(rule.value)) {
				if (rule.action == 'direct') push(cust_direct, rule.value);
				else push(cust_vpn, rule.value);
			}
		}
	}

	if (length(cust_direct) > 0) {
		for (let chunk in chunk_domains(cust_direct, MAX_DOMAINS_PER_LINE, 40)) {
			let d_spec = '/' + join('/', chunk) + '/';
			push(lines, sprintf('server=%s%s', d_spec, primary_direct_dns));
			push(lines, sprintf('nftset=%s4#inet#geovpn#cust_d4_dyn,6#inet#geovpn#cust_d6_dyn', d_spec));
		}
	}

	if (length(cust_vpn) > 0) {
		for (let chunk in chunk_domains(cust_vpn, MAX_DOMAINS_PER_LINE, 40)) {
			let d_spec = '/' + join('/', chunk) + '/';
			push(lines, sprintf('server=%s%s', d_spec, primary_vpn_dns));
			push(lines, sprintf('nftset=%s4#inet#geovpn#cust_v4_dyn,6#inet#geovpn#cust_v6_dyn', d_spec));
		}
	}

	// 3. GeoSite domains
	if (geosite_domains && type(geosite_domains) == 'array' && length(geosite_domains) > 0) {
		let geo_target_dns = (mode == 'bypass') ? primary_direct_dns : primary_vpn_dns;
		for (let chunk in chunk_domains(geosite_domains, MAX_DOMAINS_PER_LINE, 40)) {
			let d_spec = '/' + join('/', chunk) + '/';
			push(lines, sprintf('server=%s%s', d_spec, geo_target_dns));
			push(lines, sprintf('nftset=%s4#inet#geovpn#geo4_dyn,6#inet#geovpn#geo6_dyn', d_spec));
		}
	}

	// 4. DNS Canary (NXDOMAIN for use-application-dns.net to signal browsers to disable DoH)
	if (dns_canary) {
		push(lines, 'address=/use-application-dns.net/');
	}

	return join('\n', lines) + '\n';
}

function apply_dnsmasq(config, geosite_domains, active_profile) {
	let confdir = find_confdir();
	let target_file = confdir + '/geovpn.conf';
	let conf_text = render_dnsmasq_conf(config, geosite_domains, active_profile);

	let existing = '';
	let f_ex = fs.open(target_file, 'r');
	if (f_ex) {
		existing = f_ex.read('all') || '';
		f_ex.close();
	}

	// Only restart dnsmasq if configuration changed
	if (existing == conf_text) {
		util.log('info', 'dnsmasq configuration unchanged; skipping restart');
		return true;
	}

	let tmp_file = target_file + '.tmp';
	let f = fs.open(tmp_file, 'w', 0o644);
	if (!f) {
		util.log('error', sprintf('Cannot write %s', tmp_file));
		return false;
	}
	f.write(conf_text);
	f.close();
	fs.rename(tmp_file, target_file);

	util.log('info', sprintf('Restarting dnsmasq with new GeoVPN configuration in %s', confdir));
	util.safe_exec(['/etc/init.d/dnsmasq', 'restart']);
	return true;
}

function teardown_dnsmasq() {
	let confdir = find_confdir();
	let target_file = confdir + '/geovpn.conf';
	if (fs.stat(target_file)) {
		fs.unlink(target_file);
		util.log('info', 'Removing GeoVPN dnsmasq snippet and restarting dnsmasq');
		util.safe_exec(['/etc/init.d/dnsmasq', 'restart']);
	}
	return true;
}

export {
	find_confdir,
	get_direct_dns_servers,
	get_vpn_dns_servers,
	chunk_domains,
	render_dnsmasq_conf,
	apply_dnsmasq,
	teardown_dnsmasq
};
