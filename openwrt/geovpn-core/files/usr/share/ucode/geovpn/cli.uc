//
// GeoVPN Command-Line Dispatcher & Lifecycle Engine in ucode
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';
import * as cfg from './config.uc';
import * as state from './state.uc';
import * as parse from './ovpn_parse.uc';
import * as wg_parse from './wg_parse.uc';
import * as render from './ovpn_render.uc';
import * as nftgen from './nftgen.uc';
import * as route from './route.uc';
import * as dnsgen from './dnsgen.uc';
import * as fwzone from './fwzone.uc';
import * as diag from './diag.uc';
import * as data from './data.uc';
import * as drv_common from './drivers/common.uc';
import * as importer from './import.uc';
import * as te from './test_engine.uc';
import * as health from './health.uc';

function cmd_version() {
	print('GeoVPN 1.0.0 (OpenWrt 25.12)\n');
	return 0;
}

function cmd_status(json_output) {
	let s = state.get_state();
	let cursor = uci.cursor();
	cursor.load('geovpn');
	let enabled = cursor.get('geovpn', 'main', 'enabled') == '1';
	let config = cfg.load_config();
	let override = cfg.get_active_override();
	let active_id = cfg.get_effective_active_profile_id(config) || '';

	s.service.enabled = enabled;
	s.tunnel.profile = active_id;
	s.tunnel.override = override || null;

	if (active_id && length(active_id) > 0) {
		let p = cfg.get_profile(active_id);
		if (p) {
			s.tunnel.name = p.name || active_id;
			s.tunnel.proto = p.proto || 'openvpn';
		}
	}

	if (json_output) {
		print(sprintf('%J\n', s));
		return 0;
	}

	print(sprintf('GeoVPN Service: %s (state: %s)\n', enabled ? 'enabled' : 'disabled', s.service.state));
	if (override) {
		print(sprintf('Active Profile: %s (%s) [OVERRIDE: %s]\n', s.tunnel.name || 'none', s.tunnel.profile || 'none', override));
	} else {
		print(sprintf('Active Profile: %s (%s)\n', s.tunnel.name || 'none', s.tunnel.profile || 'none'));
	}
	print(sprintf('Tunnel Device:  %s (local: %s, remote: %s, v6: %s)\n',
		s.tunnel.device, s.tunnel.local_ip || '-', s.tunnel.remote_ip || '-', s.tunnel.ipv6 ? 'yes' : 'no'));
	print(sprintf('Split Tunnel:   mode: %s, kill switch: %s\n', s.split.mode, s.split.kill_switch ? 'ON' : 'OFF'));
	print(sprintf('DNS nftset:     %s (confdir: %s)\n', s.dns.nftset ? 'active' : 'inactive', s.dns.confdir || 'none'));
	return 0;
}

function cmd_import(args) {
	if (!args || length(args) < 1 || args[0] == '-h' || args[0] == '--help') {
		print('Usage: geovpn import [--proto ovpn|wg] [--cred <cred_id>] [--dedupe skip|replace|keep_both] [--atomic] <path_or_dir|-> [name]\n');
		return (args && length(args) > 0 && (args[0] == '-h' || args[0] == '--help')) ? 0 : 1;
	}

	let proto = null;
	let cred_id = null;
	let path_or_dir = null;
	let name = null;
	let atomic = false;
	let dedupe = 'skip';

	let i = 0;
	while (i < length(args)) {
		let a = args[i];
		if (a == '-h' || a == '--help') {
			print('Usage: geovpn import [--proto ovpn|wg] [--cred <cred_id>] [--dedupe skip|replace|keep_both] [--atomic] <path_or_dir|-> [name]\n');
			return 0;
		} else if (a == '--proto' && i + 1 < length(args)) {
			let p = lc(args[i + 1]);
			if (p == 'wg' || p == 'wireguard') proto = 'wireguard';
			else if (p == 'ovpn' || p == 'openvpn') proto = 'openvpn';
			else proto = p;
			i += 2;
		} else if (substr(a, 0, 8) == '--proto=') {
			let p = lc(substr(a, 8));
			if (p == 'wg' || p == 'wireguard') proto = 'wireguard';
			else if (p == 'ovpn' || p == 'openvpn') proto = 'openvpn';
			else proto = p;
			i++;
		} else if (a == '--cred' && i + 1 < length(args)) {
			cred_id = args[i + 1];
			i += 2;
		} else if (substr(a, 0, 7) == '--cred=') {
			cred_id = substr(a, 7);
			i++;
		} else if (a == '--atomic') {
			atomic = true;
			i++;
		} else if (a == '--dedupe' && i + 1 < length(args)) {
			dedupe = args[i + 1];
			i += 2;
		} else if (substr(a, 0, 9) == '--dedupe=') {
			dedupe = substr(a, 9);
			i++;
		} else if (a == '-') {
			if (!path_or_dir) path_or_dir = '-';
			else if (!name) name = '-';
			i++;
		} else if (substr(a, 0, 1) != '-') {
			if (!path_or_dir) {
				path_or_dir = a;
			} else if (!name) {
				name = a;
			}
			i++;
		} else {
			i++;
		}
	}

	if (!path_or_dir) {
		fs.stderr.write('Error: input file or directory required\n');
		return 1;
	}

	if (path_or_dir == '-') {
		let content = fs.stdin.read('all') || '';
		if (length(content) == 0) {
			fs.stderr.write('Error: empty input from stdin\n');
			return 1;
		}
		let res = importer.import_profile({
			filename: 'stdin',
			content: content,
			proto: proto,
			cred: cred_id,
			name: name || 'Imported Profile',
			dedupe: dedupe
		});
		if (!res.ok) {
			fs.stderr.write(sprintf('Import failed: %s\n', res.error));
			return 1;
		}
		if (res.skipped) {
			print(sprintf('Profile skipped: %s\n', res.reason));
			return 0;
		}
		print(sprintf('Profile imported successfully as %s (ID: %s, Protocol: %s)\n', res.name, res.id, res.proto));
		if (res.cred) print(sprintf('  Linked to credential set: %s\n', res.cred));
		if (res.notices && length(res.notices) > 0) {
			for (let n in res.notices) print(sprintf('  Notice: %s\n', n));
		}
		return 0;
	}

	let st = fs.stat(path_or_dir);
	if (!st) {
		fs.stderr.write(sprintf('Error: cannot find %s\n', path_or_dir));
		return 1;
	}

	if (st.type == 'directory') {
		let res = importer.import_batch(path_or_dir, {
			proto: proto,
			cred: cred_id,
			atomic: atomic,
			dedupe: dedupe
		});

		if (!res.ok) {
			fs.stderr.write(sprintf('Batch import failed: %s\n', res.error));
			return 1;
		}

		print(sprintf('Batch import complete from %s (%d files processed):\n', path_or_dir, res.total));
		print(sprintf('  Imported: %d profiles\n', length(res.imported)));
		if (length(res.skipped) > 0) {
			print(sprintf('  Skipped:  %d profiles (duplicates)\n', length(res.skipped)));
		}
		if (length(res.errors) > 0) {
			print(sprintf('  Errors:   %d files\n', length(res.errors)));
			for (let e in res.errors) {
				print(sprintf('    - %s: %s\n', e.item, e.error));
			}
		}
		for (let imp in res.imported) {
			print(sprintf('  + %s (ID: %s, Protocol: %s)\n', imp.name, imp.id, imp.proto));
			if (imp.notices && length(imp.notices) > 0) {
				for (let n in imp.notices) print(sprintf('      Notice: %s\n', n));
			}
		}
		return 0;
	} else {
		let f = fs.open(path_or_dir, 'r');
		if (!f) {
			fs.stderr.write(sprintf('Error: cannot open %s\n', path_or_dir));
			return 1;
		}
		let content = f.read('all') || '';
		f.close();

		let res = importer.import_profile({
			filename: path_or_dir,
			content: content,
			proto: proto,
			cred: cred_id,
			name: name,
			dedupe: dedupe
		});

		if (!res.ok) {
			fs.stderr.write(sprintf('Import failed: %s\n', res.error));
			return 1;
		}

		if (res.skipped) {
			print(sprintf('Profile skipped: %s\n', res.reason));
			return 0;
		}

		print(sprintf('Profile imported successfully as %s (ID: %s, Protocol: %s)\n', res.name, res.id, res.proto));
		if (res.cred) {
			print(sprintf('  Linked to credential set: %s\n', res.cred));
		}
		if (res.notices && length(res.notices) > 0) {
			for (let n in res.notices) print(sprintf('  Notice: %s\n', n));
		}
		if (res.warnings && length(res.warnings) > 0) {
			let shown_w = [];
			for (let w in res.warnings) {
				let already_notice = false;
				if (res.notices) {
					for (let n in res.notices) {
						if (n == w) { already_notice = true; break; }
					}
				}
				if (!already_notice) push(shown_w, w);
			}
			if (length(shown_w) > 0) {
				print('Warnings:\n');
				for (let w in shown_w) print(sprintf('  - %s\n', w));
			}
		}
		if (res.ignored && length(res.ignored) > 0) {
			print(sprintf('Ignored %d disallowed/unsupported directives.\n', length(res.ignored)));
		}
		return 0;
	}
}

function load_geo_cidrs(config) {
	let v4 = [];
	let v6 = [];
	let data_dir = '/etc/geovpn/data';
	if (config && config.geoip) {
		for (let g in config.geoip) {
			if (g.enabled != '0' && g.code) {
				let code = lc(g.code);
				let v4_candidates = [
					sprintf('%s/ip/%s.v4.txt', data_dir, code),
					sprintf('%s/ip/%s.cidr', data_dir, code),
					sprintf('%s/ip/%s.txt', data_dir, code)
				];
				for (let cand in v4_candidates) {
					let f = fs.open(cand, 'r');
					if (f) {
						let lines = split(f.read('all'), '\n');
						f.close();
						for (let l in lines) {
							let line = trim(l);
							if (length(line) > 0 && substr(line, 0, 1) != '#') {
								if (util.is_cidr4(line) || util.is_ipv4(line)) push(v4, line);
								else if (util.is_cidr6(line) || util.is_ipv6(line)) push(v6, line);
							}
						}
						break;
					}
				}

				let f6 = fs.open(sprintf('%s/ip/%s.v6.txt', data_dir, code), 'r');
				if (f6) {
					let lines = split(f6.read('all'), '\n');
					f6.close();
					for (let l in lines) {
						let line = trim(l);
						if (length(line) > 0 && substr(line, 0, 1) != '#' && (util.is_cidr6(line) || util.is_ipv6(line))) {
							push(v6, line);
						}
					}
				}
			}
		}
	}
	return { v4: v4, v6: v6 };
}

function load_geosite_domains(config) {
	let domains = [];
	let data_dir = '/etc/geovpn/data';
	if (config && config.geosite) {
		for (let s in config.geosite) {
			if (s.enabled != '0' && s.name) {
				let name = lc(s.name);
				let cand_files = [
					sprintf('%s/site/%s.txt', data_dir, name),
					sprintf('%s/site/%s.domains', data_dir, name)
				];
				for (let cand in cand_files) {
					let f = fs.open(cand, 'r');
					if (f) {
						let lines = split(f.read('all'), '\n');
						f.close();
						for (let l in lines) {
							let line = trim(l);
							if (length(line) > 0 && substr(line, 0, 1) != '#' && util.is_domain(line)) {
								push(domains, line);
							}
						}
						break;
					}
				}
			}
		}
	}
	return domains;
}

function cmd_prepare() {
	state.ensure_run_dir();
	state.update_state({ service: { state: 'applying' } });

	let config = cfg.load_config();
	let active_id = cfg.get_effective_active_profile_id(config);
	if (!active_id || length(active_id) == 0) {
		util.log('warn', 'No active profile selected');
		state.update_state({ service: { state: 'disabled' } });
		return 0;
	}

	let profile = cfg.get_profile(active_id);
	if (!profile) {
		util.log('error', sprintf('Active profile %s not found', active_id));
		state.update_state({ service: { state: 'error' } });
		return 1;
	}

	let proto = profile.proto || 'openvpn';
	let drv = drv_common.get_driver(proto);
	if (!drv) {
		util.log('error', sprintf('Unsupported protocol %s for profile %s', proto, active_id));
		state.update_state({ service: { state: 'error' } });
		return 1;
	}

	let ctx = drv_common.create_context('active', active_id, {
		proto: proto,
		dev: config.main.tun_dev || 'geovpn0',
		table: 4200
	});

	let prep = drv_common.prepare(ctx, profile, config);
	if (!prep || !prep.ok) {
		util.log('error', sprintf('Failed to prepare %s configuration: %s', proto, (prep && prep.err) ? prep.err : 'unknown'));
		state.update_state({ service: { state: 'error' } });
		return 1;
	}

	// Render ruleset, sets, dnsmasq configs via their modules
	let geo_cidrs = load_geo_cidrs(config);
	let geosite_domains = load_geosite_domains(config);

	fwzone.ensure_firewall_zone(config.main);
	nftgen.apply_ruleset(config, geo_cidrs, profile);
	route.apply_routes(config.main);
	dnsgen.apply_dnsmasq(config, geosite_domains, profile);
	health.update_cron_schedule(config.main, config.autoconnect, proto);

	if (proto == 'wireguard') {
		let sres = drv_common.start(ctx, profile, null);
		if (!sres || !sres.ok) {
			util.log('error', sprintf('Failed to start WireGuard interface %s: %s', ctx.dev, (sres && sres.err) ? sres.err : 'unknown'));
			state.update_state({ service: { state: 'error' } });
			return 1;
		}
		let has_v6 = false;
		let addrs = profile.wg_address;
		if (type(addrs) == 'string') addrs = [addrs];
		if (addrs) {
			for (let a in addrs) {
				if (index(a, ':') != -1) has_v6 = true;
			}
		}
		route.set_tunnel_up(ctx.dev, has_v6, 4200);
		state.update_state({
			service: { state: 'connected' },
			tunnel: {
				profile: active_id,
				name: profile.name || active_id,
				device: ctx.dev,
				since: time(),
				remote_ip: profile.wg_endpoint_host || '',
				ipv6: has_v6
			}
		});
		return 0;
	}

	state.update_state({ service: { state: 'connecting' } });
	return 0;
}

function cmd_teardown() {
	let config = cfg.load_config();
	let active_id = config ? cfg.get_effective_active_profile_id(config) : null;
	if (active_id) {
		let p = cfg.get_profile(active_id);
		let proto = (p && p.proto) ? p.proto : 'openvpn';
		let ctx = drv_common.create_context('active', active_id, {
			proto: proto,
			dev: (config.main && config.main.tun_dev) ? config.main.tun_dev : 'geovpn0',
			table: 4200
		});
		drv_common.stop(ctx);
	}
	route.teardown_routes(config ? config.main : null);
	nftgen.teardown_ruleset();
	dnsgen.teardown_dnsmasq();

	state.update_state({
		service: { state: 'disabled' },
		tunnel: { since: 0, uptime: 0, local_ip: '', remote_ip: '' }
	});
	return 0;
}

function cmd_panic() {
	util.log('warn', 'EMERGENCY PANIC triggered: tearing down all GeoVPN rules and disabling service');
	cfg.clear_active_override();
	cmd_teardown();
	te.test_cleanup(null, false);

	let cursor = uci.cursor();
	cursor.load('geovpn');
	cursor.set('geovpn', 'main', 'enabled', '0');
	cursor.commit('geovpn');

	util.safe_exec(['/etc/init.d/geovpn', 'stop']);
	print('Emergency stop complete: GeoVPN disabled, all routing rules removed.\n');
	return 0;
}

function tunnel_up(ctx, facts) {
	let dev = (facts && facts.dev) ? facts.dev : ctx.dev;
	let has_v6 = facts ? facts.has_v6 : false;

	if (ctx.kind == 'test') {
		util.safe_exec(['ip', '-4', 'route', 'replace', 'default', 'dev', dev, 'table', sprintf('%d', ctx.table), 'metric', '10']);
		if (has_v6) {
			util.safe_exec(['ip', '-6', 'route', 'replace', 'default', 'dev', dev, 'table', sprintf('%d', ctx.table), 'metric', '10']);
		}
		return 0;
	}

	// Active tunnel setup
	let rp_path = sprintf('/proc/sys/net/ipv4/conf/%s/rp_filter', dev);
	if (fs.stat(rp_path)) {
		let rp_f = fs.open(rp_path, 'w');
		if (rp_f) {
			rp_f.write('2\n');
			rp_f.close();
		}
	}

	route.set_tunnel_up(dev, has_v6, ctx.table);

	let local_ip = (facts && facts.v4 && length(facts.v4) > 0) ? facts.v4[0] : '';
	let remote_ip = (facts && facts.endpoint_ip) ? facts.endpoint_ip : '';
	let since_ts = (facts && facts.since) ? facts.since : time();

	state.update_state({
		service: { state: 'connected' },
		tunnel: {
			device: dev,
			since: since_ts,
			local_ip: local_ip,
			remote_ip: remote_ip,
			ipv6: has_v6,
			proto: (facts && facts.proto) ? facts.proto : (ctx.proto || 'openvpn')
		}
	});

	util.log('info', sprintf('Active tunnel up on %s (%s -> %s)', dev, local_ip || '-', remote_ip || '-'));
	return 0;
}

function tunnel_down(ctx) {
	if (ctx.kind == 'test') {
		util.safe_exec(['ip', '-4', 'route', 'del', 'default', 'dev', ctx.dev, 'table', sprintf('%d', ctx.table), 'metric', '10']);
		util.safe_exec(['ip', '-6', 'route', 'del', 'default', 'dev', ctx.dev, 'table', sprintf('%d', ctx.table), 'metric', '10']);
		return 0;
	}

	route.set_tunnel_down(ctx.table);

	state.update_state({
		service: { state: 'connecting' },
		tunnel: { since: 0, uptime: 0 }
	});
	util.log('info', 'Active tunnel down');
	return 0;
}

function cmd_hook(arg1, arg2) {
	let env_file = '/var/run/geovpn/hook.env';
	let gv_ctx = '';
	if (arg1 == '--ctx') {
		gv_ctx = arg2 || '';
	} else if (arg1 && fs.stat(arg1)) {
		env_file = arg1;
	}

	let env_vars = {};
	let f = fs.open(env_file, 'r');
	if (f) {
		let content = f.read('all') || '';
		f.close();
		let lines = split(content, '\n');
		for (let line in lines) {
			let parts = split(line, '=');
			if (length(parts) >= 2) {
				env_vars[parts[0]] = join('=', slice(parts, 1));
			}
		}
	}

	if (!gv_ctx && env_vars['GV_CTX']) {
		gv_ctx = env_vars['GV_CTX'];
	}

	let ctx_kind = 'active';
	let profile_id = '';
	let job_id = '';
	if (gv_ctx && length(gv_ctx) > 0) {
		let parts = split(gv_ctx, ':');
		if (length(parts) >= 1) ctx_kind = parts[0];
		if (length(parts) == 2) {
			profile_id = parts[1];
		} else if (length(parts) >= 3) {
			job_id = parts[1];
			profile_id = parts[2];
		}
	}

	if (!profile_id) {
		let cursor = uci.cursor();
		cursor.load('geovpn');
		profile_id = cursor.get('geovpn', 'main', 'active_profile') || '';
	}

	let proto = env_vars['proto'];
	if (!proto && profile_id) {
		let cursor = uci.cursor();
		cursor.load('geovpn');
		proto = cursor.get('geovpn', profile_id, 'proto');
	}
	if (!proto) proto = 'openvpn';

	let ctx = drv_common.create_context(ctx_kind, profile_id, {
		proto: proto,
		dev: env_vars['dev'] || (ctx_kind == 'test' ? 'gvt0' : 'geovpn0'),
		table: (ctx_kind == 'test') ? 4300 : 4200,
		rundir: (ctx_kind == 'test') ? ('/var/run/geovpn/test/' + (job_id || profile_id)) : '/var/run/geovpn',
		jid: job_id
	});

	let stype = env_vars['script_type'] || 'up';
	if (stype == 'up') {
		let facts = drv_common.facts(ctx);
		return tunnel_up(ctx, facts);
	} else if (stype == 'down') {
		return tunnel_down(ctx);
	}
	return 0;
}

function cmd_test(args) {
	if (!args || length(args) < 1 || args[0] == '-h' || args[0] == '--help') {
		print('Usage: geovpn test <profile_id|all> [--probe-url <url>] [--json]\n');
		print('       geovpn test <target_ip_or_domain> [client_ip] (legacy routing check)\n');
		return (args && length(args) > 0 && (args[0] == '-h' || args[0] == '--help')) ? 0 : 1;
	}

	let target_id = args[0];
	let probe_url = null;
	let json_out = false;
	let job_id = null;

	let i = 1;
	while (i < length(args)) {
		let a = args[i];
		if (a == '--probe-url' && i + 1 < length(args)) {
			probe_url = args[i + 1];
			i += 2;
		} else if (substr(a, 0, 12) == '--probe-url=') {
			probe_url = substr(a, 12);
			i++;
		} else if (a == '--job-id' && i + 1 < length(args)) {
			job_id = args[i + 1];
			i += 2;
		} else if (substr(a, 0, 11) == '--job-id=') {
			job_id = substr(a, 11);
			i++;
		} else if (a == '--json') {
			json_out = true;
			i++;
		} else {
			i++;
		}
	}

	let is_profile = util.is_profile_id(target_id) || (target_id == 'all') || (cfg.get_profile(target_id) != null) || (index(target_id, ',') != -1);
	if (!is_profile && !probe_url && !json_out) {
		let res = diag.test_target(args[0], args[1]);
		print(sprintf('%J\n', res));
		return 0;
	}

	let target_spec = target_id;
	if (index(target_id, ',') != -1) {
		target_spec = split(target_id, ',');
	}

	let res = (target_id == 'all' || type(target_spec) == 'array') ?
		te.test_job_start(target_spec, { probe_url: probe_url, job_id: job_id }) :
		te.test_profile(target_id, { probe_url: probe_url, job_id: job_id });

	if (json_out) {
		print(sprintf('%J\n', res));
		let failed = (res.status == 'fail' || res.status == 'error' || res.ok == false);
		if (res.results && length(res.results) > 0) {
			for (let r in res.results) {
				if (r.status == 'fail' || r.status == 'error') { failed = true; break; }
			}
		}
		return failed ? 1 : 0;
	}

	if (target_id == 'all') {
		print(sprintf('Batch Test Completed: %d profiles tested\n', res.total || 0));
		for (let r in (res.results || [])) {
			let mark = (r.status == 'pass') ? '✔' : ((r.status == 'warn') ? '⚠' : '✘');
			print(sprintf('  %s %-16s [%-9s] %s', mark, r.name || r.id, uc(r.status), r.proto));
			if (r.handshake_ms != null) print(sprintf(' (handshake: %d ms)', r.handshake_ms));
			if (r.url && r.url.median_ms != null) print(sprintf(' (latency: %d ms, loss: %d%%)', r.url.median_ms, r.url.loss_pct));
			if (r.hint) print(sprintf(' — %s', r.hint));
			print('\n');
		}
		return 0;
	}

	let mark = (res.status == 'pass') ? '✔' : ((res.status == 'warn') ? '⚠' : '✘');
	print(sprintf('%s Profile Test: %s (%s, %s)\n', mark, res.name || res.id, res.id, res.proto));
	print(sprintf('  Status:    %s\n', uc(res.status)));
	if (res.handshake_ms != null) {
		print(sprintf('  Handshake: %d ms\n', res.handshake_ms));
	}
	if (res.url) {
		print(sprintf('  Latency:   median %s ms, min %s ms, jitter %s ms (loss: %d%%, %d/%d ok)\n',
			res.url.median_ms != null ? sprintf('%d', res.url.median_ms) : '-',
			res.url.min_ms != null ? sprintf('%d', res.url.min_ms) : '-',
			res.url.jitter_ms != null ? sprintf('%d', res.url.jitter_ms) : '-',
			res.url.loss_pct, res.url.ok, res.url.samples));
	}
	if (res.reason) print(sprintf('  Reason:    %s\n', res.reason));
	if (res.hint) print(sprintf('  Hint:      %s\n', res.hint));
	if (res.warnings && length(res.warnings) > 0) {
		for (let w in res.warnings) print(sprintf('  Warning:   %s\n', w));
	}

	return (res.status == 'fail' || res.status == 'error') ? 1 : 0;
}

function cmd_test_cleanup(args) {
	let verify = false;
	if (args && length(args) > 0) {
		for (let a in args) if (a == '--verify' || a == '-v') verify = true;
	}

	let res = te.test_cleanup(null, verify);
	if (verify) {
		if (res.ok) {
			print('Verification PASSED: zero residual test artifacts detected.\n');
			return 0;
		} else {
			print(sprintf('Verification FAILED: leftovers detected: %s\n', join(', ', res.leftovers)));
			return 1;
		}
	}

	print('Test cleanup complete: all test routes, rules, and devices cleared.\n');
	return 0;
}

function cmd_health_tick(args) {
	let force = false;
	let json_out = false;
	if (args) {
		for (let a in args) {
			if (a == '--force' || a == '-f') force = true;
			if (a == '--json') json_out = true;
		}
	}
	let res = health.run_health_tick({ force: force });
	if (json_out) {
		print(sprintf('%J\n', res));
		return 0;
	}
	if (!res || !res.ok) {
		fs.stderr.write(sprintf('Health tick: %s\n', (res && res.message) ? res.message : 'failed or skipped'));
		return (res && res.skipped) ? 0 : 1;
	}
	if (res.skipped) {
		print(sprintf('Health tick: skipped (%s)\n', res.reason || res.message));
		return 0;
	}
	if (res.switched) {
		print(sprintf('Health tick: FAILOVER TRIGGERED -> switched to profile %s\n', res.target));
		return 0;
	}
	print(sprintf('Health tick: status=%s, fail_count=%d\n', (res.health ? res.health.status : 'unknown'), res.fail_count || 0));
	return 0;
}

function cmd_switch(args) {
	if (!args || length(args) < 1 || args[0] == '-h' || args[0] == '--help') {
		print('Usage: geovpn switch <profile_id> [--persist]\n');
		return (args && length(args) > 0 && (args[0] == '-h' || args[0] == '--help')) ? 0 : 1;
	}

	let profile_id = null;
	let persist = false;

	for (let i = 0; i < length(args); i++) {
		let a = args[i];
		if (a == '--persist') {
			persist = true;
		} else if (!profile_id) {
			profile_id = a;
		}
	}

	if (!profile_id || !util.is_profile_id(profile_id)) {
		fs.stderr.write(sprintf('Invalid profile ID: %s\n', profile_id || ''));
		return 1;
	}

	let res = health.manual_switch(profile_id, persist);
	if (!res || !res.ok) {
		fs.stderr.write(sprintf('Switch failed: %s\n', (res && res.message) ? res.message : ((res && res.error) ? res.error : 'unknown')));
		return 1;
	}

	print(sprintf('Switched active profile to %s (persisted: %s)\n', profile_id, persist ? 'yes' : 'no'));
	return 0;
}

function main(args) {
	if (length(args) < 1) {
		print('Usage: geovpn <command> [options]\n');
		print('Commands:\n');
		print('  status [--json]   Show service and tunnel status\n');
		print('  start             Start GeoVPN service\n');
		print('  stop              Stop GeoVPN service\n');
		print('  restart           Restart GeoVPN service\n');
		print('  reload            Reload configuration\n');
		print('  switch <id>       Switch active tunnel profile (--persist)\n');
		print('  health-tick       Run periodic health tick and failover check (--force, --json)\n');
		print('  import [opts] <path> Import profile(s) (--proto, --cred)\n');
		print('  test [opts] <id>  Pre-connection test for profile (--probe-url, --json)\n');
		print('  test-cleanup [-v] Clean test artifacts (--verify)\n');
		print('  update [--force]  Update geo data packs\n');
		print('  diag              Run system diagnostics\n');
		print('  panic             Emergency reset and shutdown\n');
		print('  purge             Complete reset (removes all rules, profiles, and configs)\n');
		print('  migrate           Migrate config v1 to v2 (--rollback, --prepare-downgrade)\n');
		print('  version           Display version\n');
		return 1;
	}

	let cmd = args[0];
	if (cmd == 'version') return cmd_version();
	if (cmd == 'status') return cmd_status(length(args) > 1 && args[1] == '--json');
	if (cmd == 'start') {
		util.safe_exec(['/etc/init.d/geovpn', 'start']);
		return 0;
	}
	if (cmd == 'stop') {
		util.safe_exec(['/etc/init.d/geovpn', 'stop']);
		return 0;
	}
	if (cmd == 'restart') {
		util.safe_exec(['/etc/init.d/geovpn', 'restart']);
		return 0;
	}
	if (cmd == 'reload') {
		util.safe_exec(['/etc/init.d/geovpn', 'reload']);
		return 0;
	}
	if (cmd == 'switch') return cmd_switch(slice(args, 1));
	if (cmd == 'health-tick' || cmd == 'health_tick') return cmd_health_tick(slice(args, 1));
	if (cmd == 'panic') return cmd_panic();
	if (cmd == 'purge') {
		cfg.clear_active_override();
		health.update_cron_schedule(null, null, null);
		cmd_teardown();
		util.safe_exec(['/etc/init.d/geovpn', 'stop']);
		let config = cfg.load_config();
		fwzone.remove_firewall_zone(config ? config.main : null);
		util.safe_exec(['rm', '-rf', '/etc/geovpn', '/var/run/geovpn']);
		let cursor = uci.cursor();
		cursor.delete('geovpn');
		cursor.commit('geovpn');
		print('GeoVPN purge complete: all rules, profiles, caches, and configs removed.\n');
		return 0;
	}
	if (cmd == 'import') return cmd_import(slice(args, 1));
	if (cmd == '_prepare') return cmd_prepare();
	if (cmd == '_teardown') return cmd_teardown();
	if (cmd == '_reload') { cmd_teardown(); return cmd_prepare(); }
	if (cmd == '_hook') return cmd_hook(args[1], args[2]);
	if (cmd == '_wan_event') {
		let lock_file = '/var/run/geovpn/wan_event.lock';
		if (fs.stat(lock_file)) return 0;
		let lk = fs.open(lock_file, 'w');
		if (lk) lk.close();
		sleep(2000);
		fs.unlink(lock_file);

		let cursor = uci.cursor();
		cursor.load('geovpn');
		let enabled = cursor.get('geovpn', 'main', 'enabled') == '1';
		if (!enabled) return 0;

		let config = cfg.load_config();
		let active_id = config.main.active_profile;
		let profile = active_id ? cfg.get_profile(active_id) : null;
		let geosite_domains = load_geosite_domains(config);
		dnsgen.apply_dnsmasq(config, geosite_domains, profile);
		return 0;
	}

	if (cmd == 'diag') {
		let res = diag.run_diag();
		print(sprintf('%J\n', res));
		return 0;
	}

	if (cmd == 'test') return cmd_test(slice(args, 1));
	if (cmd == 'test-cleanup' || cmd == 'test_cleanup') return cmd_test_cleanup(slice(args, 1));

	if (cmd == 'update') {
		return data.run_update(length(args) > 1 && args[1] == '--force');
	}

	if (cmd == 'migrate' || cmd == '--migrate') {
		let sub = (length(args) > 1) ? args[1] : '';
		if (sub == '--rollback' || sub == 'rollback') {
			let res = cfg.rollback_migration();
			if (!res || !res.ok) { fs.stderr.write(sprintf('Rollback failed: %s\n', (res && res.error) ? res.error : 'unknown')); return 1; }
			print(sprintf('Rolled back successfully from %s\n', res.restored_from));
			return 0;
		}
		if (sub == '--prepare-downgrade' || sub == 'prepare-downgrade') {
			let res = cfg.prepare_downgrade();
			if (!res || !res.ok) { fs.stderr.write(sprintf('Prepare downgrade failed: %s\n', (res && res.error) ? res.error : 'unknown')); return 1; }
			print('Prepared for downgrade: active profile verified, config_version reset to 1\n');
			return 0;
		}
		let res = cfg.migrate_v1_to_v2();
		if (!res || !res.ok) { fs.stderr.write(sprintf('Migration failed: %s\n', (res && res.error) ? res.error : 'unknown')); return 1; }
		print('Migration to v2 successful\n');
		return 0;
	}

	if (cmd == 'rollback' || cmd == '--rollback') {
		let res = cfg.rollback_migration();
		if (!res || !res.ok) { fs.stderr.write(sprintf('Rollback failed: %s\n', (res && res.error) ? res.error : 'unknown')); return 1; }
		print(sprintf('Rolled back successfully from %s\n', res.restored_from));
		return 0;
	}

	if (cmd == 'prepare-downgrade' || cmd == '--prepare-downgrade') {
		let res = cfg.prepare_downgrade();
		if (!res || !res.ok) { fs.stderr.write(sprintf('Prepare downgrade failed: %s\n', (res && res.error) ? res.error : 'unknown')); return 1; }
		print('Prepared for downgrade: active profile verified, config_version reset to 1\n');
		return 0;
	}

	fs.stderr.write(sprintf('Unknown command: %s\n', cmd));
	return 1;
}

export {
	main
};
