//
// GeoVPN IKEv2 / strongSwan Protocol Driver (§6.6 / FR-30 / NFR-19)
// Route-based IPsec via XFRM interfaces, isolated swanctl configs, 0x<hex> secret encoding.
//
'use strict';

import * as fs from 'fs';
import * as util from '../util.uc';
import * as cred from '../cred.uc';

const proto = 'ikev2';

function normalize_args(a1, a2) {
	if (a1 && a1.kind) return { ctx: a1, profile: a2 };
	return { ctx: a2, profile: a1 };
}

function to_hex(str) {
	if (!str) return '';
	let h = '';
	for (let i = 0; i < length(str); i++) h += sprintf('%02x', ord(str, i));
	return h;
}

function resolve_host(host) {
	if (util.is_ip(host)) return [host];
	let ips = [];
	let res = util.safe_exec(['nslookup', host]);
	if (res && res.code == 0 && res.stdout) {
		for (let line in split(res.stdout, '\n')) {
			let m = match(line, /Address[ 0-9]*:?\s+([0-9.]+)/);
			if (m && m[1] && m[1] != '127.0.0.1' && util.is_ipv4(m[1])) push(ips, m[1]);
			let m6 = match(line, /Address[ 0-9]*:?\s+([0-9a-fA-F:]+)/);
			if (m6 && m6[1] && m6[1] != '::1' && util.is_ipv6(m6[1])) push(ips, m6[1]);
		}
	}
	return ips;
}

function available() {
	let missing = [];
	let has_swanctl = (fs.stat('/usr/sbin/swanctl') != null) || (util.safe_exec(['which', 'swanctl']).code == 0);
	let has_ip = (fs.stat('/sbin/ip') != null) || (util.safe_exec(['which', 'ip']).code == 0);
	let has_charon = (fs.stat('/usr/lib/ipsec/charon') != null) || (fs.stat('/usr/libexec/ipsec/charon') != null) ||
	                 (fs.stat('/etc/init.d/ipsec') != null) || (fs.stat('/etc/init.d/swanctl') != null);
	let has_xfrm = (fs.stat('/sys/module/xfrm_interface') != null);

	if (!has_swanctl) push(missing, 'strongswan-swanctl');
	if (!has_charon) push(missing, 'strongswan-charon');
	if (!has_ip) push(missing, 'ip-full');
	if (!has_xfrm) {
		let chk = util.safe_exec(['ip', 'link', 'add', 'dev', 'gv_xfrm_chk', 'type', 'xfrm', 'if_id', '9999']);
		if (chk.code == 0) {
			util.safe_exec(['ip', 'link', 'del', 'dev', 'gv_xfrm_chk']);
			has_xfrm = true;
		} else {
			push(missing, 'kmod-xfrm-interface');
		}
	}
	let ok = (length(missing) == 0);
	return {
		ok: ok,
		missing: missing,
		note: ok ? 'strongSwan and XFRM interface available' : ('Missing: ' + join(', ', missing))
	};
}

function validate(profile, cfg) {
	let errors = [], warnings = [];
	if (!profile || type(profile) != 'object') return { errors: ['Profile is required'], warnings: [] };

	let host = profile.ike_host || (profile.remotes && profile.remotes[0]) || (profile.remote && profile.remote[0]);
	if (!host || !util.is_hostname(host)) push(errors, 'Invalid or missing IKEv2 remote server hostname');

	let auth = profile.ike_auth || 'eap-mschapv2';
	if (auth == 'eap-mschapv2') {
		let user = profile.ike_username || profile.username;
		if (!user && profile.cred) {
			let up = cred.get_userpass(profile.cred);
			if (up && up.username) user = up.username;
		}
		if (!user || length(user) == 0) push(errors, 'EAP-MSCHAPv2 requires a username');

		let has_sec = profile.password || profile.ike_secret;
		let id = profile.id;
		if (!has_sec && id) {
			let sp = sprintf('%s/%s/ike.secret', cfg ? cfg.get_profiles_dir() : '/etc/geovpn/profiles', id);
			if (fs.stat(sp) || cred.has_secret(id, 'auth')) has_sec = true;
		}
		if (!has_sec && profile.cred && cred.has_secret(profile.cred, 'auth')) has_sec = true;
		if (!has_sec) push(warnings, 'Password not configured; connection will require credentials');
	}
	return { errors: errors, warnings: warnings };
}

function endpoints(profile) {
	if (!profile) return [];
	let host = profile.ike_host || (profile.remotes && profile.remotes[0]) || (profile.remote && profile.remote[0]);
	if (!host || !util.is_hostname(host)) return [];
	let ips = resolve_host(host);
	return [
		{ host: host, port: 500, transport: 'udp', ips: ips },
		{ host: host, port: 4500, transport: 'udp', ips: ips }
	];
}

function prepare(arg1, arg2, cfg) {
	let pair = normalize_args(arg1, arg2);
	let ctx = pair.ctx, profile = pair.profile;
	if (!ctx || !profile) return { ok: false, err: 'Context and profile required' };

	let rundir = ctx.rundir || '/var/run/geovpn';
	if (!fs.stat(rundir)) {
		util.safe_exec(['mkdir', '-p', rundir]);
		if (!fs.stat(rundir)) fs.mkdir(rundir, 0o700);
		fs.chmod(rundir, 0o700);
	}

	let conn_name = (ctx.kind == 'test') ? ('gv_test_' + (ctx.jid || ctx.id)) : 'gv_active';
	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	let if_id = ctx.ifid || (ctx.kind == 'test' ? 4300 : 4200);

	let host = profile.ike_host || (profile.remotes && profile.remotes[0]) || (profile.remote && profile.remote[0]);
	let remote_id = profile.ike_remote_id || host;
	let auth = profile.ike_auth || 'eap-mschapv2';
	let dpd = +(profile.ike_dpd || 30);
	let ca_cert = profile.ike_ca || 'geovpn-isrg-x1.pem';

	let username = profile.ike_username || profile.username || '';
	let secret = profile.password || profile.ike_secret || '';

	if (profile.cred) {
		let up = cred.get_userpass(profile.cred);
		if (up) {
			if (!username && up.username) username = up.username;
			if (!secret && up.password) secret = up.password;
		}
	}
	if (!secret && ctx.id) {
		let up = cred.get_userpass(ctx.id);
		if (up) {
			if (!username && up.username) username = up.username;
			if (!secret && up.password) secret = up.password;
		}
		if (!secret) {
			let sf = fs.open(sprintf('%s/ike.secret', rundir), 'r');
			if (sf) { secret = trim(sf.read('all') || ''); sf.close(); }
		}
	}

	let hex_secret = to_hex(secret);

	let sys_ca_dir = '/etc/swanctl/x509ca';
	if (!fs.stat(sys_ca_dir)) util.safe_exec(['mkdir', '-p', sys_ca_dir]);
	let shipped_ca = '/usr/share/geovpn/ca/' + ca_cert;
	let target_ca = sys_ca_dir + '/' + ca_cert;
	if (fs.stat(shipped_ca) && !fs.stat(target_ca)) util.safe_exec(['cp', shipped_ca, target_ca]);

	let sec_block = (hex_secret && username) ?
		sprintf("secrets {\n  eap-%s {\n    id = %s\n    secret = 0x%s\n  }\n}\n", conn_name, username, hex_secret) : "";

	let frag = (profile.ike_fragmentation == '0' || profile.ike_fragmentation === false) ? 'no' : 'yes';
	let mobike = (profile.ike_mobike == '1' || profile.ike_mobike === true) ? 'yes' : 'no';

	let conf_content = sprintf(
		"# Managed by GeoVPN\nconnections {\n  %s {\n    version = 2\n    remote_addrs = %s\n    vips = 0.0.0.0, ::\n    dpd_delay = %ds\n    fragmentation = %s\n    mobike = %s\n    local {\n      auth = %s\n%s    }\n    remote {\n      auth = pubkey\n      id = %s\n      cacerts = %s\n    }\n    children {\n      %s {\n        remote_ts = 0.0.0.0/0, ::/0\n        if_id_in = %d\n        if_id_out = %d\n        start_action = none\n        dpd_action = restart\n        close_action = restart\n        updown = /usr/libexec/geovpn/ike-updown\n      }\n    }\n  }\n}\n%s",
		conn_name, host, dpd, frag, mobike, auth, username ? sprintf("      eap_id = %s\n", username) : "",
		remote_id, ca_cert, conn_name, if_id, if_id, sec_block
	);

	let conf_path = sprintf('%s/swanctl.conf', rundir);
	let cf = fs.open(conf_path, 'w', 0o600);
	if (!cf) return { ok: false, err: 'Failed to write swanctl.conf' };
	cf.write(conf_content);
	cf.close();
	fs.chmod(conf_path, 0o600);

	let dns_list = profile.ike_dns || [];
	if (type(dns_list) == 'string') dns_list = [dns_list];
	if (length(dns_list) > 0) {
		let df = fs.open(sprintf('%s/pushed_dns', rundir), 'w', 0o644);
		if (df) {
			for (let d in dns_list) df.write(sprintf('%s\n', d));
			df.close();
		}
	}

	let meta = {
		id: ctx.id, conn_name: conn_name, dev: dev, if_id: if_id,
		host: host, remote_id: remote_id, username: username,
		auth: auth, mtu: profile.ike_mtu || 1420, dns: dns_list
	};
	let mf = fs.open(sprintf('%s/profile.json', rundir), 'w', 0o600);
	if (mf) { mf.write(sprintf('%J', meta)); mf.close(); }

	return { ok: true, rundir: rundir, conf_path: conf_path, conn_name: conn_name, if_id: if_id, dev: dev };
}

function start(arg1, arg2, cfg) {
	let pair = normalize_args(arg1, arg2);
	let ctx = pair.ctx, profile = pair.profile;
	if (!ctx) return { ok: false, err: 'Context required' };

	let prep = prepare(profile, ctx, cfg);
	if (!prep || !prep.ok) return prep;

	let dev = prep.dev, if_id = prep.if_id, conn_name = prep.conn_name, rundir = prep.rundir;

	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
	let add_res = util.safe_exec(['ip', 'link', 'add', 'dev', dev, 'type', 'xfrm', 'if_id', sprintf('%d', if_id)]);
	if (add_res.code != 0) return { ok: false, err: sprintf('Failed to create XFRM dev %s (if_id %d): %s', dev, if_id, add_res.stderr) };

	let mtu = profile.ike_mtu || 1420;
	let up_res = util.safe_exec(['ip', 'link', 'set', 'dev', dev, 'mtu', sprintf('%d', mtu), 'up']);
	if (up_res.code != 0) {
		util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
		return { ok: false, err: sprintf('Failed to bring up XFRM dev %s: %s', dev, up_res.stderr) };
	}

	// Non-destructive charon daemon management (M2)
	let charon_running = (fs.stat('/var/run/charon.vici') != null) || (util.safe_exec(['pgrep', '-x', 'charon']).code == 0);
	if (!charon_running) {
		let s_res = util.safe_exec(['/etc/init.d/ipsec', 'start']);
		if (s_res.code != 0) util.safe_exec(['/etc/init.d/swanctl', 'start']);
		let wf = fs.open(sprintf('%s/we_started_charon', rundir), 'w', 0o600);
		if (wf) { wf.write('1\n'); wf.close(); }
	}

	util.safe_exec(['swanctl', '--load-creds', '--file', prep.conf_path]);
	let load_res = util.safe_exec(['swanctl', '--load-conns', '--file', prep.conf_path]);
	if (load_res.code != 0) {
		util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
		return { ok: false, err: sprintf('swanctl load-conns failed: %s', load_res.stderr) };
	}

	let timeout_s = (ctx.kind == 'test') ? 10 : 15;
	util.safe_exec(['swanctl', '--initiate', '--child', conn_name, '--timeout', sprintf('%d', timeout_s)]);

	return { ok: true, dev: dev, if_id: if_id, conn_name: conn_name, async: false };
}

function facts(ctx) {
	let dev = (ctx && ctx.dev) ? ctx.dev : (ctx && ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	let conn_name = (ctx && ctx.kind == 'test') ? ('gv_test_' + (ctx.jid || ctx.id)) : 'gv_active';
	let rundir = (ctx && ctx.rundir) ? ctx.rundir : '/var/run/geovpn';

	let sas_res = util.safe_exec(['swanctl', '--list-sas']);
	let sas_out = (sas_res && sas_res.code == 0) ? (sas_res.stdout || '') : '';

	let has_est = false, has_inst = false, ep_ip = '', established_s = 0;
	let rx_bytes = 0, tx_bytes = 0, local_vip = '', local_vip6 = '';

	if (sas_out) {
		let in_conn = false;
		for (let line in split(sas_out, '\n')) {
			let l = trim(line);
			if (index(line, conn_name + ':') == 0) {
				in_conn = true;
				if (index(line, 'ESTABLISHED') != -1) has_est = true;
			} else if (match(line, /^[a-zA-Z0-9_-]+:/)) {
				in_conn = false;
			}
			if (in_conn) {
				if (index(l, 'INSTALLED') != -1) has_inst = true;
				let m_rem = match(l, /remote\s+[^@]*@\s*([0-9.]+)(\[[0-9]+\]|:[0-9]+)/);
				if (m_rem && m_rem[1] && util.is_ipv4(m_rem[1])) ep_ip = m_rem[1];
				let m_est = match(l, /established\s+([0-9]+)s\s+ago/);
				if (m_est && m_est[1]) established_s = +m_est[1];
				let m_in = match(l, /in\s+[0-9a-fA-F]+,\s*([0-9]+)\s*bytes/);
				if (m_in && m_in[1]) rx_bytes = +m_in[1];
				let m_out = match(l, /out\s+[0-9a-fA-F]+,\s*([0-9]+)\s*bytes/);
				if (m_out && m_out[1]) tx_bytes = +m_out[1];
				let m_vip = match(l, /local\s+([0-9.]+)\/32/);
				if (m_vip && m_vip[1] && util.is_ipv4(m_vip[1])) local_vip = m_vip[1];
				let m_vip6 = match(l, /local\s+([0-9a-fA-F:]+)\/128/);
				if (m_vip6 && m_vip6[1] && util.is_ipv6(m_vip6[1])) local_vip6 = m_vip6[1];
			}
		}
	}

	let v4_list = [], v6_list = [];
	let addr_res = util.safe_exec(['ip', '-o', 'addr', 'show', 'dev', dev]);
	if (addr_res.code == 0 && addr_res.stdout) {
		for (let line in split(addr_res.stdout, '\n')) {
			let m4 = match(line, /inet\s+([0-9.]+)/);
			if (m4 && util.is_ipv4(m4[1])) push(v4_list, m4[1]);
			let m6 = match(line, /inet6\s+([0-9a-fA-F:]+)/);
			if (m6 && util.is_ipv6(m6[1]) && substr(m6[1], 0, 4) != 'fe80') push(v6_list, m6[1]);
		}
	}
	if (length(v4_list) == 0 && local_vip) push(v4_list, local_vip);
	if (length(v6_list) == 0 && local_vip6) push(v6_list, local_vip6);

	let dns_servers = [];
	let df = fs.open(sprintf('%s/pushed_dns', rundir), 'r');
	if (df) {
		let dlines = split(df.read('all'), '\n');
		df.close();
		for (let dl in dlines) {
			let dip = trim(dl);
			if (util.is_ip(dip)) push(dns_servers, dip);
		}
	}

	let mtu = 1420;
	let mf = fs.open(sprintf('/sys/class/net/%s/mtu', dev), 'r');
	if (mf) { mtu = +trim(mf.read('all') || '1420'); mf.close(); }

	let is_up = (has_est && has_inst);
	let state_str = is_up ? 'connected' : (has_est ? 'connecting' : 'down');
	let now = time();

	return {
		proto: 'ikev2',
		up: is_up,
		dev: dev,
		v4: v4_list,
		v6: v6_list,
		dns: dns_servers,
		has_v6: (length(v6_list) > 0),
		mtu: mtu,
		since: established_s > 0 ? (now - established_s) : 0,
		endpoint_ip: ep_ip,
		rx: rx_bytes,
		tx: tx_bytes,
		last_handshake: established_s > 0 ? (now - established_s) : null,
		state: state_str
	};
}

function refresh(ctx) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let conn_name = (ctx.kind == 'test') ? ('gv_test_' + (ctx.jid || ctx.id)) : 'gv_active';
	let res = util.safe_exec(['swanctl', '--initiate', '--child', conn_name]);
	return { ok: (res.code == 0) };
}

function cleanup(ctx) {
	if (!ctx) return { ok: false };
	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);

	let rundir = ctx.rundir || '/var/run/geovpn';
	if (fs.stat(rundir)) {
		let start_marker = sprintf('%s/we_started_charon', rundir);
		if (fs.stat(start_marker)) {
			let s_res = util.safe_exec(['/etc/init.d/ipsec', 'stop']);
			if (s_res.code != 0) util.safe_exec(['/etc/init.d/swanctl', 'stop']);
			fs.unlink(start_marker);
		}
		let del_files = ['swanctl.conf', 'profile.json', 'pushed_dns', 'hook.env', 'ike.secret'];
		for (let f in del_files) {
			let path = sprintf('%s/%s', rundir, f);
			if (fs.stat(path)) fs.unlink(path);
		}
		if (ctx.kind == 'test') fs.rmdir(rundir);
	}
	return { ok: true };
}

function stop(ctx) {
	if (!ctx) return { ok: false };
	let conn_name = (ctx.kind == 'test') ? ('gv_test_' + (ctx.jid || ctx.id)) : 'gv_active';
	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	let rundir = ctx.rundir || '/var/run/geovpn';

	util.safe_exec(['swanctl', '--terminate', '--ike', conn_name]);
	util.safe_exec(['swanctl', '--unload-conn', '--name', conn_name]);
	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);

	let start_marker = sprintf('%s/we_started_charon', rundir);
	if (fs.stat(start_marker)) {
		let s_res = util.safe_exec(['/etc/init.d/ipsec', 'stop']);
		if (s_res.code != 0) util.safe_exec(['/etc/init.d/swanctl', 'stop']);
		fs.unlink(start_marker);
	}
	return cleanup(ctx);
}

export {
	proto, available, validate, endpoints, prepare, start, facts, refresh, stop, cleanup
};
