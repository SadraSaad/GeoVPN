//
// GeoVPN Pre-Connection Test Engine (§7, §11 A4 / FR-36..39, FR-42..44 / AT-27..30)
// Strictly upholds test-mode invariants T1–T8:
//   T1: Never modify active tunnel, table 4200, rule 700, the classifier, dnsmasq, fw4, or state.json.
//   T2: Fail-closed table 4300 initialized BEFORE test link raised; test traffic only leaves via gvt0.
//   T3: Test marking uses (ip . port) sets with 90s element timeout in inet geovpn; conflict guard.
//   T4: Every created artifact is journaled BEFORE creation; idempotent cleanup.
//   T5: Concurrency limit (1 concurrent test job), hard deadlines (15s per test).
//   T6: Active profile live check only; parallel session credential warning/refusal.
//   T7: Privacy & SSRF validation for probe URLs; results contain no secrets.
//   T8: Zero residual artifacts; verify passes and active state byte-identical.
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';
import * as cfg from './config.uc';
import * as state from './state.uc';
import * as route from './route.uc';
import * as drv_common from './drivers/common.uc';
import * as cred from './cred.uc';

const DEFAULT_RT_TABLE = 4300;
const DEFAULT_RULE_PRIO = 701;
const TEST_MARK = '0x03000000';
const TEST_MASK = '0x0f000000';
const TEST_DEV = 'gvt0';
const DEFAULT_TIMEOUT_S = 15;
const DEFAULT_TARGETS = [
	'https://www.gstatic.com/generate_204',
	'http://cp.cloudflare.com/generate_204'
];

function get_run_dir() {
	return getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn';
}

function get_test_dir() {
	return get_run_dir() + '/test';
}

function get_lock_file() {
	return get_run_dir() + '/test.lock';
}

function get_results_file() {
	return get_test_dir() + '/results.json';
}

function get_job_dir(job_id) {
	return get_test_dir() + '/' + job_id;
}

function get_journal_file(job_id) {
	return get_job_dir(job_id) + '/journal.json';
}

function get_job_file(job_id) {
	return get_job_dir(job_id) + '/job.json';
}

function now_ms() {
	let c = (type(clock) == 'function') ? clock() : null;
	if (c && length(c) >= 2) {
		return c[0] * 1000 + int(c[1] / 1000000);
	}
	return time() * 1000;
}

// ----------------------------------------------------------------------------
// 1. Journal Management (T4: Journal-before-action)
// ----------------------------------------------------------------------------

function journal_init(job_id) {
	let jdir = get_job_dir(job_id);
	if (!fs.stat(jdir)) {
		let tdir = get_test_dir();
		if (!fs.stat(tdir)) fs.mkdir(tdir, 0o700);
		fs.mkdir(jdir, 0o700);
	}
	let jfile = get_journal_file(job_id);
	let f = fs.open(jfile, 'w', 0o600);
	if (f) {
		f.write('[]');
		f.close();
	}
}

function journal_get(job_id) {
	let jfile = get_journal_file(job_id);
	if (!fs.stat(jfile)) return [];
	let f = fs.open(jfile, 'r');
	if (!f) return [];
	let content = f.read('all') || '[]';
	f.close();
	try {
		let arr = json(content);
		return (type(arr) == 'array') ? arr : [];
	} catch (e) {
		return [];
	}
}

function journal_record(job_id, action) {
	let entries = journal_get(job_id);
	push(entries, action);
	let jfile = get_journal_file(job_id);
	let f = fs.open(jfile, 'w', 0o600);
	if (f) {
		f.write(sprintf('%J', entries));
		f.close();
	}
	return action;
}

// ----------------------------------------------------------------------------
// 2. Concurrency & Lock Control (T5)
// ----------------------------------------------------------------------------

function acquire_lock(job_id) {
	let lock_file = get_lock_file();
	let rdir = get_run_dir();
	if (!fs.stat(rdir)) fs.mkdir(rdir, 0o700);

	if (fs.stat(lock_file)) {
		let lf = fs.open(lock_file, 'r');
		if (lf) {
			let lock_content = trim(lf.read('all') || '');
			lf.close();
			let lock_pid = null;
			let parts = split(lock_content, ':');
			if (length(parts) >= 2) lock_pid = +parts[1];
			else if (match(lock_content, /^[0-9]+$/)) lock_pid = +lock_content;

			if (lock_pid) {
				let chk = util.safe_exec(['kill', '-0', sprintf('%d', lock_pid)]);
				if (chk.code == 0) {
					return { ok: false, error: 'BUSY', message: sprintf('Another test job is currently running (PID %d)', lock_pid) };
				}
			}
		}
		// Stale lock
		fs.unlink(lock_file);
	}

	let my_pid = null;
	let pstat = fs.stat('/proc/self');
	if (pstat) {
		let plink = fs.readlink('/proc/self');
		if (plink && match(plink, /^[0-9]+$/)) my_pid = plink;
	}
	let payload = sprintf('%s:%s', job_id, my_pid || '0');
	let f = fs.open(lock_file, 'w', 0o600);
	if (f) {
		f.write(payload);
		f.close();
	}
	journal_record(job_id, { type: 'lock', path: lock_file });
	return { ok: true };
}

function release_lock() {
	let lock_file = get_lock_file();
	if (fs.stat(lock_file)) fs.unlink(lock_file);
}

function check_resource_preflight(test_cfg) {
	let cfg_test = test_cfg || {};
	let min_ram = (cfg_test.min_free_ram_mb != null) ? +cfg_test.min_free_ram_mb : 48;
	let max_load = (cfg_test.max_load != null) ? +cfg_test.max_load : 3.0;

	// Check RAM via /proc/meminfo
	let mf = fs.open('/proc/meminfo', 'r');
	if (mf) {
		let mcontent = mf.read('all') || '';
		mf.close();
		let m_avail = match(mcontent, /MemAvailable:\s+([0-9]+)\s+kB/);
		let free_kb = m_avail ? +m_avail[1] : null;
		if (free_kb == null) {
			let m_free = match(mcontent, /MemFree:\s+([0-9]+)\s+kB/);
			let m_buf = match(mcontent, /Buffers:\s+([0-9]+)\s+kB/);
			let m_cache = match(mcontent, /Cached:\s+([0-9]+)\s+kB/);
			if (m_free) {
				free_kb = +m_free[1] + (m_buf ? +m_buf[1] : 0) + (m_cache ? +m_cache[1] : 0);
			}
		}
		if (free_kb != null) {
			let free_mb = free_kb / 1024;
			if (free_mb < min_ram) {
				return {
					ok: false,
					reason: 'resources',
					hint: sprintf('Insufficient free RAM (%.1f MB < %d MB limit)', free_mb, min_ram)
				};
			}
		}
	}

	// Check load average via /proc/loadavg
	let lf = fs.open('/proc/loadavg', 'r');
	if (lf) {
		let lcontent = lf.read('all') || '';
		lf.close();
		let lparts = split(trim(lcontent), ' ');
		if (length(lparts) > 0) {
			let load1 = +lparts[0];
			if (load1 > max_load) {
				return {
					ok: false,
					reason: 'resources',
					hint: sprintf('System load too high (%.2f > %.2f limit)', load1, max_load)
				};
			}
		}
	}

	return { ok: true };
}

// ----------------------------------------------------------------------------
// 3. SSRF & URL Validation (T7)
// ----------------------------------------------------------------------------

function is_private_ipv4(ip) {
	if (!util.is_ipv4(ip)) return false;
	let parts = split(ip, '.');
	let p0 = +parts[0];
	let p1 = +parts[1];

	if (p0 == 0) return true;                           // 0.0.0.0/8
	if (p0 == 10) return true;                          // 10.0.0.0/8
	if (p0 == 127) return true;                         // 127.0.0.0/8 (loopback)
	if (p0 == 169 && p1 == 254) return true;            // 169.254.0.0/16 (link-local, cloud metadata)
	if (p0 == 172 && (p1 >= 16 && p1 <= 31)) return true; // 172.16.0.0/12
	if (p0 == 192 && p1 == 168) return true;            // 192.168.0.0/16
	if (p0 == 100 && (p1 >= 64 && p1 <= 127)) return true; // 100.64.0.0/10 (CGNAT)
	if (p0 >= 224) return true;                         // 224.0.0.0/4 multicast & reserved
	if (ip == '255.255.255.255') return true;
	return false;
}

function is_private_ipv6(ip) {
	if (type(ip) != 'string') return false;
	let s = lc(ip);
	if (s == '::' || s == '::1') return true;
	if (substr(s, 0, 2) == 'fc' || substr(s, 0, 2) == 'fd') return true; // Unique local (fc00::/7)
	if (substr(s, 0, 4) == 'fe80' || substr(s, 0, 4) == 'fe90' ||
	    substr(s, 0, 4) == 'fea0' || substr(s, 0, 4) == 'feb0') return true; // Link-local (fe80::/10)
	if (substr(s, 0, 2) == 'ff') return true; // Multicast
	if (substr(s, 0, 7) == '::ffff:' || index(s, ':ffff:') != -1) return true; // IPv4-mapped IPv6
	if (!util.is_ipv6(ip)) return false;
	return false;
}

function resolve_target_host(host) {
	if (util.is_ip(host)) return [host];
	let ips = [];
	let has_ns = (fs.stat('/usr/bin/nslookup') != null) || (fs.stat('/bin/nslookup') != null) || (util.safe_exec(['which', 'nslookup']).code == 0);
	if (has_ns) {
		let res = util.safe_exec(['nslookup', host]);
		if (res && res.code == 0 && res.stdout) {
			let lines = split(res.stdout, '\n');
			let in_answer = false;
			for (let line in lines) {
				if (index(line, 'Name:') != -1 || index(line, 'answer:') != -1) {
					in_answer = true;
				}
				if (in_answer) {
					let m = match(line, /Address([ \t]+[0-9]+)?:?[ \t]+([0-9.]+)/);
					if (m && m[2] && util.is_ipv4(m[2])) push(ips, m[2]);
					let m6 = match(line, /Address([ \t]+[0-9]+)?:?[ \t]+([0-9a-fA-F:]+)/);
					if (m6 && m6[2] && util.is_ipv6(m6[2])) push(ips, m6[2]);
				}
			}
		}
	}
	if (length(ips) == 0) {
		let gres = util.safe_exec(['getent', 'hosts', host]);
		if (gres && gres.code == 0 && gres.stdout) {
			let glines = split(gres.stdout, '\n');
			for (let line in glines) {
				let parts = split(trim(line), /[ \t]+/);
				if (parts && parts[0] && util.is_ip(parts[0])) {
					push(ips, parts[0]);
				}
			}
		}
	}
	return ips;
}

function validate_probe_url(url_str) {
	if (!url_str || type(url_str) != 'string') {
		return { ok: false, error: 'INVALID_URL', message: 'URL string is required' };
	}
	if (length(url_str) > 200) {
		return { ok: false, error: 'URL_TOO_LONG', message: 'URL exceeds maximum length of 200 characters' };
	}
	if (index(url_str, '@') != -1) {
		return { ok: false, error: 'SSRF_PROHIBITED', message: 'User credentials/userinfo forbidden in probe URL' };
	}

	let m = match(url_str, /^(https?):\/\/([a-zA-Z0-9._-]+|\[[a-fA-F0-9:.]+\])(:([0-9]+))?(\/.*)?$/);
	if (!m) {
		return { ok: false, error: 'INVALID_URL', message: 'URL must be a valid http:// or https:// address' };
	}

	let scheme = m[1];
	let raw_host = m[2];
	let port = m[4] ? +m[4] : (scheme == 'https' ? 443 : 80);
	let path = m[5] || '/';

	let host = raw_host;
	if (substr(host, 0, 1) == '[' && substr(host, length(host) - 1, 1) == ']') {
		host = substr(host, 1, length(host) - 2);
	}

	let allowed_ports = [80, 443, 8080, 8443];
	let port_allowed = false;
	for (let p in allowed_ports) {
		if (p == port) { port_allowed = true; break; }
	}
	if (!port_allowed) {
		return { ok: false, error: 'PORT_PROHIBITED', message: sprintf('Port %d is not in probe allowlist (80, 443, 8080, 8443)', port) };
	}

	if (lc(host) == 'localhost') {
		return { ok: false, error: 'SSRF_PROHIBITED', message: 'Loopback hostname localhost prohibited' };
	}

	if (util.is_ipv4(host)) {
		if (is_private_ipv4(host)) {
			return { ok: false, error: 'SSRF_PROHIBITED', message: sprintf('Private or loopback IPv4 address %s prohibited', host) };
		}
	} else if (util.is_ipv6(host) || substr(lc(host), 0, 7) == '::ffff:' || index(lc(host), ':ffff:') != -1) {
		if (is_private_ipv6(host)) {
			return { ok: false, error: 'SSRF_PROHIBITED', message: sprintf('Private or loopback IPv6 address %s prohibited', host) };
		}
	} else {
		// Domain name: resolve and inspect resolved IPs
		let resolved_ips = resolve_target_host(host);
		for (let ip in resolved_ips) {
			if (is_private_ipv4(ip) || is_private_ipv6(ip)) {
				return { ok: false, error: 'SSRF_PROHIBITED', message: sprintf('Domain %s resolves to private address %s', host, ip) };
			}
		}
	}

	return {
		ok: true,
		scheme: scheme,
		host: host,
		port: port,
		path: path,
		url: url_str
	};
}

// ----------------------------------------------------------------------------
// 4. Conflict Guard (T3)
// ----------------------------------------------------------------------------

function check_target_conflict(ip, port, main_cfg, active_profile) {
	if (!ip || !port) return false;

	// 1. Check against private/loopback
	if (is_private_ipv4(ip) || is_private_ipv6(ip)) return true;

	// 2. Check against active tunnel endpoints
	if (active_profile) {
		if (active_profile.remotes) {
			for (let r in active_profile.remotes) {
				let parts = split(r, ' ');
				if (parts && parts[0] == ip) return true;
			}
		}
		if (active_profile.wg_endpoint_host == ip) return true;
	}

	// 3. Check against VPN DNS infrastructure (prevent stealing active router DNS queries)
	let active_dns = ['1.1.1.1', '9.9.9.9'];
	if (main_cfg && main_cfg.dns_vpn_servers) {
		let dlist = main_cfg.dns_vpn_servers;
		if (type(dlist) == 'string') dlist = [dlist];
		for (let d in dlist) push(active_dns, d);
	}
	for (let ad in active_dns) {
		if (ad == ip && (port == 53 || port == 853)) return true;
	}

	return false;
}

// ----------------------------------------------------------------------------
// 5. Fail-Closed Routing & Nftables Test Invariant Setup (T2, T3)
// ----------------------------------------------------------------------------

function setup_test_nft(job_id) {
	// 1. Ensure table inet geovpn exists (journal BEFORE action - T4)
	let has_table = (util.safe_exec(['nft', 'list', 'table', 'inet', 'geovpn']).code == 0);
	if (!has_table) {
		journal_record(job_id, { type: 'nft_table', family: 'inet', name: 'geovpn' });
		util.safe_exec(['nft', 'add', 'table', 'inet', 'geovpn']);
	}

	// 2. Define test sets with 90s element timeout (T3, journal BEFORE action - T4)
	let sets = [
		{ name: 'test_dst4', type: 'ipv4_addr . inet_service', size: 256 },
		{ name: 'test_dst6', type: 'ipv6_addr . inet_service', size: 256 },
		{ name: 'test_ep4', type: 'ipv4_addr', size: 64 },
		{ name: 'test_ep6', type: 'ipv6_addr', size: 64 }
	];

	for (let s in sets) {
		journal_record(job_id, { type: 'nft_set', family: 'inet', table: 'geovpn', name: s.name });
		util.safe_exec(['nft', 'add', 'set', 'inet', 'geovpn', s.name, sprintf('{ type %s; flags timeout; timeout 90s; size %d; }', s.type, s.size)]);
	}

	// 3. Define test_guard output drop chain (T2, journal BEFORE action - T4)
	journal_record(job_id, { type: 'nft_chain', family: 'inet', table: 'geovpn', name: 'test_guard' });
	util.safe_exec(['nft', 'add', 'chain', 'inet', 'geovpn', 'test_guard', '{ type filter hook output priority filter - 1; policy accept; }']);

	let guard_rule = sprintf('meta mark & %s == %s oifname != "%s" drop', TEST_MASK, TEST_MARK, TEST_DEV);
	journal_record(job_id, { type: 'nft_guard_rule', family: 'inet', table: 'geovpn', chain: 'test_guard', spec: guard_rule });
	util.safe_exec(['nft', 'add', 'rule', 'inet', 'geovpn', 'test_guard', guard_rule]);

	// 4. Ensure chain out exists for test marking
	let has_out = (util.safe_exec(['nft', 'list', 'chain', 'inet', 'geovpn', 'out']).code == 0);
	if (!has_out) {
		journal_record(job_id, { type: 'nft_chain', family: 'inet', table: 'geovpn', name: 'out' });
		util.safe_exec(['nft', 'add', 'chain', 'inet', 'geovpn', 'out', '{ type route hook output priority mangle; policy accept; }']);
	}

	// Terminal test accept rule in out
	let r_term = sprintf('meta mark & %s == %s accept', TEST_MASK, TEST_MARK);
	journal_record(job_id, { type: 'nft_out_rule', spec: r_term });
	util.safe_exec(['nft', 'insert', 'rule', 'inet', 'geovpn', 'out', r_term]);

	// IPv6 test_dst6 marking rule
	let r_v6 = sprintf('meta l4proto { tcp, udp } ip6 daddr . th dport @test_dst6 meta mark set meta mark & 0xf0ffffff | %s accept', TEST_MARK);
	journal_record(job_id, { type: 'nft_out_rule', spec: r_v6 });
	util.safe_exec(['nft', 'insert', 'rule', 'inet', 'geovpn', 'out', r_v6]);

	// IPv4 test_dst4 marking rule
	let r_v4 = sprintf('meta l4proto { tcp, udp } ip daddr . th dport @test_dst4 meta mark set meta mark & 0xf0ffffff | %s accept', TEST_MARK);
	journal_record(job_id, { type: 'nft_out_rule', spec: r_v4 });
	util.safe_exec(['nft', 'insert', 'rule', 'inet', 'geovpn', 'out', r_v4]);

	return true;
}

function setup_test_routing(job_id, table_id, prio_id) {
	let table = table_id || DEFAULT_RT_TABLE;
	let prio = prio_id || DEFAULT_RULE_PRIO;

	// Invariant T2: Journal fail-closed routes BEFORE applying them
	journal_record(job_id, { type: 'ip_rule', family: 4, prio: prio, table: table });
	journal_record(job_id, { type: 'ip_rule', family: 6, prio: prio, table: table });
	journal_record(job_id, { type: 'route_unreachable', family: 4, table: table });
	journal_record(job_id, { type: 'route_unreachable', family: 6, table: table });

	// Apply fail-closed route table 4300 and rule 701 via route.uc
	return route.test_route_init(table, prio);
}

function add_test_endpoint(job_id, ip) {
	if (!ip) return;
	let set_name = util.is_ipv6(ip) ? 'test_ep6' : 'test_ep4';
	// Journal BEFORE creation (T4)
	journal_record(job_id, { type: 'nft_element', set: set_name, elem: ip });
	util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', set_name, sprintf('{ %s }', ip)]);
}

function add_test_target(job_id, ip, port) {
	if (!ip || !port) return false;
	let set_name = util.is_ipv6(ip) ? 'test_dst6' : 'test_dst4';
	let elem_spec = sprintf('%s . %d', ip, port);
	// Journal BEFORE creation (T4)
	journal_record(job_id, { type: 'nft_element', set: set_name, elem: elem_spec });
	let res = util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', set_name, sprintf('{ %s }', elem_spec)]);
	return (res.code == 0);
}

// ----------------------------------------------------------------------------
// 6. Cleanup & Verification (T4, T8)
// ----------------------------------------------------------------------------

function test_cleanup(target_job_id, verify) {
	let test_dir = get_test_dir();
	let job_ids = [];

	if (target_job_id) {
		push(job_ids, target_job_id);
	} else if (fs.stat(test_dir)) {
		let list = fs.lsdir(test_dir);
		if (list && type(list) == 'array') {
			for (let entry in list) {
				if (entry != '.' && entry != '..' && entry != 'results.json' && fs.stat(test_dir + '/' + entry)) {
					push(job_ids, entry);
				}
			}
		}
	}

	let leftover_errors = [];

	// 1. Replay journals for identified jobs in reverse (T4)
	for (let jid in job_ids) {
		let journal = journal_get(jid);
		for (let i = length(journal) - 1; i >= 0; i--) {
			let act = journal[i];
			if (!act || !act.type) continue;

			if (act.type == 'route_default') {
				util.safe_exec(['ip', '-4', 'route', 'del', 'default', 'dev', act.dev || TEST_DEV, 'table', sprintf('%d', act.table || DEFAULT_RT_TABLE)]);
				util.safe_exec(['ip', '-6', 'route', 'del', 'default', 'dev', act.dev || TEST_DEV, 'table', sprintf('%d', act.table || DEFAULT_RT_TABLE)]);
			} else if (act.type == 'route_unreachable') {
				util.safe_exec(['ip', sprintf('-%d', act.family || 4), 'route', 'del', 'unreachable', 'default', 'table', sprintf('%d', act.table || DEFAULT_RT_TABLE), 'metric', '4000']);
			} else if (act.type == 'ip_rule') {
				util.safe_exec(['ip', sprintf('-%d', act.family || 4), 'rule', 'del', 'priority', sprintf('%d', act.prio || DEFAULT_RULE_PRIO)]);
			} else if (act.type == 'link') {
				util.safe_exec(['ip', 'link', 'del', 'dev', act.dev || TEST_DEV]);
			} else if (act.type == 'proc') {
				if (act.pid) {
					util.safe_exec(['kill', '-15', sprintf('%d', act.pid)]);
				}
				if (act.pid_file && fs.stat(act.pid_file)) {
					let pf = fs.open(act.pid_file, 'r');
					if (pf) {
						let pid_str = trim(pf.read('all') || '');
						pf.close();
						if (pid_str && match(pid_str, /^[0-9]+$/)) {
							util.safe_exec(['kill', '-15', pid_str]);
							util.safe_exec(['kill', '-9', pid_str]);
						}
					}
					fs.unlink(act.pid_file);
				}
			} else if (act.type == 'nft_element') {
				util.safe_exec(['nft', 'delete', 'element', 'inet', 'geovpn', act.set, sprintf('{ %s }', act.elem)]);
			} else if (act.type == 'nft_chain') {
				util.safe_exec(['nft', 'delete', 'chain', 'inet', 'geovpn', act.name]);
			} else if (act.type == 'nft_set') {
				util.safe_exec(['nft', 'delete', 'set', 'inet', 'geovpn', act.name]);
			} else if (act.type == 'nft_table') {
				util.safe_exec(['nft', 'delete', 'table', act.family || 'inet', act.name]);
			} else if (act.type == 'nft_guard_rule') {
				util.safe_exec(['nft', 'delete', 'chain', 'inet', 'geovpn', act.chain || 'test_guard']);
			} else if (act.type == 'nft_out_rule') {
				// Handled in out chain rule cleanup
			} else if (act.type == 'lock' && act.path) {
				if (fs.stat(act.path)) fs.unlink(act.path);
			}
		}

		// Clean job working directory (preserve job.json if target_job_id is specified)
		let jdir = get_job_dir(jid);
		if (fs.stat(jdir)) {
			let jfiles = fs.lsdir(jdir);
			let has_job_json = false;
			if (jfiles) {
				for (let f in jfiles) {
					if (target_job_id && f == 'job.json') {
						has_job_json = true;
					} else if (f != '.' && f != '..') {
						fs.unlink(jdir + '/' + f);
					}
				}
			}
			if (!has_job_json) {
				fs.rmdir(jdir);
			}
		}
	}

	// 2. Global Sweep: Ensure unconditional removal of test routing table, rules, link, and nftables sets
	route.test_route_teardown(DEFAULT_RT_TABLE, DEFAULT_RULE_PRIO);
	util.safe_exec(['ip', 'link', 'del', 'dev', TEST_DEV]);

	// Clean test rules from chain out by rule handle (T1, T8)
	let out_list = util.safe_exec(['nft', '-a', 'list', 'chain', 'inet', 'geovpn', 'out']);
	if (out_list && out_list.code == 0 && out_list.stdout) {
		let olines = split(out_list.stdout, '\n');
		for (let line in olines) {
			if (index(line, 'test_dst') != -1 || index(line, TEST_MARK) != -1 || index(line, '0x03000000') != -1 || index(line, '0x3000000') != -1 || index(line, 'test_ep') != -1) {
				let hm = match(line, /# handle ([0-9]+)/);
				if (hm && hm[1]) {
					util.safe_exec(['nft', 'delete', 'rule', 'inet', 'geovpn', 'out', 'handle', hm[1]]);
				}
			}
		}
	}

	// Stop any test OpenVPN procd instance
	util.safe_exec(['/etc/init.d/geovpn-test', 'stop']);

	// Stop any test IKEv2 connection and remove test XFRM interface
	let ike_drv = drv_common.get_driver('ikev2');
	if (ike_drv) {
		if (length(job_ids) > 0) {
			for (let jid in job_ids) {
				let tctx = drv_common.create_context('test', 'test', { dev: TEST_DEV, jid: jid });
				if (ike_drv.stop) ike_drv.stop(tctx);
				else if (ike_drv.cleanup) ike_drv.cleanup(tctx);
			}
		} else {
			let tctx = drv_common.create_context('test', 'test', { dev: TEST_DEV, jid: target_job_id || 'test' });
			if (ike_drv.stop) ike_drv.stop(tctx);
			else if (ike_drv.cleanup) ike_drv.cleanup(tctx);
		}
	}

	// Clean nftables artifacts if present
	util.safe_exec(['nft', 'delete', 'chain', 'inet', 'geovpn', 'test_guard']);
	util.safe_exec(['nft', 'delete', 'set', 'inet', 'geovpn', 'test_dst4']);
	util.safe_exec(['nft', 'delete', 'set', 'inet', 'geovpn', 'test_dst6']);
	util.safe_exec(['nft', 'delete', 'set', 'inet', 'geovpn', 'test_ep4']);
	util.safe_exec(['nft', 'delete', 'set', 'inet', 'geovpn', 'test_ep6']);

	// If table inet geovpn was created purely for tests and has no other chains/rules, delete it
	let active_rules = util.safe_exec(['nft', 'list', 'chain', 'inet', 'geovpn', 'classify']);
	if (active_rules.code != 0) {
		let tlist = util.safe_exec(['nft', 'list', 'table', 'inet', 'geovpn']);
		if (tlist.code == 0) {
			util.safe_exec(['nft', 'delete', 'table', 'inet', 'geovpn']);
		}
	}

	release_lock();

	// 3. Verification Post-Condition Checks (T8 / --verify)
	let leftovers = [];
	if (verify) {
		let link_chk = util.safe_exec(['ip', 'link', 'show', 'dev', TEST_DEV]);
		if (link_chk.code == 0) push(leftovers, sprintf('Link %s still exists', TEST_DEV));

		let r4_chk = util.safe_exec(['ip', '-4', 'rule', 'show', 'priority', sprintf('%d', DEFAULT_RULE_PRIO)]);
		if (r4_chk.code == 0 && trim(r4_chk.stdout) != '') push(leftovers, sprintf('IPv4 rule priority %d still present: %s', DEFAULT_RULE_PRIO, trim(r4_chk.stdout)));

		let r6_chk = util.safe_exec(['ip', '-6', 'rule', 'show', 'priority', sprintf('%d', DEFAULT_RULE_PRIO)]);
		if (r6_chk.code == 0 && trim(r6_chk.stdout) != '') push(leftovers, sprintf('IPv6 rule priority %d still present: %s', DEFAULT_RULE_PRIO, trim(r6_chk.stdout)));

		let route4_chk = util.safe_exec(['ip', '-4', 'route', 'show', 'table', sprintf('%d', DEFAULT_RT_TABLE)]);
		if (route4_chk.code == 0 && trim(route4_chk.stdout) != '') push(leftovers, sprintf('IPv4 table %d not empty: %s', DEFAULT_RT_TABLE, trim(route4_chk.stdout)));

		let route6_chk = util.safe_exec(['ip', '-6', 'route', 'show', 'table', sprintf('%d', DEFAULT_RT_TABLE)]);
		if (route6_chk.code == 0 && trim(route6_chk.stdout) != '') push(leftovers, sprintf('IPv6 table %d not empty: %s', DEFAULT_RT_TABLE, trim(route6_chk.stdout)));

		let guard_chk = util.safe_exec(['nft', 'list', 'chain', 'inet', 'geovpn', 'test_guard']);
		if (guard_chk.code == 0) push(leftovers, 'nftables chain test_guard still exists');

		let dst4_chk = util.safe_exec(['nft', 'list', 'set', 'inet', 'geovpn', 'test_dst4']);
		if (dst4_chk.code == 0) push(leftovers, 'nftables set test_dst4 still exists');

		let dst6_chk = util.safe_exec(['nft', 'list', 'set', 'inet', 'geovpn', 'test_dst6']);
		if (dst6_chk.code == 0) push(leftovers, 'nftables set test_dst6 still exists');

		let ep4_chk = util.safe_exec(['nft', 'list', 'set', 'inet', 'geovpn', 'test_ep4']);
		if (ep4_chk.code == 0) push(leftovers, 'nftables set test_ep4 still exists');

		let ep6_chk = util.safe_exec(['nft', 'list', 'set', 'inet', 'geovpn', 'test_ep6']);
		if (ep6_chk.code == 0) push(leftovers, 'nftables set test_ep6 still exists');

		if (fs.stat(get_lock_file())) push(leftovers, 'test.lock still exists');
	}

	return {
		ok: (length(leftovers) == 0),
		verified: (verify == true),
		leftovers: leftovers
	};
}

// ----------------------------------------------------------------------------
// 7. Thresholds, Scoring, and Ranking (§7.5)
// ----------------------------------------------------------------------------

function score_result(metrics, test_cfg) {
	let cfg_test = test_cfg || {};
	let max_hs = cfg_test.max_handshake_ms || 8000;
	let max_lat = cfg_test.max_latency_ms || 800;
	let max_loss = cfg_test.max_loss_pct || 34;
	let req_http = (cfg_test.require_http != '0' && cfg_test.require_http != false && cfg_test.require_http != 0);

	if (!metrics.handshake_ok) {
		return {
			status: 'fail',
			reason: metrics.reason || 'no_handshake',
			hint: metrics.hint || 'No handshake or tunnel connection failed'
		};
	}

	if (req_http) {
		if (!metrics.url || metrics.url.ok_samples == 0 || metrics.url.median_ms == null) {
			return {
				status: 'fail',
				reason: metrics.reason || 'http_failed',
				hint: metrics.hint || 'HTTP probe failed through test tunnel'
			};
		}
		let loss = metrics.url.loss_pct;
		if (loss > max_loss) {
			return {
				status: 'fail',
				reason: 'http_failed',
				hint: sprintf('Packet loss %d%% exceeded threshold %d%%', loss, max_loss)
			};
		}
	}

	if (metrics.handshake_ms != null && metrics.handshake_ms > max_hs) {
		return {
			status: 'warn',
			reason: 'latency',
			hint: sprintf('Handshake latency %d ms exceeded threshold %d ms', metrics.handshake_ms, max_hs)
		};
	}

	if (req_http && metrics.url && metrics.url.median_ms != null && metrics.url.median_ms > max_lat) {
		return {
			status: 'warn',
			reason: 'latency',
			hint: sprintf('Median HTTP latency %d ms exceeded threshold %d ms', metrics.url.median_ms, max_lat)
		};
	}

	return {
		status: 'pass',
		reason: null,
		hint: null
	};
}

function rank_results(results, test_cfg) {
	if (!results || type(results) != 'array') return [];
	let cfg_test = test_cfg || {};
	let tolerance = cfg_test.tolerance_ms || 50;
	let proto_pref = cfg_test.proto_preference || ['wireguard', 'openvpn', 'ikev2'];

	function status_weight(st) {
		if (st == 'pass') return 4;
		if (st == 'warn') return 3;
		if (st == 'fail') return 2;
		if (st == 'error') return 1;
		return 0; // skipped / cancelled
	}

	function proto_weight(p) {
		for (let i = 0; i < length(proto_pref); i++) {
			if (proto_pref[i] == p) return 10 - i;
		}
		return 0;
	}

	let sorted = slice(results, 0);
	for (let i = 0; i < length(sorted); i++) {
		for (let j = i + 1; j < length(sorted); j++) {
			let a = sorted[i];
			let b = sorted[j];

			let swap = false;
			let wa = status_weight(a.status);
			let wb = status_weight(b.status);
			if (wb > wa) {
				swap = true;
			} else if (wb == wa) {
				// Compare HTTP median latency
				let la = (a.url && a.url.median_ms != null) ? a.url.median_ms : 999999;
				let lb = (b.url && b.url.median_ms != null) ? b.url.median_ms : 999999;

				let diff = lb - la;
				if (diff < -tolerance) {
					swap = true; // b is noticeably faster than a
				} else if (diff > tolerance) {
					swap = false; // a is noticeably faster than b
				} else {
					// Latencies tied within tolerance: compare handshake time
					let ha = (a.handshake_ms != null) ? a.handshake_ms : 999999;
					let hb = (b.handshake_ms != null) ? b.handshake_ms : 999999;
					if (hb < ha) {
						swap = true;
					} else if (hb == ha) {
						// Compare protocol preference
						let pa = proto_weight(a.proto);
						let pb = proto_weight(b.proto);
						if (pb > pa) swap = true;
						else if (pb == pa) {
							// Alphabetical by name
							if ((b.name || b.id) < (a.name || a.id)) swap = true;
						}
					}
				}
			}

			if (swap) {
				let tmp = sorted[i];
				sorted[i] = sorted[j];
				sorted[j] = tmp;
			}
		}
	}

	return sorted;
}

// ----------------------------------------------------------------------------
// 8. Probe Execution (§7.4)
// ----------------------------------------------------------------------------

function execute_probe(job_id, target_url, sample_timeout_s, tunnel_dns, samples_count) {
	let val = validate_probe_url(target_url);
	if (!val.ok) {
		return { ok: false, error: val.error, message: val.message };
	}

	let target_ips = resolve_target_host(val.host);
	let target_ip = (length(target_ips) > 0) ? target_ips[0] : val.host;

	// Invariant T3: Conflict guard
	let c = cfg.load_config();
	let active_p = c.main && c.main.active_profile ? cfg.get_profile(c.main.active_profile) : null;
	if (check_target_conflict(target_ip, val.port, c.main, active_p)) {
		return { ok: false, error: 'target_conflict', message: 'Target IP conflicts with active router policy or DNS' };
	}

	let is_live = (job_id == 'live');

	if (is_live) {
		// Live check: steer through active tunnel via fetch_vpn set in table 4200 (T1, T6)
		let set_name = util.is_ipv6(target_ip) ? 'fetch_vpn6' : 'fetch_vpn4';
		util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', set_name, sprintf('{ %s }', target_ip)]);
	} else {
		// Isolated test: steer target into test tunnel via test_dst4/6 in table 4300 (T2, T3)
		add_test_target(job_id, target_ip, val.port);
		if (tunnel_dns && util.is_ip(tunnel_dns)) {
			add_test_target(job_id, tunnel_dns, 53);
		}
	}

	let n_samples = samples_count || 3;
	let timeout_sec = sample_timeout_s || 5;
	let successful_latencies = [];

	let has_ufetch = (fs.stat('/usr/bin/uclient-fetch') != null) || (fs.stat('/bin/uclient-fetch') != null) || (util.safe_exec(['which', 'uclient-fetch']).code == 0);
	let has_curl = (fs.stat('/usr/bin/curl') != null) || (util.safe_exec(['which', 'curl']).code == 0);

	for (let s = 0; s < n_samples; s++) {
		let t0 = now_ms();
		let ok = false;

		if (has_ufetch) {
			let cmd = ['uclient-fetch', '-q', '-T', sprintf('%d', timeout_sec), '-O', '/dev/null', '-U', 'geovpn-test', val.url];
			let r = util.safe_exec(cmd);
			ok = (r.code == 0);
		} else if (has_curl) {
			let cmd = ['curl', '-s', '-m', sprintf('%d', timeout_sec), '-o', '/dev/null', '-A', 'geovpn-test', val.url];
			let r = util.safe_exec(cmd);
			ok = (r.code == 0);
		} else {
			// Fallback: bounded TCP connect probe via nc with strict timeout (VA-04)
			let cmd = ['nc', '-w', sprintf('%d', timeout_sec), target_ip, sprintf('%d', val.port)];
			let r = util.safe_exec(cmd);
			ok = (r.code == 0);
		}

		let t1 = now_ms();
		let elapsed = t1 - t0;
		if (ok) {
			push(successful_latencies, elapsed);
		}
	}

	if (is_live) {
		let set_name = util.is_ipv6(target_ip) ? 'fetch_vpn6' : 'fetch_vpn4';
		util.safe_exec(['nft', 'delete', 'element', 'inet', 'geovpn', set_name, sprintf('{ %s }', target_ip)]);
	}

	let ok_cnt = length(successful_latencies);
	let loss_pct = int(((n_samples - ok_cnt) / n_samples) * 100);

	let median_ms = null;
	let min_ms = null;
	let jitter_ms = null;

	if (ok_cnt > 0) {
		// Numerical sort
		for (let i = 0; i < length(successful_latencies); i++) {
			for (let j = i + 1; j < length(successful_latencies); j++) {
				if (successful_latencies[j] < successful_latencies[i]) {
					let tmp = successful_latencies[i];
					successful_latencies[i] = successful_latencies[j];
					successful_latencies[j] = tmp;
				}
			}
		}
		min_ms = successful_latencies[0];
		let max_ms = successful_latencies[length(successful_latencies) - 1];
		jitter_ms = max_ms - min_ms;
		median_ms = successful_latencies[int(length(successful_latencies) / 2)];
	}

	return {
		ok: (ok_cnt > 0),
		samples: n_samples,
		ok_samples: ok_cnt,
		median_ms: median_ms,
		median: median_ms,
		min_ms: min_ms,
		jitter_ms: jitter_ms,
		loss_pct: loss_pct
	};
}

// ----------------------------------------------------------------------------
// 9. Single-Profile Test Runner (WireGuard, OpenVPN, Live Check)
// ----------------------------------------------------------------------------

function run_live_check(profile, opts, profile_id) {
	let c = cfg.load_config();
	let act_id = cfg.get_effective_active_profile_id ? cfg.get_effective_active_profile_id(c) : (c.main && c.main.active_profile);
	let pid = profile_id || (profile && (profile.id || profile['.name'])) || act_id;
	let active_ctx = drv_common.create_context('active', act_id, {
		proto: profile.proto || 'openvpn',
		dev: c.main.tun_dev || 'geovpn0',
		table: 4200,
		rundir: get_run_dir()
	});

	let facts = drv_common.facts(active_ctx);
	let st = state.get_state();
	let is_up = (facts && (facts.up || facts.state == 'connected')) || (st && st.service && st.service.state == 'connected');

	if (!is_up) {
		return {
			id: pid,
			proto: profile.proto || 'openvpn',
			status: 'fail',
			tested_at: time(),
			probe_ms: null,
			handshake_ms: null,
			url: null,
			speed_mbps: null,
			reason: 'active_tunnel_down',
			hint: 'Live check on active profile: active tunnel is disconnected',
			warnings: []
		};
	}

	// Measure URL latency through live connection (marked into table 4200)
	let probe_url = opts && opts.probe_url ? opts.probe_url : DEFAULT_TARGETS[0];
	let probe_res = execute_probe('live', probe_url, 5, null, 3);

	return {
		id: pid,
		proto: profile.proto || 'openvpn',
		status: (probe_res.ok ? 'pass' : 'warn'),
		tested_at: time(),
		probe_ms: null,
		handshake_ms: (facts && facts.since ? (now_ms() - facts.since * 1000) : 0),
		url: probe_res.ok ? {
			samples: probe_res.samples,
			ok: probe_res.ok_samples,
			median_ms: probe_res.median_ms,
			median: probe_res.median_ms,
			min_ms: probe_res.min_ms,
			jitter_ms: probe_res.jitter_ms,
			loss_pct: probe_res.loss_pct
		} : null,
		speed_mbps: null,
		reason: probe_res.ok ? null : (probe_res.error || 'http_failed'),
		hint: 'Live check on active profile (no secondary tunnel)',
		warnings: []
	};
}

function test_profile(profile_id, opts) {
	let options = opts || {};
	let c = cfg.load_config();
	let profile = cfg.get_profile(profile_id);

	if (!profile) {
		return { id: profile_id, status: 'error', reason: 'not_found', hint: 'Profile not found' };
	}
	profile.id = profile.id || profile_id || profile['.name'];

	let proto = profile.proto || 'openvpn';
	let act_id = cfg.get_effective_active_profile_id ? cfg.get_effective_active_profile_id(c) : (c.main && c.main.active_profile);

	// Invariant T6: Active profile live check only
	if (profile_id == act_id || options.live_check_only) {
		return run_live_check(profile, options, profile_id);
	}

	// Invariant T6: Shared credential / key collision warning / refusal
	let warnings = [];
	let act_p = act_id ? cfg.get_profile(act_id) : null;
	let act_cred = (act_p && act_p.cred) || (c.main && c.main.cred) || null;
	let is_same_cred = false;
	if (profile.cred && act_cred && profile.cred == act_cred) is_same_cred = true;
	let u1 = profile.ike_username || profile.username;
	if (!u1 && profile.cred) {
		let up1 = cred.get_userpass(profile.cred);
		if (up1 && up1.username) u1 = up1.username;
	}
	let u2 = act_p ? (act_p.ike_username || act_p.username) : null;
	if (!u2 && act_cred) {
		let up2 = cred.get_userpass(act_cred);
		if (up2 && up2.username) u2 = up2.username;
	}
	if (u1 && u2 && u1 == u2) is_same_cred = true;

	if (is_same_cred) {
		if (proto == 'ikev2' || (act_p && act_p.proto == 'ikev2')) {
			return {
				id: profile_id,
				proto: proto,
				status: 'fail',
				tested_at: time(),
				reason: 'parallel_session_refused',
				hint: 'IKEv2 profile shares credentials with active tunnel; refused to prevent active connection drop',
				warnings: []
			};
		}
		push(warnings, 'Profile shares credentials with active tunnel; server may terminate existing session');
	}
	if (proto == 'wireguard' && act_p && act_p.proto == 'wireguard') {
		if (profile.wg_public_key && act_p.wg_public_key && profile.wg_public_key == act_p.wg_public_key) {
			push(warnings, 'Profile shares WireGuard keys with active tunnel; server may terminate existing session');
		}
	}

	// Preflight: Driver availability
	let avail = drv_common.available ? drv_common.available(proto) : null;
	if (!avail) {
		let drv = drv_common.get_driver(proto);
		avail = (drv && drv.available) ? drv.available() : { ok: false, note: sprintf('Driver for %s not found', proto) };
	}
	if (!avail.ok) {
		return {
			id: profile_id,
			proto: proto,
			status: 'fail',
			tested_at: time(),
			reason: 'driver_missing',
			hint: avail.note || 'Required driver packages are not installed',
			warnings: warnings
		};
	}

	// Preflight: Resource checks (RAM, load) per §7.8 / FR-43
	let pre_res = check_resource_preflight(c.test);
	if (!pre_res.ok) {
		return {
			id: profile_id,
			proto: proto,
			status: 'fail',
			tested_at: time(),
			reason: pre_res.reason,
			hint: pre_res.hint,
			warnings: warnings
		};
	}

	// Preflight: Concurrency lock (T5)
	let job_id = options.job_id || ('t' + substr(sprintf('%08x', time()), 0, 8) + substr(sprintf('%04x', rand() % 65536), 0, 4));
	let held_own_lock = false;
	if (!options.job_id) {
		let lock_res = acquire_lock(job_id);
		if (!lock_res.ok) {
			return {
				id: profile_id,
				proto: proto,
				status: 'fail',
				tested_at: time(),
				reason: 'resources',
				hint: lock_res.message,
				warnings: warnings
			};
		}
		held_own_lock = true;
	}

	journal_init(job_id);

	let timeout_s = options.timeout_s || (c.test && c.test.timeout_s ? +c.test.timeout_s : DEFAULT_TIMEOUT_S);
	let test_cfg = c.test || {};
	let target_url = options.probe_url || (test_cfg.targets && length(test_cfg.targets) > 0 ? (type(test_cfg.targets) == 'array' ? test_cfg.targets[0] : test_cfg.targets) : DEFAULT_TARGETS[0]);

	let handshake_ok = false;
	let handshake_ms = null;
	let url_metrics = null;
	let failure_reason = null;
	let failure_hint = null;

	let pre_state_bytes = null;
	let sfile = get_run_dir() + '/state.json';
	if (fs.stat(sfile)) {
		let sf = fs.open(sfile, 'r');
		if (sf) { pre_state_bytes = sf.read('all'); sf.close(); }
	}

	let rt_table = (c.test && c.test.rt_table) ? +c.test.rt_table : DEFAULT_RT_TABLE;
	let rule_prio = (c.main && c.main.rule_priority) ? (+c.main.rule_priority + 1) : DEFAULT_RULE_PRIO;

	try {
		// Invariant T2 & T3: Set up fail-closed routing and nftables rules
		setup_test_routing(job_id, rt_table, rule_prio);
		setup_test_nft(job_id);

		let ctx = drv_common.create_context('test', profile_id, {
			proto: proto,
			dev: TEST_DEV,
			table: rt_table,
			rundir: get_job_dir(job_id),
			jid: job_id
		});

		let endpoints = drv_common.endpoints(proto, profile);
		for (let ep in endpoints) {
			if (ep.ips) {
				for (let ip in ep.ips) add_test_endpoint(job_id, ip);
			} else if (ep.host && util.is_ip(ep.host)) {
				add_test_endpoint(job_id, ep.host);
			}
		}

		let t_start = now_ms();

		if (proto == 'wireguard') {
			// WireGuard test tunnel procedure (§7.3.2)
			journal_record(job_id, { type: 'link', dev: TEST_DEV });
			let sres = drv_common.start(ctx, profile, null);
			if (!sres || !sres.ok) {
				failure_reason = 'driver_error';
				failure_hint = (sres && sres.err) ? sres.err : 'WireGuard start failed';
			} else {
				// Poll handshake via wg show gvt0 dump every 100 ms up to deadline
				let deadline = t_start + (timeout_s * 1000);
				while (now_ms() < deadline) {
					let f = drv_common.facts(ctx);
					if (f && f.last_handshake && f.last_handshake > 0) {
						handshake_ok = true;
						handshake_ms = now_ms() - t_start;
						break;
					}
					util.safe_exec(['sleep', '1']);
				}

				if (handshake_ok) {
					// Handshake confirmed: raise default route in table 4300
					journal_record(job_id, { type: 'route_default', dev: TEST_DEV, table: rt_table });
					route.test_route_up(TEST_DEV, false, rt_table);

					// Run URL probe samples
					let p_res = execute_probe(job_id, target_url, 5, profile.wg_dns, 3);
					if (p_res.ok) {
						url_metrics = {
							samples: p_res.samples,
							ok: p_res.ok_samples,
							median_ms: p_res.median_ms,
							median: p_res.median_ms,
							min_ms: p_res.min_ms,
							jitter_ms: p_res.jitter_ms,
							loss_pct: p_res.loss_pct
						};
					} else {
						failure_reason = p_res.error || 'http_failed';
						failure_hint = p_res.message || 'HTTP probe failed through test tunnel';
					}
				} else {
					failure_reason = 'no_handshake';
					failure_hint = 'UDP blocked, wrong endpoint, or key invalidated (Windscribe: regenerate)';
				}
			}
		} else if (proto == 'openvpn') {
			// OpenVPN test tunnel procedure (§7.3.1)
			journal_record(job_id, { type: 'link', dev: TEST_DEV });
			let prep = drv_common.prepare(ctx, profile, null);
			if (!prep || !prep.ok) {
				failure_reason = 'render_error';
				failure_hint = (prep && prep.err) ? prep.err : 'Failed to prepare OpenVPN configuration';
			} else {
				let sres = drv_common.start(ctx, profile, null);
				if (sres && sres.pid_file) {
					journal_record(job_id, { type: 'proc', pid_file: sres.pid_file });
				}

				// Poll hook up state up to deadline
				let deadline = t_start + (timeout_s * 1000);
				while (now_ms() < deadline) {
					let f = drv_common.facts(ctx);
					if (f && f.up) {
						handshake_ok = true;
						handshake_ms = now_ms() - t_start;
						break;
					}
					util.safe_exec(['sleep', '1']);
				}

				if (handshake_ok) {
					journal_record(job_id, { type: 'route_default', dev: TEST_DEV, table: rt_table });
					route.test_route_up(TEST_DEV, false, rt_table);

					let p_res = execute_probe(job_id, target_url, 5, null, 3);
					if (p_res.ok) {
						url_metrics = {
							samples: p_res.samples,
							ok: p_res.ok_samples,
							median_ms: p_res.median_ms,
							median: p_res.median_ms,
							min_ms: p_res.min_ms,
							jitter_ms: p_res.jitter_ms,
							loss_pct: p_res.loss_pct
						};
					} else {
						failure_reason = p_res.error || 'http_failed';
						failure_hint = p_res.message || 'HTTP probe failed through test tunnel';
					}
				} else {
					failure_reason = 'timeout';
					failure_hint = 'OpenVPN connection timed out waiting for server handshake';
				}
			}
		} else if (proto == 'ikev2') {
			// IKEv2 test tunnel procedure (§7.3.3)
			journal_record(job_id, { type: 'link', dev: TEST_DEV });
			let prep = drv_common.prepare(ctx, profile, null);
			if (!prep || !prep.ok) {
				failure_reason = 'render_error';
				failure_hint = (prep && prep.err) ? prep.err : 'Failed to prepare IKEv2 configuration';
			} else {
				let sres = drv_common.start(ctx, profile, null);
				if (!sres || !sres.ok) {
					failure_reason = 'driver_error';
					failure_hint = (sres && sres.err) ? sres.err : 'IKEv2 start failed';
				} else {
					let deadline = t_start + (timeout_s * 1000);
					while (now_ms() < deadline) {
						let f = drv_common.facts(ctx);
						if (f && f.up) {
							handshake_ok = true;
							handshake_ms = now_ms() - t_start;
							break;
						}
						util.safe_exec(['sleep', '1']);
					}

					if (handshake_ok) {
						journal_record(job_id, { type: 'route_default', dev: TEST_DEV, table: rt_table });
						route.test_route_up(TEST_DEV, false, rt_table);

						let p_res = execute_probe(job_id, target_url, 5, profile.ike_dns, 3);
						if (p_res.ok) {
							url_metrics = {
								samples: p_res.samples,
								ok: p_res.ok_samples,
								median_ms: p_res.median_ms,
								median: p_res.median_ms,
								min_ms: p_res.min_ms,
								jitter_ms: p_res.jitter_ms,
								loss_pct: p_res.loss_pct
							};
						} else {
							failure_reason = p_res.error || 'http_failed';
							failure_hint = p_res.message || 'HTTP probe failed through test tunnel';
						}
					} else {
						failure_reason = 'timeout';
						failure_hint = 'IKEv2 connection timed out waiting for server handshake';
					}
				}
			}
		} else {
			failure_reason = 'unsupported_proto';
			failure_hint = sprintf('Protocol %s not supported for real test in current phase', proto);
		}

	} catch (err) {
		failure_reason = 'exception';
		failure_hint = sprintf('Unhandled test error: %s', err);
	}

	// Always cleanup test artifacts (T4)
	test_cleanup(job_id, false);
	if (held_own_lock) release_lock();

	// Invariant T1 / T8: Verify active state.json is byte-identical
	if (pre_state_bytes != null && fs.stat(sfile)) {
		let sf = fs.open(sfile, 'r');
		if (sf) {
			let post_bytes = sf.read('all');
			sf.close();
			if (post_bytes != pre_state_bytes) {
				push(warnings, 'Active state.json was altered during test execution!');
			}
		}
	}

	let score = score_result({
		handshake_ok: handshake_ok,
		handshake_ms: handshake_ms,
		url: url_metrics,
		reason: failure_reason,
		hint: failure_hint
	}, test_cfg);

	let res_record = {
		id: profile_id,
		name: profile.name || profile_id,
		proto: proto,
		status: score.status,
		tested_at: time(),
		probe_ms: null,
		handshake_ms: handshake_ms,
		url: url_metrics,
		speed_mbps: null,
		reason: score.reason,
		hint: score.hint,
		warnings: warnings
	};

	// Save volatile result record to cache
	let cached = [];
	let rfile = get_results_file();
	if (fs.stat(rfile)) {
		let rf = fs.open(rfile, 'r');
		if (rf) {
			try { cached = json(rf.read('all') || '[]') || []; } catch(e) { cached = []; }
			rf.close();
		}
	}
	let updated = false;
	for (let i = 0; i < length(cached); i++) {
		if (cached[i].id == profile_id) {
			cached[i] = res_record;
			updated = true;
			break;
		}
	}
	if (!updated) push(cached, res_record);
	let wf = fs.open(rfile, 'w', 0o600);
	if (wf) { wf.write(sprintf('%J', cached)); wf.close(); }

	return res_record;
}

// ----------------------------------------------------------------------------
// 10. Multi-Profile Test Job Runner & Job Management (§7.8, §7.11)
// ----------------------------------------------------------------------------

function test_job_start(profiles_or_all, opts) {
	let c = cfg.load_config();
	let ids_to_test = [];

	if (!profiles_or_all || profiles_or_all == 'all') {
		let profs = c.profiles || {};
		for (let pid in keys(profs)) {
			if (profs[pid].enabled != '0') push(ids_to_test, pid);
		}
	} else if (type(profiles_or_all) == 'array') {
		ids_to_test = profiles_or_all;
	} else if (type(profiles_or_all) == 'string') {
		ids_to_test = [profiles_or_all];
	}

	if (length(ids_to_test) == 0) {
		return { ok: false, error: 'NO_PROFILES', message: 'No enabled profiles to test' };
	}

	let job_id = 't' + substr(sprintf('%08x', time()), 0, 8) + substr(sprintf('%04x', rand() % 65536), 0, 4);
	let lock_res = acquire_lock(job_id);
	if (!lock_res.ok) {
		return { ok: false, error: 'BUSY', message: lock_res.message };
	}

	let jdir = get_job_dir(job_id);
	if (!fs.stat(jdir)) {
		let tdir = get_test_dir();
		if (!fs.stat(tdir)) fs.mkdir(tdir, 0o700);
		fs.mkdir(jdir, 0o700);
	}

	let timeout_s = (opts && opts.timeout_s) ? +opts.timeout_s : ((c.test && c.test.timeout_s) ? +c.test.timeout_s : DEFAULT_TIMEOUT_S);
	// T5 / §7.8 Job deadline: n_profiles * (timeout_s + 5) + 30 s, hard max 15 min (900 s)
	let deadline_secs = length(ids_to_test) * (timeout_s + 5) + 30;
	if (deadline_secs > 900) deadline_secs = 900;
	let deadline_ms = now_ms() + deadline_secs * 1000;

	let results = [];
	let cancelled = false;

	for (let i = 0; i < length(ids_to_test); i++) {
		let pid = ids_to_test[i];

		// Check if job was cancelled
		let cur_status = test_job_status(job_id);
		if (cur_status && cur_status.state == 'cancelled') {
			cancelled = true;
			break;
		}

		// Check job deadline
		if (now_ms() > deadline_ms) {
			push(results, {
				id: pid,
				status: 'fail',
				reason: 'timeout',
				hint: 'Overall test job deadline exceeded',
				tested_at: time()
			});
			continue;
		}

		let jstate = {
			job_id: job_id,
			state: 'running',
			index: i,
			total: length(ids_to_test),
			current: { id: pid },
			results: results,
			deadline: int(deadline_ms / 1000)
		};
		let jf = fs.open(get_job_file(job_id), 'w', 0o600);
		if (jf) { jf.write(sprintf('%J', jstate)); jf.close(); }

		let sub_opts = {};
		if (opts) {
			for (let k in keys(opts)) sub_opts[k] = opts[k];
		}
		sub_opts.job_id = job_id;
		sub_opts.timeout_s = timeout_s;

		let r = test_profile(pid, sub_opts);
		push(results, r);
	}

	release_lock();

	if (cancelled) {
		return { ok: false, error: 'CANCELLED', message: 'Test job was cancelled', job_id: job_id, results: results };
	}

	let ranked = rank_results(results, c.test);
	let final_state = {
		job_id: job_id,
		state: 'done',
		index: length(ids_to_test),
		total: length(ids_to_test),
		current: null,
		results: ranked,
		deadline: int(deadline_ms / 1000)
	};
	let jf = fs.open(get_job_file(job_id), 'w', 0o600);
	if (jf) { jf.write(sprintf('%J', final_state)); jf.close(); }

	return {
		ok: true,
		job_id: job_id,
		total: length(ids_to_test),
		results: ranked
	};
}

function test_job_status(job_id) {
	let jfile = get_job_file(job_id);
	if (!fs.stat(jfile)) {
		return { error: 'NOT_FOUND', message: 'Job not found' };
	}
	let f = fs.open(jfile, 'r');
	if (!f) return { error: 'NOT_FOUND', message: 'Job unreadable' };
	let content = f.read('all') || '{}';
	f.close();
	try {
		return json(content);
	} catch (e) {
		return { error: 'PARSE_ERROR', message: 'Corrupted job status file' };
	}
}

function test_cancel(job_id) {
	let jfile = job_id ? get_job_file(job_id) : null;
	if (jfile && fs.stat(jfile)) {
		let jf = fs.open(jfile, 'r+');
		if (jf) {
			let jdata = {};
			try { jdata = json(jf.read('all') || '{}') || {}; } catch (e) {}
			jdata.state = 'cancelled';
			jf.seek(0);
			jf.write(sprintf('%J', jdata));
			jf.close();
		}
	}
	let lfile = get_lock_file();
	if (fs.stat(lfile)) {
		let my_pid = null;
		if (fs.stat('/proc/self')) {
			let plink = fs.readlink('/proc/self');
			if (plink && match(plink, /^[0-9]+$/)) my_pid = +plink;
		}
		let lf = fs.open(lfile, 'r');
		if (lf) {
			let lcont = trim(lf.read('all') || '');
			lf.close();
			let parts = split(lcont, ':');
			let pid = (length(parts) >= 2) ? +parts[1] : +lcont;
			if (pid && pid > 0 && pid != my_pid) {
				util.safe_exec(['kill', '-15', sprintf('%d', pid)]);
			}
		}
	}
	return test_cleanup(job_id, false);
}

function get_cached_results(ids) {
	let rfile = get_results_file();
	let list = [];
	if (fs.stat(rfile)) {
		let f = fs.open(rfile, 'r');
		if (f) {
			try { list = json(f.read('all') || '[]') || []; } catch(e) { list = []; }
			f.close();
		}
	}
	if (!ids || length(ids) == 0) return list;
	let filtered = [];
	for (let r in list) {
		for (let id in ids) {
			if (r.id == id) { push(filtered, r); break; }
		}
	}
	return filtered;
}

export {
	validate_probe_url,
	check_target_conflict,
	setup_test_routing,
	setup_test_nft,
	add_test_endpoint,
	add_test_target,
	test_cleanup,
	score_result,
	rank_results,
	execute_probe,
	run_live_check,
	test_profile,
	test_job_start,
	test_job_status,
	test_cancel,
	get_cached_results,
	acquire_lock,
	release_lock,
	journal_init,
	journal_record,
	journal_get,
	check_resource_preflight,
	get_job_file,
	get_job_dir
};
