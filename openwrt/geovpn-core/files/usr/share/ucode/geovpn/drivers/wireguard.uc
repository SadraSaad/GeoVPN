//
// GeoVPN WireGuard Protocol Driver (§6.5 / FR-29 / NFR-19)
// Direct kernel ip/wg execution; secrets never in argv; cryptokey routing in kernel peer only.
//
'use strict';

import * as fs from 'fs';
import * as util from '../util.uc';
import * as cred from '../cred.uc';

const proto = 'wireguard';

function normalize_args(a1, a2) {
	if (a1 && a1.kind) return { ctx: a1, profile: a2 };
	return { ctx: a2, profile: a1 };
}

function resolve_host(host) {
	if (util.is_ip(host)) return [host];
	let ips = [];
	let has_ns = (fs.stat('/usr/bin/nslookup') != null) || (fs.stat('/bin/nslookup') != null);
	if (has_ns) {
		let res = util.safe_exec(['nslookup', host]);
		if (res && res.code == 0 && res.stdout) {
			let lines = split(res.stdout, '\n');
			for (let line in lines) {
				let m = match(line, /Address[ 0-9]*:?\s+([0-9.]+)/);
				if (m && m[1] && m[1] != '127.0.0.1' && util.is_ipv4(m[1])) push(ips, m[1]);
				let m6 = match(line, /Address[ 0-9]*:?\s+([0-9a-fA-F:]+)/);
				if (m6 && m6[1] && m6[1] != '::1' && util.is_ipv6(m6[1])) push(ips, m6[1]);
			}
		}
	}
	if (length(ips) == 0) {
		let gres = util.safe_exec(['getent', 'hosts', host]);
		if (gres && gres.code == 0 && gres.stdout) {
			let glines = split(gres.stdout, '\n');
			for (let line in glines) {
				let parts = split(trim(line), /[ \t]+/);
				if (parts && parts[0] && util.is_ip(parts[0]) && parts[0] != '127.0.0.1' && parts[0] != '::1') {
					push(ips, parts[0]);
				}
			}
		}
	}
	return ips;
}

function available() {
	let missing = [];
	let has_wg = (fs.stat('/usr/bin/wg') != null) || (util.safe_exec(['which', 'wg']).code == 0);
	let has_ip = (fs.stat('/sbin/ip') != null) || (util.safe_exec(['which', 'ip']).code == 0);
	let has_kmod = (fs.stat('/sys/module/wireguard') != null);

	if (!has_wg) push(missing, 'wireguard-tools');
	if (!has_ip) push(missing, 'ip-full');
	if (!has_kmod) {
		let chk = util.safe_exec(['ip', 'link', 'add', 'dev', 'gv_kmod_chk', 'type', 'wireguard']);
		if (chk.code == 0) {
			util.safe_exec(['ip', 'link', 'del', 'dev', 'gv_kmod_chk']);
			has_kmod = true;
		} else {
			push(missing, 'kmod-wireguard');
		}
	}
	let ok = (length(missing) == 0);
	return {
		ok: ok,
		missing: missing,
		note: ok ? 'WireGuard tools and kernel module available' : ('Missing required packages: ' + join(', ', missing))
	};
}

function validate(profile, cfg) {
	let errors = [];
	let warnings = [];
	if (!profile || type(profile) != 'object') {
		push(errors, 'Profile is required and must be an object');
		return { errors: errors, warnings: warnings };
	}
	if (!profile.wg_public_key || !util.is_wireguard_key(profile.wg_public_key)) push(errors, 'Invalid or missing WireGuard public key');
	if (!profile.wg_endpoint_host || !util.is_hostname(profile.wg_endpoint_host)) push(errors, 'Invalid or missing WireGuard endpoint host');
	if (!profile.wg_endpoint_port || !util.is_port(profile.wg_endpoint_port)) push(errors, 'Invalid or missing WireGuard endpoint port');

	let addrs = profile.wg_address;
	if (type(addrs) == 'string') addrs = [addrs];
	if (!addrs || type(addrs) != 'array' || length(addrs) == 0) {
		push(errors, 'At least one interface address (IPv4 or IPv6 CIDR) is required');
	} else {
		for (let a in addrs) if (!util.is_cidr(a)) push(errors, sprintf("Invalid address CIDR: '%s'", a));
	}

	let aips = profile.wg_allowed_ips;
	if (type(aips) == 'string') aips = [aips];
	if (!aips || type(aips) != 'array' || length(aips) == 0) {
		push(errors, 'AllowedIPs is required');
	} else {
		let has_def = false;
		for (let a in aips) {
			if (!util.is_cidr(a)) push(errors, sprintf("Invalid AllowedIPs CIDR: '%s'", a));
			if (a == '0.0.0.0/0' || a == '::/0') has_def = true;
		}
		if (!has_def && profile.wg_allow_partial != '1' && profile.wg_allow_partial != true) {
			push(errors, "AllowedIPs doesn't cover 0.0.0.0/0 or ::/0: GeoVPN routes the tunnel as a default route; narrow AllowedIPs would drop traffic");
		}
	}

	let id = profile.id;
	let has_key = profile.private_key && util.is_wireguard_key(profile.private_key);
	if (!has_key && id) {
		let kp = cred.get_wg_key_path(id);
		has_key = (kp && fs.stat(kp) != null);
	}
	if (!has_key) push(errors, 'WireGuard private key missing');
	if (!profile.wg_dns || length(profile.wg_dns) == 0) push(warnings, 'No WireGuard DNS servers configured');

	return { errors: errors, warnings: warnings };
}

function endpoints(profile) {
	let eps = [];
	if (!profile) return eps;
	let host = profile.wg_endpoint_host;
	let port = profile.wg_endpoint_port ? +profile.wg_endpoint_port : 51820;
	if (!host || !util.is_hostname(host)) return eps;

	let ips = resolve_host(host);
	push(eps, { host: host, port: port, transport: 'udp', ips: ips });
	return eps;
}

function prepare(arg1, arg2, cfg) {
	let pair = normalize_args(arg1, arg2);
	let ctx = pair.ctx;
	let profile = pair.profile;
	if (!ctx) return { ok: false, err: 'Context required' };
	if (!profile) return { ok: false, err: 'Profile required' };

	let rundir = ctx.rundir || '/var/run/geovpn';
	if (!fs.stat(rundir)) {
		util.safe_exec(['mkdir', '-p', rundir]);
		fs.chmod(rundir, 0o700);
	}

	let key_path = null;
	if (profile.cred) { let kp = cred.get_wg_key_path(profile.cred); if (kp && fs.stat(kp)) key_path = kp; }
	if (!key_path && ctx.id) { let kp = cred.get_wg_key_path(ctx.id); if (kp && fs.stat(kp)) key_path = kp; }
	if (!key_path && profile.private_key) {
		key_path = sprintf('%s/wg.key', rundir);
		let f = fs.open(key_path, 'w', 0o600);
		if (f) { f.write(profile.private_key); f.close(); fs.chmod(key_path, 0o600); }
	}
	if (!key_path || !fs.stat(key_path)) return { ok: false, err: 'Private key file not found' };

	let psk_path = null;
	if (profile.cred) { let pp = cred.get_wg_psk_path(profile.cred); if (pp && fs.stat(pp)) psk_path = pp; }
	if (!psk_path && ctx.id) { let pp = cred.get_wg_psk_path(ctx.id); if (pp && fs.stat(pp)) psk_path = pp; }
	if (!psk_path && profile.preshared_key) {
		psk_path = sprintf('%s/wg.psk', rundir);
		let pf = fs.open(psk_path, 'w', 0o600);
		if (pf) { pf.write(profile.preshared_key); pf.close(); fs.chmod(psk_path, 0o600); }
	}

	let dns_list = profile.wg_dns;
	if (type(dns_list) == 'string') dns_list = [dns_list];
	if (dns_list && length(dns_list) > 0) {
		let df = fs.open(sprintf('%s/pushed_dns', rundir), 'w', 0o644);
		if (df) {
			for (let d in dns_list) df.write(d + '\n');
			df.close();
		}
	}

	let meta = {
		id: ctx.id,
		dev: ctx.dev,
		endpoint_host: profile.wg_endpoint_host,
		endpoint_port: profile.wg_endpoint_port,
		public_key: profile.wg_public_key,
		address: profile.wg_address,
		allowed_ips: profile.wg_allowed_ips,
		mtu: profile.wg_mtu || 1420,
		keepalive: (profile.wg_keepalive != null) ? profile.wg_keepalive : 25,
		key_path: key_path,
		psk_path: psk_path
	};
	let mf = fs.open(sprintf('%s/profile.json', rundir), 'w', 0o600);
	if (mf) { mf.write(sprintf('%J', meta)); mf.close(); }

	return { ok: true, rundir: rundir, key_path: key_path, psk_path: psk_path };
}

function start(arg1, arg2, cfg) {
	let pair = normalize_args(arg1, arg2);
	let ctx = pair.ctx;
	let profile = pair.profile;
	if (!ctx) return { ok: false, err: 'Context required' };

	let prep = prepare(profile, ctx, cfg);
	if (!prep || !prep.ok) return prep;

	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);

	let add_res = util.safe_exec(['ip', 'link', 'add', 'dev', dev, 'type', 'wireguard']);
	if (add_res.code != 0) {
		return { ok: false, err: sprintf('Failed to create WireGuard device %s: %s', dev, add_res.stderr) };
	}

	let ep_host = profile.wg_endpoint_host;
	let ep_port = profile.wg_endpoint_port ? +profile.wg_endpoint_port : 51820;
	let ep_ips = resolve_host(ep_host);
	let ep_target = (length(ep_ips) > 0) ? ep_ips[0] : ep_host;
	let endpoint_str = sprintf(index(ep_target, ':') != -1 ? '[%s]:%d' : '%s:%d', ep_target, ep_port);

	let wg_cmd = ['wg', 'set', dev, 'private-key', prep.key_path, 'peer', profile.wg_public_key];
	if (prep.psk_path && fs.stat(prep.psk_path)) push(wg_cmd, 'preshared-key', prep.psk_path);
	push(wg_cmd, 'endpoint', endpoint_str);

	let aips = profile.wg_allowed_ips;
	if (type(aips) == 'string') aips = [aips];
	let aip_str = (aips && length(aips) > 0) ? join(',', aips) : '0.0.0.0/0';
	push(wg_cmd, 'allowed-ips', aip_str);

	let ka = (profile.wg_keepalive != null) ? profile.wg_keepalive : 25;
	push(wg_cmd, 'persistent-keepalive', sprintf('%d', ka));

	let set_res = util.safe_exec(wg_cmd);
	if (set_res.code != 0) {
		util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
		return { ok: false, err: sprintf('wg set failed on %s: %s', dev, set_res.stderr) };
	}

	let addrs = profile.wg_address;
	if (type(addrs) == 'string') addrs = [addrs];
	for (let a in addrs) util.safe_exec(['ip', 'address', 'add', a, 'dev', dev]);

	let mtu = profile.wg_mtu || 1420;
	let up_res = util.safe_exec(['ip', 'link', 'set', 'dev', dev, 'mtu', sprintf('%d', mtu), 'up']);
	if (up_res.code != 0) {
		util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
		return { ok: false, err: sprintf('Failed to bring up interface %s: %s', dev, up_res.stderr) };
	}

	return { ok: true, dev: dev, async: false };
}

function facts(ctx) {
	let dev = (ctx && ctx.dev) ? ctx.dev : 'geovpn0';
	let res = util.safe_exec(['wg', 'show', dev, 'dump']);
	if (res.code != 0) {
		return {
			proto: 'wireguard', up: false, dev: dev, v4: [], v6: [], dns: [],
			has_v6: false, mtu: 1420, since: 0, endpoint_ip: '', rx: 0, tx: 0,
			last_handshake: null, state: 'down'
		};
	}

	let lines = split(trim(res.stdout), '\n');
	let last_hs = 0;
	let rx_bytes = 0;
	let tx_bytes = 0;
	let endpoint_str = '';
	let allowed_ips_str = '';

	for (let i = 1; i < length(lines); i++) {
		if (!lines[i]) continue;
		let peer_fields = split(lines[i], '\t');
		if (length(peer_fields) >= 7) {
			endpoint_str = peer_fields[2];
			allowed_ips_str = peer_fields[3] || '';
			last_hs = +peer_fields[4] || 0;
			rx_bytes = +peer_fields[5] || 0;
			tx_bytes = +peer_fields[6] || 0;
			break;
		}
	}

	let ep_ip = '';
	if (endpoint_str && endpoint_str != '(none)') {
		if (substr(endpoint_str, 0, 1) == '[') {
			let end_b = index(endpoint_str, ']');
			if (end_b != -1) ep_ip = substr(endpoint_str, 1, end_b - 1);
		} else {
			let col = rindex(endpoint_str, ':');
			ep_ip = (col != -1) ? substr(endpoint_str, 0, col) : endpoint_str;
		}
	}

	let now = time();
	let state_str = 'connecting';
	let is_up = false;
	if (last_hs > 0) {
		let age = now - last_hs;
		if (age <= 180) { state_str = 'connected'; is_up = true; }
		else { state_str = 'stale'; is_up = true; }
	}

	let v4_list = [];
	let v6_list = [];
	let addr_res = util.safe_exec(['ip', '-o', 'addr', 'show', 'dev', dev]);
	if (addr_res.code == 0 && addr_res.stdout) {
		let alines = split(addr_res.stdout, '\n');
		for (let line in alines) {
			let m4 = match(line, /inet\s+([0-9.]+)/);
			if (m4 && util.is_ipv4(m4[1])) push(v4_list, m4[1]);
			let m6 = match(line, /inet6\s+([0-9a-fA-F:]+)/);
			if (m6 && util.is_ipv6(m6[1]) && substr(m6[1], 0, 4) != 'fe80') push(v6_list, m6[1]);
		}
	}

	let dns_servers = [];
	let rundir = (ctx && ctx.rundir) ? ctx.rundir : '/var/run/geovpn';
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

	// PLAN_ADDENDUM §6.5: has_v6 = wg_address has v6 && AllowedIPs has ::/0
	let has_v6_allowed = (index(allowed_ips_str, '::/0') != -1);
	let has_v6 = (length(v6_list) > 0 && has_v6_allowed);

	return {
		proto: 'wireguard', up: is_up, dev: dev, v4: v4_list, v6: v6_list,
		dns: dns_servers, has_v6: has_v6, mtu: mtu, since: (last_hs > 0 ? last_hs : 0),
		endpoint_ip: ep_ip, rx: rx_bytes, tx: tx_bytes,
		last_handshake: last_hs > 0 ? last_hs : null, state: state_str
	};
}

function refresh(ctx) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let rundir = ctx.rundir || '/var/run/geovpn';
	let dev = ctx.dev || 'geovpn0';
	let mf = fs.open(sprintf('%s/profile.json', rundir), 'r');
	if (!mf) return { ok: true, note: 'No cached profile state' };
	let raw = mf.read('all');
	mf.close();
	let meta = null;
	try { meta = json(raw); } catch (e) { return { ok: false, err: 'Corrupt state' }; }
	if (!meta || !meta.endpoint_host || !meta.public_key) return { ok: true };

	let ips = resolve_host(meta.endpoint_host);
	if (length(ips) > 0) {
		let ep_str = sprintf(index(ips[0], ':') != -1 ? '[%s]:%d' : '%s:%d', ips[0], meta.endpoint_port || 51820);
		let res = util.safe_exec(['wg', 'set', dev, 'peer', meta.public_key, 'endpoint', ep_str]);
		return { ok: (res.code == 0), endpoint: ep_str };
	}
	return { ok: true };
}

function stop(ctx) {
	if (!ctx) return { ok: false };
	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
	return cleanup(ctx);
}

function cleanup(ctx) {
	if (!ctx) return { ok: false };
	let dev = ctx.dev || (ctx.kind == 'test' ? 'gvt0' : 'geovpn0');
	util.safe_exec(['ip', 'link', 'del', 'dev', dev]);
	let rundir = ctx.rundir || '/var/run/geovpn';
	if (fs.stat(rundir)) {
		let del_files = ['wg.key', 'wg.psk', 'profile.json', 'pushed_dns'];
		for (let f in del_files) {
			let path = sprintf('%s/%s', rundir, f);
			if (fs.stat(path)) fs.unlink(path);
		}
		if (ctx.kind == 'test') fs.rmdir(rundir);
	}
	return { ok: true };
}

export {
	proto, available, validate, endpoints, prepare, start, facts, refresh, stop, cleanup
};
