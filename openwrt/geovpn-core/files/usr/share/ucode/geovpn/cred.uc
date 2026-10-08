//
// GeoVPN Credential and Secret Store (§5.4 / FR-34 / NFR-18)
// Manages credentials under /etc/geovpn/credentials/
// Directory mode: 0700, File mode: 0600
// Secrets are NEVER written to UCI, argv, logs, or RPC output.
//
'use strict';

import * as fs from 'fs';
import * as util from './util.uc';

const CRED_BASE_DIR = '/etc/geovpn/credentials';
const RE_ID = /^[A-Za-z0-9_.-]{1,64}$/;
const RE_NAME = /^[A-Za-z0-9_.-]{1,64}$/;

function is_valid_id(id) {
	if (type(id) != 'string') return false;
	if (index(id, '..') != -1 || index(id, '/') != -1) return false;
	return (match(id, RE_ID) != null);
}

function is_valid_name(name) {
	if (type(name) != 'string') return false;
	if (index(name, '..') != -1 || index(name, '/') != -1) return false;
	return (match(name, RE_NAME) != null);
}

function get_base_dir() {
	return getenv('GEOVPN_CRED_DIR') || CRED_BASE_DIR;
}

/**
 * Ensures directory exists with mode 0700
 */
function ensure_cred_dir(id) {
	let base = get_base_dir();
	if (!getenv('GEOVPN_CRED_DIR') && !fs.stat('/etc/geovpn')) {
		fs.mkdir('/etc/geovpn', 0o755);
	}
	if (!fs.stat(base)) {
		fs.mkdir(base, 0o700);
	}
	fs.chmod(base, 0o700);

	if (id) {
		if (!is_valid_id(id)) return null;
		let dir = base + '/' + id;
		if (!fs.stat(dir)) {
			fs.mkdir(dir, 0o700);
		}
		fs.chmod(dir, 0o700);
		return dir;
	}
	return base;
}

/**
 * Safely stores a secret string into a 0600 file under /etc/geovpn/credentials/<id>/<name>
 */
function store_secret(id, name, content) {
	if (!is_valid_id(id) || !is_valid_name(name)) return false;
	if (content == null) return false;

	let dir = ensure_cred_dir(id);
	if (!dir) return false;

	let path = dir + '/' + name;
	let f = fs.open(path, 'w', 0o600);
	if (!f) return false;
	f.write('' + content);
	f.close();
	fs.chmod(path, 0o600);
	return true;
}

/**
 * Loads a secret string from /etc/geovpn/credentials/<id>/<name>
 */
function load_secret(id, name) {
	if (!is_valid_id(id) || !is_valid_name(name)) return null;
	let base = get_base_dir();
	let path = base + '/' + id + '/' + name;
	if (!fs.stat(path)) return null;

	let f = fs.open(path, 'r');
	if (!f) return null;
	let content = f.read('all');
	f.close();
	return content;
}

/**
 * Deletes a single secret file under a credential id
 */
function delete_secret(id, name) {
	if (!is_valid_id(id) || !is_valid_name(name)) return false;
	let base = get_base_dir();
	let path = base + '/' + id + '/' + name;
	if (fs.stat(path)) {
		fs.unlink(path);
	}
	return true;
}

/**
 * Deletes an entire credential directory and all files inside
 */
function delete_credential(id) {
	if (!is_valid_id(id)) return false;
	let base = get_base_dir();
	let dir = base + '/' + id;
	if (fs.stat(dir)) {
		let entries = fs.lsdir(dir);
		if (entries) {
			for (let e in entries) {
				if (e != '.' && e != '..') {
					fs.unlink(dir + '/' + e);
				}
			}
		}
		fs.rmdir(dir);
	}
	return true;
}

/**
 * Checks whether a secret file exists
 */
function has_secret(id, name) {
	if (!is_valid_id(id) || !is_valid_name(name)) return false;
	let base = get_base_dir();
	return (fs.stat(base + '/' + id + '/' + name) != null);
}

/**
 * Returns path to secret file
 */
function get_secret_path(id, name) {
	if (!is_valid_id(id) || !is_valid_name(name)) return null;
	let base = get_base_dir();
	return base + '/' + id + '/' + name;
}

/**
 * Returns path to WireGuard private key file (checked in credentials or profile dir)
 */
function get_wg_key_path(id) {
	if (!is_valid_id(id)) return null;
	let base = get_base_dir();
	let cpath = base + '/' + id + '/wg.key';
	if (fs.stat(cpath)) return cpath;
	let prof_dir = getenv('GEOVPN_PROFILES_DIR') || '/etc/geovpn/profiles';
	let ppath = prof_dir + '/' + id + '/wg.key';
	if (fs.stat(ppath)) return ppath;
	return cpath;
}

/**
 * Returns path to WireGuard PSK file (checked in credentials or profile dir)
 */
function get_wg_psk_path(id) {
	if (!is_valid_id(id)) return null;
	let base = get_base_dir();
	let cpath = base + '/' + id + '/wg.psk';
	if (fs.stat(cpath)) return cpath;
	let prof_dir = getenv('GEOVPN_PROFILES_DIR') || '/etc/geovpn/profiles';
	let ppath = prof_dir + '/' + id + '/wg.psk';
	if (fs.stat(ppath)) return ppath;
	return cpath;
}

/**
 * Stores WireGuard private key and optional preshared key into 0600 files
 */
function store_wg_keys(id, private_key, psk) {
	if (!is_valid_id(id)) return false;
	let ok = store_secret(id, 'wg.key', private_key);
	if (!ok) return false;
	if (psk && length(psk) > 0) {
		store_secret(id, 'wg.psk', psk);
	}
	return true;
}

/**
 * Stores username and password in auth file (line 1: user, line 2: password) mode 0600
 */
function store_userpass(id, username, password) {
	if (!is_valid_id(id)) return false;
	let content = sprintf('%s\n%s\n', username || '', password || '');
	return store_secret(id, 'auth', content);
}

/**
 * Loads username and password from auth file
 */
function load_userpass(id) {
	let raw = load_secret(id, 'auth');
	if (!raw) return null;
	let lines = split(raw, '\n');
	return {
		username: (length(lines) >= 1) ? lines[0] : '',
		password: (length(lines) >= 2) ? lines[1] : ''
	};
}

/**
 * Lists credential summaries without disclosing any secret content
 */
function list_credentials() {
	let base = get_base_dir();
	if (!fs.stat(base)) return [];
	let entries = fs.lsdir(base);
	if (!entries) return [];
	let results = [];
	for (let e in entries) {
		if (e != '.' && e != '..' && is_valid_id(e)) {
			let cdir = base + '/' + e;
			let files = [];
			let files_raw = fs.lsdir(cdir);
			if (files_raw) {
				for (let f in files_raw) {
					if (f != '.' && f != '..') push(files, f);
				}
			}
			push(results, {
				id: e,
				has_auth: (fs.stat(cdir + '/auth') != null),
				has_wg_key: (fs.stat(cdir + '/wg.key') != null),
				has_wg_psk: (fs.stat(cdir + '/wg.psk') != null),
				files: files
			});
		}
	}
	return results;
}

/**
 * Scrubs all secrets from text for logging or display
 */
function scrub_secrets(text) {
	return util.scrub_secrets(text);
}

function get_userpass(id) {
	return load_userpass(id);
}

export {
	CRED_BASE_DIR,
	is_valid_id,
	is_valid_name,
	ensure_cred_dir,
	store_secret,
	load_secret,
	delete_secret,
	delete_credential,
	has_secret,
	get_secret_path,
	get_wg_key_path,
	get_wg_psk_path,
	store_wg_keys,
	store_userpass,
	load_userpass,
	get_userpass,
	list_credentials,
	scrub_secrets
};
