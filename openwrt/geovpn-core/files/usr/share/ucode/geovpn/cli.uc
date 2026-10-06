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
import * as render from './ovpn_render.uc';
import * as nftgen from './nftgen.uc';
import * as route from './route.uc';
import * as dnsgen from './dnsgen.uc';
import * as fwzone from './fwzone.uc';
import * as diag from './diag.uc';
import * as data from './data.uc';

function cmd_version() {
	print('GeoVPN 1.0.0 (OpenWrt 25.12)\n');
	return 0;
}

function cmd_status(json_output) {
	let s = state.get_state();
	let cursor = uci.cursor();
	cursor.load('geovpn');
	let enabled = cursor.get('geovpn', 'main', 'enabled') == '1';
	let active_id = cursor.get('geovpn', 'main', 'active_profile') || '';

	s.service.enabled = enabled;
	s.tunnel.profile = active_id;

	if (active_id && length(active_id) > 0) {
		let p = cfg.get_profile(active_id);
		if (p) s.tunnel.name = p.name || active_id;
	}

	if (json_output) {
		print(sprintf('%J\n', s));
		return 0;
	}

	print(sprintf('GeoVPN Service: %s (state: %s)\n', enabled ? 'enabled' : 'disabled', s.service.state));
	print(sprintf('Active Profile: %s (%s)\n', s.tunnel.name || 'none', s.tunnel.profile || 'none'));
	print(sprintf('Tunnel Device:  %s (local: %s, remote: %s, v6: %s)\n',
		s.tunnel.device, s.tunnel.local_ip || '-', s.tunnel.remote_ip || '-', s.tunnel.ipv6 ? 'yes' : 'no'));
	print(sprintf('Split Tunnel:   mode: %s, kill switch: %s\n', s.split.mode, s.split.kill_switch ? 'ON' : 'OFF'));
	print(sprintf('DNS nftset:     %s (confdir: %s)\n', s.dns.nftset ? 'active' : 'inactive', s.dns.confdir || 'none'));
	return 0;
}

function cmd_import(file_path, name) {
	if (!file_path) {
		fs.stderr.write('Error: input file required\n');
		return 1;
	}
	let f = fs.open(file_path, 'r');
	if (!f) {
		fs.stderr.write(sprintf('Error: cannot open %s\n', file_path));
		return 1;
	}
	let content = f.read('all');
	f.close();

	let res = parse.parse_ovpn(content, name);
	if (!res.ok) {
		fs.stderr.write(sprintf('Import failed: %s\n', res.error));
		return 1;
	}

	let id = cfg.create_profile(res.profile);
	print(sprintf('Profile imported successfully as %s (ID: %s)\n', res.profile.name, id));
	if (length(res.profile.warnings) > 0) {
		print('Warnings:\n');
		for (let w in res.profile.warnings) {
			print(sprintf('  - %s\n', w));
		}
	}
	if (length(res.profile.ignored) > 0) {
		print(sprintf('Ignored %d disallowed/unsupported directives.\n', length(res.profile.ignored)));
	}
	return 0;
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
	let active_id = config.main.active_profile;
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

	let pdir = cfg.PROFILES_DIR + '/' + active_id;
	let conf_text = render.render_ovpn(profile, pdir, config.main);
	if (!conf_text) {
		util.log('error', 'Failed to render OpenVPN configuration');
		state.update_state({ service: { state: 'error' } });
		return 1;
	}

	let conf_file = sprintf('/var/run/geovpn/%s.conf', active_id);
	let f = fs.open(conf_file, 'w', 0o600);
	if (!f) {
		util.log('error', sprintf('Cannot write %s', conf_file));
		state.update_state({ service: { state: 'error' } });
		return 1;
	}
	f.write(conf_text);
	f.close();

	// Render ruleset, sets, dnsmasq configs via their modules
	let geo_cidrs = load_geo_cidrs(config);
	let geosite_domains = load_geosite_domains(config);

	fwzone.ensure_firewall_zone(config.main);
	nftgen.apply_ruleset(config, geo_cidrs, profile);
	route.apply_routes(config.main);
	dnsgen.apply_dnsmasq(config, geosite_domains, profile);

	state.update_state({ service: { state: 'connecting' } });
	return 0;
}

function cmd_teardown() {
	let config = cfg.load_config();
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
	cmd_teardown();

	let cursor = uci.cursor();
	cursor.load('geovpn');
	cursor.set('geovpn', 'main', 'enabled', '0');
	cursor.commit('geovpn');

	util.safe_exec(['/etc/init.d/geovpn', 'stop']);
	print('Emergency stop complete: GeoVPN disabled, all routing rules removed.\n');
	return 0;
}

function cmd_hook() {
	let env_file = '/var/run/geovpn/hook.env';
	let f = fs.open(env_file, 'r');
	if (!f) return 0;
	let content = f.read('all') || '';
	f.close();

	let lines = split(content, '\n');
	let env_vars = {};
	for (let line in lines) {
		let parts = split(line, '=');
		if (length(parts) >= 2) {
			env_vars[parts[0]] = join('=', slice(parts, 1));
		}
	}

	let stype = env_vars['script_type'];
	if (stype == 'up') {
		let dev = env_vars['dev'] || 'geovpn0';
		let local_ip = env_vars['ifconfig_local'] || '';
		let remote_ip = env_vars['ifconfig_remote'] || '';
		let ipv6_local = env_vars['ifconfig_ipv6_local'] || '';

		// Enable loose reverse path filtering (rp_filter=2)
		let rp_path = sprintf('/proc/sys/net/ipv4/conf/%s/rp_filter', dev);
		if (fs.stat(rp_path)) {
			let rp_f = fs.open(rp_path, 'w');
			if (rp_f) {
				rp_f.write('2\n');
				rp_f.close();
			}
		}

		route.set_tunnel_up(dev, ipv6_local && length(ipv6_local) > 0);

		state.update_state({
			service: { state: 'connected' },
			tunnel: {
				device: dev,
				since: time(),
				local_ip: local_ip,
				remote_ip: remote_ip,
				ipv6: (ipv6_local && length(ipv6_local) > 0)
			}
		});
		util.log('info', sprintf('Tunnel up on %s (%s -> %s)', dev, local_ip, remote_ip));
	} else if (stype == 'down') {
		route.set_tunnel_down();

		state.update_state({
			service: { state: 'connecting' },
			tunnel: { since: 0, uptime: 0 }
		});
		util.log('info', 'Tunnel down');
	}
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
		print('  import <file> [n] Import .ovpn profile\n');
		print('  test <target>     Test routing destination\n');
		print('  update [--force]  Update geo data packs\n');
		print('  diag              Run system diagnostics\n');
		print('  panic             Emergency reset and shutdown\n');
		print('  purge             Complete reset (removes all rules, profiles, and configs)\n');
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
	if (cmd == 'panic') return cmd_panic();
	if (cmd == 'purge') {
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
	if (cmd == 'import') return cmd_import(args[1], args[2]);
	if (cmd == '_prepare') return cmd_prepare();
	if (cmd == '_teardown') return cmd_teardown();
	if (cmd == '_reload') { cmd_teardown(); return cmd_prepare(); }
	if (cmd == '_hook') return cmd_hook();
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

	if (cmd == 'test') {
		let res = diag.test_target(args[1], args[2]);
		print(sprintf('%J\n', res));
		return 0;
	}

	if (cmd == 'update') {
		return data.run_update(length(args) > 1 && args[1] == '--force');
	}

	fs.stderr.write(sprintf('Unknown command: %s\n', cmd));
	return 1;
}

export {
	main
};
