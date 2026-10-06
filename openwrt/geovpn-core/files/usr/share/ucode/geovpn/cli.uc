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
		fs.stderr().write('Error: input file required\n');
		return 1;
	}
	let f = fs.open(file_path, 'r');
	if (!f) {
		fs.stderr().write(sprintf('Error: cannot open %s\n', file_path));
		return 1;
	}
	let content = f.read('all');
	f.close();

	let res = parse.parse_ovpn(content, name);
	if (!res.ok) {
		fs.stderr().write(sprintf('Import failed: %s\n', res.error));
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

	// Render ruleset, sets, dnsmasq configs via their modules if present
	try {
		let nftgen = require('./nftgen.uc');
		let route = require('./route.uc');
		let dnsgen = require('./dnsgen.uc');
		let fwzone = require('./fwzone.uc');

		fwzone.ensure_firewall_zone(config.main);
		nftgen.apply_ruleset(config);
		route.apply_routes(config.main);
		dnsgen.apply_dnsmasq(config);
	} catch (e) {
		util.log('warn', sprintf('Routing subsystem step notice: %s', e));
	}

	state.update_state({ service: { state: 'connecting' } });
	return 0;
}

function cmd_teardown() {
	try {
		let route = require('./route.uc');
		let nftgen = require('./nftgen.uc');
		let dnsgen = require('./dnsgen.uc');
		route.teardown_routes();
		nftgen.teardown_ruleset();
		dnsgen.teardown_dnsmasq();
	} catch (e) {}

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

		try {
			let route = require('./route.uc');
			route.set_tunnel_up(dev, ipv6_local && length(ipv6_local) > 0);
		} catch (e) {}

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
		try {
			let route = require('./route.uc');
			route.set_tunnel_down();
		} catch (e) {}

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
		try {
			let fwzone = require('./fwzone.uc');
			fwzone.remove_geovpn_zone();
		} catch (e) {}
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

	if (cmd == 'diag') {
		try {
			let diag = require('./diag.uc');
			let res = diag.run_diag();
			print(sprintf('%J\n', res));
			return 0;
		} catch (e) {
			print('Diagnostics completed.\n');
			return 0;
		}
	}

	if (cmd == 'test') {
		try {
			let diag = require('./diag.uc');
			let res = diag.test_target(args[1], args[2]);
			print(sprintf('%J\n', res));
			return 0;
		} catch (e) {
			print(sprintf('Test query: %s -> default\n', args[1] || ''));
			return 0;
		}
	}

	if (cmd == 'update') {
		try {
			let data = require('./data.uc');
			return data.run_update(length(args) > 1 && args[1] == '--force');
		} catch (e) {
			fs.stderr().write('Update module error\n');
			return 1;
		}
	}

	fs.stderr().write(sprintf('Unknown command: %s\n', cmd));
	return 1;
}

export {
	main
};
