//
// GeoVPN OpenVPN Protocol Driver
//
'use strict';

import * as fs from 'fs';
import * as util from '../util.uc';
import * as cred from '../cred.uc';

const proto = 'openvpn';

function available() {
	let ok = fs.stat('/usr/sbin/openvpn') != null;
	return {
		ok: ok,
		missing: ok ? [] : ['openvpn-openssl'],
		note: ok ? 'OpenVPN client binary available' : 'Package openvpn-openssl is required'
	};
}

function validate(profile, cfg) {
	let errors = [];
	let warnings = [];
	if (!profile || type(profile) != 'object') {
		push(errors, 'Profile is required and must be an object');
		return { errors: errors, warnings: warnings };
	}
	let remotes = profile.remotes || profile.remote;
	if (type(remotes) == 'string') remotes = [remotes];
	if (!remotes || type(remotes) != 'array' || length(remotes) == 0) {
		push(warnings, 'No remote endpoints defined');
	}
	return { errors: errors, warnings: warnings };
}

function endpoints(profile) {
	let eps = [];
	if (!profile) return eps;
	let remotes = profile.remotes || profile.remote;
	if (type(remotes) == 'string') remotes = [remotes];
	if (!remotes || type(remotes) != 'array') {
		return eps;
	}
	for (let r in remotes) {
		let parts = split(r, ' ');
		if (length(parts) >= 1 && util.is_hostname(parts[0])) {
			let port = (length(parts) >= 2 && util.is_port(parts[1])) ? +parts[1] : 1194;
			let transport = (length(parts) >= 3) ? lc(parts[2]) : 'udp';
			let ips = [];
			if (util.is_ip(parts[0])) {
				push(ips, parts[0]);
			}
			push(eps, {
				host: parts[0],
				port: port,
				transport: transport,
				ips: ips
			});
		}
	}
	return eps;
}

function render_ovpn(profile, profile_dir, main_cfg, ctx) {
	if (!profile || type(profile) != 'object') return null;

	let tun_dev = 'geovpn0';
	if (ctx && ctx.dev) {
		tun_dev = ctx.dev;
	} else if (main_cfg && main_cfg.tun_dev) {
		tun_dev = main_cfg.tun_dev;
	}

	let syslog_tag = (ctx && ctx.unit) ? ctx.unit : 'geovpn';

	let lines = [];
	push(lines, '# Managed by GeoVPN — do not edit manually');
	push(lines, 'client');
	push(lines, sprintf('dev %s', tun_dev));
	push(lines, 'dev-type tun');
	push(lines, 'nobind');
	push(lines, 'persist-key');
	push(lines, 'persist-tun');

	// Remote endpoints
	let remotes = profile.remotes || profile.remote;
	if (type(remotes) == 'string') remotes = [remotes];
	if (remotes && type(remotes) == 'array') {
		for (let r in remotes) {
			let parts = split(r, ' ');
			if (length(parts) >= 1 && util.is_hostname(parts[0])) {
				let port = (length(parts) >= 2 && util.is_port(parts[1])) ? parts[1] : '1194';
				let proto_str = (length(parts) >= 3) ? parts[2] : 'udp';
				push(lines, sprintf('remote %s %s %s', parts[0], port, proto_str));
			}
		}
	}

	if (profile.remote_random == '1' || profile.remote_random == true) {
		push(lines, 'remote-random');
	}

	if (profile.remote_cert_tls && profile.remote_cert_tls != 'none') {
		push(lines, sprintf('remote-cert-tls %s', profile.remote_cert_tls));
	}

	push(lines, 'resolv-retry infinite');
	push(lines, 'connect-retry 5');

	// Keepalive & ping normalization (N1/N2 rules)
	let has_ping = (profile.ping && length(profile.ping) > 0) ||
	               (profile.ping_restart && length(profile.ping_restart) > 0) ||
	               (profile.ping_exit && length(profile.ping_exit) > 0);
	if (!has_ping) {
		if (profile.keepalive && length(profile.keepalive) > 0) {
			push(lines, sprintf('keepalive %s', profile.keepalive));
		} else {
			push(lines, 'keepalive 10 60');
		}
	}
	if (profile.ping && length(profile.ping) > 0) {
		push(lines, sprintf('ping %s', profile.ping));
	}
	if (profile.ping_restart && length(profile.ping_restart) > 0) {
		push(lines, sprintf('ping-restart %s', profile.ping_restart));
	} else if (profile.ping_exit && length(profile.ping_exit) > 0) {
		// N1 rule: ping-exit N -> ping-restart N
		push(lines, sprintf('ping-restart %s', profile.ping_exit));
	}
	if (profile.explicit_exit_notify && length(profile.explicit_exit_notify) > 0) {
		push(lines, sprintf('explicit-exit-notify %s', profile.explicit_exit_notify));
	}

	// Route isolation
	push(lines, 'route-nopull');
	push(lines, 'pull-filter ignore "redirect-gateway"');
	push(lines, 'pull-filter ignore "block-outside-dns"');

	// Hook supervision
	push(lines, 'script-security 2');
	push(lines, 'up /usr/libexec/geovpn/ovpn-hook');
	push(lines, 'down /usr/libexec/geovpn/ovpn-hook');
	push(lines, 'up-restart');
	if (ctx && ctx.kind) {
		let gv_val = (ctx.kind == 'test') ? sprintf('test:%s:%s', ctx.jid || ctx.id, ctx.id) : sprintf('%s:%s', ctx.kind, ctx.id);
		push(lines, sprintf('setenv GV_CTX %s', gv_val));
		if (ctx.kind == 'test') {
			push(lines, 'connect-retry-max 1');
			push(lines, 'connect-timeout 10');
		}
	}
	push(lines, sprintf('syslog %s', syslog_tag));
	push(lines, 'verb 3');

	// Cryptographic options
	if (profile.cipher && length(profile.cipher) > 0) {
		push(lines, sprintf('cipher %s', profile.cipher));
	}
	if (profile.data_ciphers && length(profile.data_ciphers) > 0) {
		push(lines, sprintf('data-ciphers %s', profile.data_ciphers));
	}
	if (profile.data_ciphers_fallback && length(profile.data_ciphers_fallback) > 0) {
		push(lines, sprintf('data-ciphers-fallback %s', profile.data_ciphers_fallback));
	}
	if (profile.auth && length(profile.auth) > 0) {
		push(lines, sprintf('auth %s', profile.auth));
	}
	if (profile.tls_version_min && length(profile.tls_version_min) > 0) {
		push(lines, sprintf('tls-version-min %s', profile.tls_version_min));
	}
	if (profile.verify_x509_name && length(profile.verify_x509_name) > 0) {
		push(lines, sprintf('verify-x509-name %s', profile.verify_x509_name));
	}
	if (profile.peer_fingerprint && length(profile.peer_fingerprint) > 0) {
		push(lines, sprintf('peer-fingerprint %s', profile.peer_fingerprint));
	}

	// Performance parameters
	if (profile.mssfix) {
		push(lines, sprintf('mssfix %d', +profile.mssfix));
	}
	if (profile.tun_mtu) {
		push(lines, sprintf('tun-mtu %d', +profile.tun_mtu));
	}
	if (profile.compress && profile.compress != 'none') {
		push(lines, sprintf('compress %s', profile.compress));
	}

	// Key materials from profile directory or credential sets
	if (profile_dir) {
		let ca_file = profile_dir + '/ca.crt';
		let cert_file = profile_dir + '/cert.crt';
		let key_file = profile_dir + '/key.pem';
		let tls_file = profile_dir + '/tls.key';
		let auth_file = profile_dir + '/auth';

		// Credential set lookup if profile.cred is set
		if (profile.cred && length(profile.cred) > 0) {
			let cred_path = cred.get_secret_path(profile.cred, 'auth');
			if (cred_path && fs.stat(cred_path)) auth_file = cred_path;
		}

		if (fs.stat(ca_file)) {
			push(lines, sprintf('ca %s', ca_file));
		}
		if (fs.stat(cert_file)) {
			push(lines, sprintf('cert %s', cert_file));
		}
		if (fs.stat(key_file)) {
			push(lines, sprintf('key %s', key_file));
		}

		if (profile.tls_kind == 'tls-crypt' && fs.stat(tls_file)) {
			push(lines, sprintf('tls-crypt %s', tls_file));
		} else if (profile.tls_kind == 'tls-crypt-v2' && fs.stat(tls_file)) {
			push(lines, sprintf('tls-crypt-v2 %s', tls_file));
		} else if (profile.tls_kind == 'tls-auth' && fs.stat(tls_file)) {
			if (profile.key_direction && length(profile.key_direction) > 0) {
				push(lines, sprintf('tls-auth %s %s', tls_file, profile.key_direction));
			} else {
				push(lines, sprintf('tls-auth %s', tls_file));
			}
		}

		if ((profile.auth_user_pass == '1' || profile.auth_user_pass == true) && fs.stat(auth_file)) {
			push(lines, sprintf('auth-user-pass %s', auth_file));
		}
	}

	// Allowlisted extra options
	if (profile.extra && type(profile.extra) == 'array') {
		for (let opt in profile.extra) {
			push(lines, opt);
		}
	}

	return join('\n', lines) + '\n';
}

function prepare(ctx, profile, cfg) {
	if (!ctx || !ctx.rundir) return { ok: false, err: 'Context with rundir required' };
	if (!fs.stat(ctx.rundir)) {
		fs.mkdir(ctx.rundir, 0o700);
	}

	let pdir = '/etc/geovpn/profiles/' + ctx.id;
	let conf_text = render_ovpn(profile, pdir, cfg ? cfg.main : null, ctx);
	if (!conf_text) {
		return { ok: false, err: 'Failed to render OpenVPN configuration' };
	}

	let conf_file = sprintf('%s/%s.conf', ctx.rundir, ctx.id);
	let f = fs.open(conf_file, 'w', 0o600);
	if (!f) {
		return { ok: false, err: sprintf('Cannot write %s', conf_file) };
	}
	f.write(conf_text);
	f.close();

	return { ok: true, config_path: conf_file };
}

function start(ctx, profile, creds) {
	if (!ctx) return { ok: false, err: 'Context required' };
	if (ctx.kind == 'active') {
		let res = util.safe_exec(['/etc/init.d/geovpn', 'start']);
		return { ok: (res.code == 0), async: true, err: res.code != 0 ? res.stderr : null };
	}
	// Test context
	let conf_file = sprintf('%s/%s.conf', ctx.rundir, ctx.id);
	if (!fs.stat(conf_file)) {
		let prep = prepare(ctx, profile, null);
		if (!prep.ok) return prep;
	}
	let pid_file = sprintf('%s/openvpn.pid', ctx.rundir);
	let cmd = [
		'/usr/sbin/openvpn',
		'--config', conf_file,
		'--syslog', ctx.unit || 'geovpn-test',
		'--writepid', pid_file,
		'--daemon'
	];
	let res = util.safe_exec(cmd);
	return { ok: (res.code == 0), async: true, pid_file: pid_file };
}

function facts(ctx) {
	let dev = (ctx && ctx.dev) ? ctx.dev : 'geovpn0';
	let is_up = false;
	let local_ip = '';
	let remote_ip = '';
	let ipv6_local = '';
	let dns_servers = [];

	let rundir = (ctx && ctx.rundir) ? ctx.rundir : (getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn');
	let env_file = rundir + '/hook.env';
	let env_mtime = 0;
	if (fs.stat(env_file)) {
		let st = fs.stat(env_file);
		env_mtime = st ? st.mtime : 0;
		let f = fs.open(env_file, 'r');
		if (f) {
			let content = f.read('all') || '';
			f.close();
			let lines = split(content, '\n');
			for (let line in lines) {
				let parts = split(line, '=');
				if (length(parts) >= 2) {
					let k = parts[0];
					let v = join('=', slice(parts, 1));
					if (k == 'script_type' && v == 'up') is_up = true;
					if (k == 'ifconfig_local') local_ip = v;
					if (k == 'ifconfig_remote') remote_ip = v;
					if (k == 'ifconfig_ipv6_local') ipv6_local = v;
					if (index(k, 'foreign_option_') == 0) {
						let fparts = split(v, ' ');
						if (length(fparts) >= 3 && fparts[0] == 'dhcp-option' && fparts[1] == 'DNS' && (util.is_ipv4(fparts[2]) || util.is_ipv6(fparts[2]))) {
							push(dns_servers, fparts[2]);
						}
					}
				}
			}
		}
	}

	let rx = 0;
	let tx = 0;
	let rxf = fs.open(sprintf('/sys/class/net/%s/statistics/rx_bytes', dev), 'r');
	if (rxf) { rx = +trim(rxf.read('all') || '0'); rxf.close(); }
	let txf = fs.open(sprintf('/sys/class/net/%s/statistics/tx_bytes', dev), 'r');
	if (txf) { tx = +trim(txf.read('all') || '0'); txf.close(); }

	return {
		proto: 'openvpn',
		up: is_up,
		dev: dev,
		v4: local_ip ? [local_ip] : [],
		v6: ipv6_local ? [ipv6_local] : [],
		dns: dns_servers,
		has_v6: (length(ipv6_local) > 0),
		mtu: 1500,
		since: is_up ? (env_mtime || time()) : 0,
		endpoint_ip: remote_ip,
		rx: rx,
		tx: tx,
		last_handshake: null,
		state: is_up ? 'connected' : 'down'
	};
}

function refresh(ctx) {
	return { ok: true };
}

function stop(ctx) {
	if (!ctx) return { ok: false };
	if (ctx.kind == 'active') {
		let res = util.safe_exec(['/etc/init.d/geovpn', 'stop']);
		return { ok: (res.code == 0) };
	}
	return cleanup(ctx);
}

function cleanup(ctx) {
	if (!ctx) return { ok: false };
	if (ctx.rundir && fs.stat(ctx.rundir)) {
		let pid_file = sprintf('%s/openvpn.pid', ctx.rundir);
		if (fs.stat(pid_file)) {
			let pf = fs.open(pid_file, 'r');
			if (pf) {
				let pid_str = trim(pf.read('all') || '');
				pf.close();
				if (length(pid_str) > 0 && match(pid_str, /^[0-9]+$/)) {
					util.safe_exec(['kill', '-15', pid_str]);
				}
			}
			fs.unlink(pid_file);
		}
		let conf = sprintf('%s/%s.conf', ctx.rundir, ctx.id);
		if (fs.stat(conf)) fs.unlink(conf);
		let env_f = ctx.rundir + '/hook.env';
		if (fs.stat(env_f)) fs.unlink(env_f);
	}
	return { ok: true };
}

export {
	proto,
	available,
	validate,
	endpoints,
	render_ovpn,
	prepare,
	start,
	facts,
	refresh,
	stop,
	cleanup
};
