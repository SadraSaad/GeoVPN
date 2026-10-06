//
// GeoVPN UCI Configuration & Profile CRUD Library
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as math from 'math';
import * as util from './util.uc';

const PROFILES_DIR = '/etc/geovpn/profiles';

function ensure_profiles_dir() {
	if (!fs.stat(PROFILES_DIR)) {
		fs.mkdir(PROFILES_DIR, 0o700);
	}
}

function get_cursor() {
	let cursor = uci.cursor();
	cursor.load('geovpn');
	return cursor;
}

function load_config() {
	let cursor = get_cursor();
	let config = {
		main: {},
		data: {},
		profiles: {},
		geoip: [],
		geosite: [],
		rules: [],
		clients: []
	};

	let sections = cursor.get_all('geovpn');
	if (!sections) return config;

	for (let sname in sections) {
		let s = sections[sname];
		let stype = s['.type'];

		if (stype == 'main') {
			config.main = s;
		} else if (stype == 'data') {
			config.data = s;
		} else if (stype == 'profile') {
			if (util.is_profile_id(sname)) {
				config.profiles[sname] = s;
			}
		} else if (stype == 'geoip') {
			push(config.geoip, s);
		} else if (stype == 'geosite') {
			push(config.geosite, s);
		} else if (stype == 'rule') {
			push(config.rules, s);
		} else if (stype == 'client') {
			push(config.clients, s);
		}
	}

	return config;
}

function generate_profile_id() {
	ensure_profiles_dir();
	for (let i = 0; i < 100; i++) {
		let val = (math && math.rand) ? math.rand() : time();
		let hex = sprintf('%08x', val & 0xffffffff);
		let id = 'p' + hex;
		if (!fs.stat(PROFILES_DIR + '/' + id)) {
			return id;
		}
	}
	return 'p' + sprintf('%08x', time());
}

function get_profile(id) {
	if (!util.is_profile_id(id)) return null;
	let cursor = get_cursor();
	let p = cursor.get('geovpn', id);
	if (!p || p['.type'] != 'profile') return null;

	let pdir = PROFILES_DIR + '/' + id;
	p.has_ca = fs.stat(pdir + '/ca.crt') != null;
	p.has_cert = fs.stat(pdir + '/cert.crt') != null;
	p.has_key = fs.stat(pdir + '/key.pem') != null;
	p.has_tls = fs.stat(pdir + '/tls.key') != null;
	p.has_auth = fs.stat(pdir + '/auth') != null;

	return p;
}

function create_profile(parsed_profile) {
	ensure_profiles_dir();
	let id = generate_profile_id();
	let pdir = PROFILES_DIR + '/' + id;
	fs.mkdir(pdir, 0o700);

	let cursor = get_cursor();
	cursor.set('geovpn', id, 'profile');
	let opts = {
		name: parsed_profile.name || 'Imported Profile',
		enabled: '1',
		remote: parsed_profile.remotes || [],
		remote_random: parsed_profile.remote_random ? '1' : '0',
		auth_user_pass: parsed_profile.auth_user_pass ? '1' : '0',
		tls_kind: parsed_profile.tls_kind || 'none',
		key_direction: parsed_profile.key_direction || '',
		cipher: parsed_profile.cipher || '',
		data_ciphers: parsed_profile.data_ciphers || '',
		data_ciphers_fallback: parsed_profile.data_ciphers_fallback || '',
		auth: parsed_profile.auth || '',
		tls_version_min: parsed_profile.tls_version_min || '',
		verify_x509_name: parsed_profile.verify_x509_name || '',
		peer_fingerprint: parsed_profile.peer_fingerprint || '',
		remote_cert_tls: parsed_profile.remote_cert_tls || 'server',
		mssfix: sprintf('%d', parsed_profile.mssfix || 1450),
		tun_mtu: sprintf('%d', parsed_profile.tun_mtu || 1500),
		keepalive: parsed_profile.keepalive || '10 60',
		compress: parsed_profile.compress || 'none',
		imported_at: sprintf('%d', time())
	};
	for (let k in opts) {
		cursor.set('geovpn', id, k, opts[k]);
	}
	cursor.commit('geovpn');

	// Write inline material files
	if (parsed_profile.materials) {
		let m = parsed_profile.materials;
		if (m.ca) fs.writefile(pdir + '/ca.crt', m.ca, 0o600);
		if (m.cert) fs.writefile(pdir + '/cert.crt', m.cert, 0o600);
		if (m.key) fs.writefile(pdir + '/key.pem', m.key, 0o600);
		if (m['tls-crypt']) fs.writefile(pdir + '/tls.key', m['tls-crypt'], 0o600);
		else if (m['tls-crypt-v2']) fs.writefile(pdir + '/tls.key', m['tls-crypt-v2'], 0o600);
		else if (m['tls-auth']) fs.writefile(pdir + '/tls.key', m['tls-auth'], 0o600);
		if (m['crl-verify']) fs.writefile(pdir + '/crl.pem', m['crl-verify'], 0o600);
		if (m['extra-certs']) fs.writefile(pdir + '/extra.crt', m['extra-certs'], 0o600);
	}

	return id;
}

function delete_profile(id) {
	if (!util.is_profile_id(id)) return false;
	let pdir = PROFILES_DIR + '/' + id;
	if (fs.stat(pdir)) {
		let entries = fs.lsdir(pdir);
		if (entries) {
			for (let e in entries) {
				if (e != '.' && e != '..') {
					fs.unlink(pdir + '/' + e);
				}
			}
		}
		fs.rmdir(pdir);
	}

	let cursor = get_cursor();
	cursor.delete('geovpn', id);

	let active = cursor.get('geovpn', 'main', 'active_profile');
	if (active == id) {
		cursor.set('geovpn', 'main', 'active_profile', '');
	}
	cursor.commit('geovpn');
	return true;
}

function set_profile_credentials(id, username, password) {
	if (!util.is_profile_id(id)) return false;
	ensure_profiles_dir();
	let pdir = PROFILES_DIR + '/' + id;
	if (!fs.stat(pdir)) return false;

	let auth_file = pdir + '/auth';
	let f = fs.open(auth_file, 'w', 0o600);
	if (!f) return false;
	f.write(sprintf('%s\n%s\n', username, password));
	f.close();

	let cursor = get_cursor();
	cursor.set('geovpn', id, 'auth_user_pass', '1');
	cursor.commit('geovpn');
	return true;
}

function put_profile_material(id, role, content) {
	if (!util.is_profile_id(id)) return false;
	ensure_profiles_dir();
	let pdir = PROFILES_DIR + '/' + id;
	if (!fs.stat(pdir)) return false;

	let filename = null;
	if (role == 'ca') filename = 'ca.crt';
	else if (role == 'cert') filename = 'cert.crt';
	else if (role == 'key') filename = 'key.pem';
	else if (role == 'tls-auth' || role == 'tls-crypt' || role == 'tls-crypt-v2') filename = 'tls.key';
	else if (role == 'extra-certs') filename = 'extra.crt';
	else if (role == 'crl-verify') filename = 'crl.pem';

	if (!filename) return false;
	let target = pdir + '/' + filename;
	let f = fs.open(target, 'w', 0o600);
	if (!f) return false;
	f.write(content);
	f.close();

	if (role == 'tls-auth' || role == 'tls-crypt' || role == 'tls-crypt-v2') {
		let cursor = get_cursor();
		cursor.set('geovpn', id, 'tls_kind', role);
		cursor.commit('geovpn');
	}
	return true;
}

export {
	load_config,
	get_profile,
	create_profile,
	delete_profile,
	set_profile_credentials,
	put_profile_material,
	PROFILES_DIR
};
