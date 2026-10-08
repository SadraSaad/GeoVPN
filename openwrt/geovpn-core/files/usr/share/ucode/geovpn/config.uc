//
// GeoVPN UCI Configuration & Profile CRUD Library
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as math from 'math';
import * as util from './util.uc';
import * as cred from './cred.uc';

const PROFILES_DIR = '/etc/geovpn/profiles';

function get_profiles_dir() {
	return getenv('GEOVPN_PROFILES_DIR') || PROFILES_DIR;
}

function ensure_profiles_dir() {
	let pdir = get_profiles_dir();
	if (!fs.stat('/etc/geovpn') && !getenv('GEOVPN_PROFILES_DIR')) {
		fs.mkdir('/etc/geovpn', 0o755);
	}
	if (!fs.stat(pdir)) {
		fs.mkdir(pdir, 0o700);
	}
}

function write_file_safe(path, data, mode) {
	let f = fs.open(path, 'w', mode || 0o600);
	if (!f) return false;
	f.write(data);
	f.close();
	return true;
}

function read_file_safe(path) {
	let f = fs.open(path, 'r');
	if (!f) return null;
	let content = f.read('all');
	f.close();
	return content;
}

function get_cursor() {
	let confdir = getenv('UCI_CONFIG_DIR');
	let cursor = confdir ? uci.cursor(confdir) : uci.cursor();
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
		clients: [],
		credentials: [],
		test: {},
		autoconnect: {}
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
				let rem_list = s.remotes || s.remote;
				if (type(rem_list) == 'string') rem_list = [rem_list];
				s.remotes = rem_list || [];
				s.remote = s.remotes;
				if (s.proto == 'wireguard') {
					if (type(s.wg_address) == 'string') s.wg_address = [s.wg_address];
					if (type(s.wg_dns) == 'string') s.wg_dns = [s.wg_dns];
					if (type(s.wg_allowed_ips) == 'string') s.wg_allowed_ips = [s.wg_allowed_ips];
				}
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
		} else if (stype == 'test') {
			config.test = s;
		} else if (stype == 'autoconnect') {
			let fb = s.fallback;
			if (type(fb) == 'string') fb = (length(fb) > 0 ? [fb] : []);
			s.fallback = fb || [];
			config.autoconnect = s;
		} else if (stype == 'credential') {
			push(config.credentials, s);
		}
	}

	return config;
}

function generate_profile_id() {
	ensure_profiles_dir();
	let base = get_profiles_dir();
	for (let i = 0; i < 100; i++) {
		let val = (math && math.rand) ? math.rand() : time();
		let hex = sprintf('%08x', val & 0xffffffff);
		let id = 'p' + hex;
		if (!fs.stat(base + '/' + id)) {
			return id;
		}
	}
	return 'p' + sprintf('%08x', time());
}

function get_profile(id) {
	if (!util.is_profile_id(id)) return null;
	let cursor = get_cursor();
	let p = cursor.get_all('geovpn', id);
	if (!p || p['.type'] != 'profile') return null;

	let pdir = get_profiles_dir() + '/' + id;
	let cred_id = p.cred;
	p.has_ca = fs.stat(pdir + '/ca.crt') != null;
	p.has_cert = fs.stat(pdir + '/cert.crt') != null;
	p.has_key = fs.stat(pdir + '/key.pem') != null;
	p.has_tls = fs.stat(pdir + '/tls.key') != null;
	p.has_auth = (fs.stat(pdir + '/auth') != null) || (cred_id && cred.has_secret(cred_id, 'auth'));
	p.has_wg_key = (fs.stat(pdir + '/wg.key') != null) || cred.has_secret(id, 'wg.key') || (cred_id && cred.has_secret(cred_id, 'wg.key'));
	p.has_wg_psk = (fs.stat(pdir + '/wg.psk') != null) || cred.has_secret(id, 'wg.psk') || (cred_id && cred.has_secret(cred_id, 'wg.psk'));

	let rem_list = p.remotes || p.remote;
	if (type(rem_list) == 'string') rem_list = [rem_list];
	p.remotes = rem_list || [];
	p.remote = p.remotes;

	p.proto = p.proto || 'openvpn';
	p.provider = p.provider || '';
	p.cred = p.cred || '';
	p.source_sha256 = p.source_sha256 || '';
	p.keepalive = p.keepalive || '';
	p.auto_pool = (p.auto_pool == null || p.auto_pool == '1') ? '1' : '0';

	if (p.proto == 'wireguard') {
		let addr_list = p.wg_address;
		if (type(addr_list) == 'string') addr_list = [addr_list];
		p.wg_address = addr_list || [];

		let dns_list = p.wg_dns;
		if (type(dns_list) == 'string') dns_list = [dns_list];
		p.wg_dns = dns_list || [];

		let aip_list = p.wg_allowed_ips;
		if (type(aip_list) == 'string') aip_list = [aip_list];
		p.wg_allowed_ips = aip_list || ['0.0.0.0/0'];
	} else if (p.proto == 'ikev2') {
		p.ike_host = p.ike_host || '';
		p.ike_remote_id = p.ike_remote_id || p.ike_host || '';
		p.ike_auth = p.ike_auth || 'eap-mschapv2';
		p.ike_username = p.ike_username || '';
		p.ike_ca = p.ike_ca || 'geovpn-isrg-x1.pem';
		p.ike_dpd = p.ike_dpd || '30';
		p.ike_fragmentation = (p.ike_fragmentation != null) ? p.ike_fragmentation : '1';
		p.ike_mobike = (p.ike_mobike != null) ? p.ike_mobike : '0';
		p.ike_if_id = p.ike_if_id || '4200';
		p.ike_mtu = p.ike_mtu || '1420';
		let dns_list = p.ike_dns;
		if (type(dns_list) == 'string') dns_list = [dns_list];
		p.ike_dns = dns_list || [];
		p.has_ike_secret = (fs.stat(pdir + '/ike.secret') != null) || cred.has_secret(id, 'auth') || (cred_id && cred.has_secret(cred_id, 'auth'));
	}

	return p;
}

function create_profile(parsed_profile) {
	ensure_profiles_dir();
	let id = generate_profile_id();
	let pdir = get_profiles_dir() + '/' + id;
	fs.mkdir(pdir, 0o700);

	let cursor = get_cursor();
	cursor.set('geovpn', id, 'profile');
	let opts = {
		name: parsed_profile.name || 'Imported Profile',
		enabled: '1',
		proto: parsed_profile.proto || 'openvpn',
		provider: parsed_profile.provider || '',
		cred: parsed_profile.cred || '',
		source_sha256: parsed_profile.source_sha256 || '',
		auto_pool: (parsed_profile.auto_pool != null) ? parsed_profile.auto_pool : '1',
		remote: parsed_profile.remotes || parsed_profile.remote || [],
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
		keepalive: (parsed_profile.keepalive != null) ? parsed_profile.keepalive : '10 60',
		ping: parsed_profile.ping || '',
		ping_restart: parsed_profile.ping_restart || '',
		ping_exit: parsed_profile.ping_exit || '',
		explicit_exit_notify: parsed_profile.explicit_exit_notify || '',
		compress: parsed_profile.compress || 'none',
		imported_at: sprintf('%d', time())
	};

	if (parsed_profile.proto == 'wireguard') {
		opts.proto = 'wireguard';
		opts.wg_endpoint_host = parsed_profile.wg_endpoint_host || '';
		opts.wg_endpoint_port = sprintf('%d', parsed_profile.wg_endpoint_port || 51820);
		opts.wg_public_key = parsed_profile.wg_public_key || '';
		opts.wg_address = parsed_profile.wg_address || [];
		opts.wg_dns = parsed_profile.wg_dns || [];
		opts.wg_allowed_ips = parsed_profile.wg_allowed_ips || ['0.0.0.0/0'];
		opts.wg_mtu = sprintf('%d', parsed_profile.wg_mtu || 1420);
		opts.wg_keepalive = sprintf('%d', (parsed_profile.wg_keepalive != null) ? parsed_profile.wg_keepalive : 25);
		opts.wg_has_psk = parsed_profile.wg_has_psk ? '1' : '0';
		opts.wg_allow_partial = parsed_profile.wg_allow_partial ? '1' : '0';
	} else if (parsed_profile.proto == 'ikev2') {
		opts.proto = 'ikev2';
		opts.ike_host = parsed_profile.ike_host || '';
		opts.ike_remote_id = parsed_profile.ike_remote_id || parsed_profile.ike_host || '';
		opts.ike_auth = parsed_profile.ike_auth || 'eap-mschapv2';
		opts.ike_username = parsed_profile.ike_username || parsed_profile.username || '';
		opts.ike_ca = parsed_profile.ike_ca || 'geovpn-isrg-x1.pem';
		opts.ike_dpd = sprintf('%d', parsed_profile.ike_dpd || 30);
		opts.ike_fragmentation = (parsed_profile.ike_fragmentation != null) ? parsed_profile.ike_fragmentation : '1';
		opts.ike_mobike = (parsed_profile.ike_mobike != null) ? parsed_profile.ike_mobike : '0';
		opts.ike_if_id = sprintf('%d', parsed_profile.ike_if_id || 4200);
		opts.ike_mtu = sprintf('%d', parsed_profile.ike_mtu || 1420);
		opts.ike_dns = parsed_profile.ike_dns || [];
	}

	for (let k in opts) {
		cursor.set('geovpn', id, k, opts[k]);
	}
	cursor.commit('geovpn');

	// Write WireGuard key files (mode 0600) - skip if linked to shared credential set
	if (parsed_profile.proto == 'wireguard') {
		let cred_id = parsed_profile.cred;
		let has_cred_key = (cred_id && length(cred_id) > 0 && cred.has_secret(cred_id, 'wg.key'));
		let has_cred_psk = (cred_id && length(cred_id) > 0 && cred.has_secret(cred_id, 'wg.psk'));

		if (parsed_profile.private_key && !has_cred_key) {
			write_file_safe(pdir + '/wg.key', parsed_profile.private_key, 0o600);
		}
		if (parsed_profile.preshared_key && !has_cred_psk) {
			write_file_safe(pdir + '/wg.psk', parsed_profile.preshared_key, 0o600);
		}
	}

	// Write IKEv2 secret file (mode 0600) - skip if linked to shared credential set with secret
	if (parsed_profile.proto == 'ikev2') {
		let cred_id = parsed_profile.cred;
		let has_cred = (cred_id && length(cred_id) > 0 && cred.has_secret(cred_id, 'auth'));
		let sec = parsed_profile.password || parsed_profile.ike_secret;
		if (sec && !has_cred) {
			write_file_safe(pdir + '/ike.secret', sec, 0o600);
		}
	}

	// Write inline material files
	if (parsed_profile.materials) {
		let m = parsed_profile.materials;
		if (m.ca) write_file_safe(pdir + '/ca.crt', m.ca, 0o600);
		if (m.cert) write_file_safe(pdir + '/cert.crt', m.cert, 0o600);
		if (m.key) write_file_safe(pdir + '/key.pem', m.key, 0o600);
		if (m['tls-crypt']) write_file_safe(pdir + '/tls.key', m['tls-crypt'], 0o600);
		else if (m['tls-crypt-v2']) write_file_safe(pdir + '/tls.key', m['tls-crypt-v2'], 0o600);
		else if (m['tls-auth']) write_file_safe(pdir + '/tls.key', m['tls-auth'], 0o600);
		if (m['crl-verify']) write_file_safe(pdir + '/crl.pem', m['crl-verify'], 0o600);
		if (m['extra-certs']) write_file_safe(pdir + '/extra.crt', m['extra-certs'], 0o600);
	}

	return id;
}

function delete_profile(id) {
	if (!util.is_profile_id(id)) return false;
	let pdir = get_profiles_dir() + '/' + id;
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
	let pdir = get_profiles_dir() + '/' + id;
	if (!fs.stat(pdir)) return false;

	let auth_file = pdir + '/auth';
	let f = fs.open(auth_file, 'w', 0o600);
	if (!f) return false;
	f.write(sprintf('%s\n%s\n', username, password));
	f.close();

	let cursor = get_cursor();
	let proto = cursor.get('geovpn', id, 'proto');
	if (proto == 'ikev2') {
		if (username) cursor.set('geovpn', id, 'ike_username', username);
		let sf = fs.open(pdir + '/ike.secret', 'w', 0o600);
		if (sf) {
			sf.write(password);
			sf.close();
		}
	} else {
		cursor.set('geovpn', id, 'auth_user_pass', '1');
	}
	cursor.commit('geovpn');
	return true;
}

function put_profile_material(id, role, content) {
	if (!util.is_profile_id(id)) return false;
	ensure_profiles_dir();
	let pdir = get_profiles_dir() + '/' + id;
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

function migrate_v1_to_v2(confdir, backup_dir) {
	let cdir = confdir;
	if (!cdir) {
		let cfile = getenv('CONFIG_FILE');
		if (cfile) {
			let parts = split(cfile, '/');
			cdir = join('/', slice(parts, 0, -1));
		} else {
			cdir = getenv('GEOVPN_CONF_DIR') || '/etc/config';
		}
	}
	let bdir = backup_dir || getenv('BACKUP_DIR') || getenv('GEOVPN_BACKUP_DIR') || '/etc/geovpn/backup';
	let cpath = cdir + '/geovpn';

	if (!fs.stat(cpath)) {
		return { ok: true, note: 'no configuration file to migrate' };
	}

	let cursor = uci.cursor(cdir);
	cursor.load('geovpn');

	let ver = cursor.get('geovpn', 'main', 'config_version');
	if (ver && +ver >= 2) {
		return { ok: true, note: 'already version 2 or newer' };
	}

	// 1. Ensure backup directory and create backup first
	if (!fs.stat(bdir)) {
		fs.mkdir(bdir, 0o700);
	}
	let ts = time();
	let bfile = sprintf('%s/geovpn.v1.%d', bdir, ts);

	let content = read_file_safe(cpath);
	if (!content) {
		return { ok: false, error: 'failed to read existing configuration' };
	}
	let bw = write_file_safe(bfile, content, 0o600);
	if (!bw) {
		return { ok: false, error: 'failed to write migration backup' };
	}

	// 2. Perform non-destructive migration
	try {
		let sections = cursor.get_all('geovpn');
		if (sections) {
			for (let sname in sections) {
				let s = sections[sname];
				if (s['.type'] == 'profile') {
					if (!s.proto || length(s.proto) == 0) {
						cursor.set('geovpn', sname, 'proto', 'openvpn');
					}
					if (!s.auto_pool || length(s.auto_pool) == 0) {
						cursor.set('geovpn', sname, 'auto_pool', '1');
					}
				}
			}
		}

		// 3. Add test section if missing
		let test_sec = cursor.get_all('geovpn', 'test');
		if (!test_sec || test_sec['.type'] != 'test') {
			cursor.set('geovpn', 'test', 'test');
			cursor.set('geovpn', 'test', 'max_handshake_ms', '8000');
			cursor.set('geovpn', 'test', 'max_latency_ms', '800');
			cursor.set('geovpn', 'test', 'max_loss_pct', '34');
			cursor.set('geovpn', 'test', 'require_http', '1');
			cursor.set('geovpn', 'test', 'samples', '3');
			cursor.set('geovpn', 'test', 'timeout_s', '20');
			cursor.set('geovpn', 'test', 'tolerance_ms', '50');
			cursor.set('geovpn', 'test', 'test_ttl', '300');
			cursor.set('geovpn', 'test', 'max_real', '1');
			cursor.set('geovpn', 'test', 'min_free_ram_mb', '48');
			cursor.set('geovpn', 'test', 'max_load', '3.0');
			cursor.set('geovpn', 'test', 'targets', [
				'https://www.gstatic.com/generate_204',
				'http://cp.cloudflare.com/generate_204'
			]);
			cursor.set('geovpn', 'test', 'proto_preference', ['wireguard', 'openvpn', 'ikev2']);
			cursor.set('geovpn', 'test', 'speed_url', '');
			cursor.set('geovpn', 'test', 'speed_max_kb', '2048');
			cursor.set('geovpn', 'test', 'rt_table', '4300');
		}

		// 4. Add autoconnect section if missing
		let auto_sec = cursor.get_all('geovpn', 'auto');
		if (!auto_sec || auto_sec['.type'] != 'autoconnect') {
			cursor.set('geovpn', 'auto', 'autoconnect');
			cursor.set('geovpn', 'auto', 'mode', 'off');
			cursor.set('geovpn', 'auto', 'fallback', []);
			cursor.set('geovpn', 'auto', 'connect_gate', 'off');
			cursor.set('geovpn', 'auto', 'health_enabled', '0');
			cursor.set('geovpn', 'auto', 'health_interval', '120');
			cursor.set('geovpn', 'auto', 'fail_threshold', '3');
			cursor.set('geovpn', 'auto', 'down_grace', '30');
			cursor.set('geovpn', 'auto', 'failover', '0');
			cursor.set('geovpn', 'auto', 'failover_max_candidates', '3');
			cursor.set('geovpn', 'auto', 'best_max_candidates', '8');
			cursor.set('geovpn', 'auto', 'failback', '0');
			cursor.set('geovpn', 'auto', 'min_switch_interval', '60');
			cursor.set('geovpn', 'auto', 'max_switches_per_hour', '6');
			cursor.set('geovpn', 'auto', 'persist_switch', '0');
		}

		// 5. Upgrade config_version to 2 and commit
		cursor.set('geovpn', 'main', 'config_version', '2');
		let saved = cursor.commit('geovpn');
		if (!saved) {
			write_file_safe(cpath, content, 0o600);
			return { ok: false, error: 'uci commit failed' };
		}
		return { ok: true, backup: bfile };
	} catch (e) {
		// Restore from backup on error
		write_file_safe(cpath, content, 0o600);
		return { ok: false, error: 'migration failed: ' + e };
	}
}

function rollback_migration(confdir, backup_dir) {
	let cdir = confdir;
	if (!cdir) {
		let cfile = getenv('CONFIG_FILE');
		if (cfile) {
			let parts = split(cfile, '/');
			cdir = join('/', slice(parts, 0, -1));
		} else {
			cdir = getenv('GEOVPN_CONF_DIR') || '/etc/config';
		}
	}
	let bdir = backup_dir || getenv('BACKUP_DIR') || getenv('GEOVPN_BACKUP_DIR') || '/etc/geovpn/backup';
	let cpath = cdir + '/geovpn';

	if (!fs.stat(bdir)) {
		return { ok: false, error: 'backup directory not found' };
	}

	let entries = fs.lsdir(bdir);
	if (!entries) {
		return { ok: false, error: 'cannot list backup directory' };
	}

	let backups = [];
	for (let entry in entries) {
		if (index(entry, 'geovpn.v1.') == 0) {
			push(backups, entry);
		}
	}

	if (length(backups) == 0) {
		return { ok: false, error: 'no v1 backups found in ' + bdir };
	}

	backups = sort(backups);
	let newest = backups[length(backups) - 1];
	let bfile = bdir + '/' + newest;

	let content = read_file_safe(bfile);
	if (!content) {
		return { ok: false, error: 'cannot read backup file ' + bfile };
	}

	let res = write_file_safe(cpath, content, 0o600);
	if (!res) {
		return { ok: false, error: 'failed to restore configuration from ' + bfile };
	}

	return { ok: true, restored_from: bfile };
}

function prepare_downgrade(confdir) {
	let cdir = confdir;
	if (!cdir) {
		let cfile = getenv('CONFIG_FILE');
		if (cfile) {
			let parts = split(cfile, '/');
			cdir = join('/', slice(parts, 0, -1));
		} else {
			cdir = getenv('GEOVPN_CONF_DIR') || '/etc/config';
		}
	}
	let cpath = cdir + '/geovpn';
	if (!fs.stat(cpath)) {
		return { ok: false, error: 'configuration file not found' };
	}

	let cursor = uci.cursor(cdir);
	cursor.load('geovpn');

	let warnings = [];
	let active = cursor.get('geovpn', 'main', 'active_profile') || '';
	let active_proto = 'openvpn';
	if (active && length(active) > 0) {
		active_proto = cursor.get('geovpn', active, 'proto') || 'openvpn';
	}

	let first_ovpn = '';
	let sections = cursor.get_all('geovpn');
	if (sections) {
		for (let sname in sections) {
			let s = sections[sname];
			if (s['.type'] == 'profile') {
				let proto = s.proto || 'openvpn';
				if (proto == 'openvpn' && !first_ovpn && s.enabled != '0') {
					first_ovpn = sname;
				}
				if (proto != 'openvpn') {
					push(warnings, sprintf('Warning: profile %s uses unsupported proto %s on baseline v1', sname, proto));
				}
			}
		}
	}

	// If active was not openvpn, switch to first ovpn or empty
	if (active_proto != 'openvpn') {
		cursor.set('geovpn', 'main', 'active_profile', first_ovpn);
	}

	cursor.set('geovpn', 'main', 'config_version', '1');
	cursor.commit('geovpn');

	return {
		ok: true,
		active_profile: cursor.get('geovpn', 'main', 'active_profile'),
		warnings: warnings
	};
}

function get_active_override() {
	let fpath = (getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn') + '/active_override';
	if (!fs.stat(fpath)) return null;
	let f = fs.open(fpath, 'r');
	if (!f) return null;
	let val = trim(f.read('all') || '');
	f.close();
	return (val && util.is_profile_id(val)) ? val : null;
}

function get_effective_active_profile_id(config) {
	let ov = get_active_override();
	if (ov) return ov;
	return (config && config.main) ? config.main.active_profile : null;
}

function set_active_override(id) {
	if (!id || !util.is_profile_id(id)) return false;
	let rdir = getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn';
	if (!fs.stat(rdir)) fs.mkdir(rdir, 0o755);
	let f = fs.open(rdir + '/active_override', 'w', 0o600);
	if (!f) return false;
	f.write(id + '\n');
	f.close();
	return true;
}

function clear_active_override() {
	let fpath = (getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn') + '/active_override';
	if (fs.stat(fpath)) fs.unlink(fpath);
}

export {
	get_cursor,
	load_config,
	get_profile,
	create_profile,
	delete_profile,
	set_profile_credentials,
	put_profile_material,
	migrate_v1_to_v2,
	rollback_migration,
	prepare_downgrade,
	get_profiles_dir,
	PROFILES_DIR,
	get_active_override,
	get_effective_active_profile_id,
	set_active_override,
	clear_active_override
};

