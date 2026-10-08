//
// GeoVPN IKEv2 / strongSwan Profile Importer (§5.2, §5.4, §6.6 / FR-32)
// Supports strongSwan Android .sswan (JSON) format and smart-paste grammar.
//
'use strict';

import * as fs from 'fs';
import * as util from './util.uc';

const MAX_CONFIG_SIZE = 65536; // 64 KB

/**
 * Parses strongSwan Android .sswan JSON profile
 */
function parse_sswan(content, default_name) {
	if (type(content) != 'string' || length(content) == 0) {
		return { ok: false, error: 'Empty content' };
	}
	if (length(content) > MAX_CONFIG_SIZE) {
		return { ok: false, error: 'Configuration exceeds size limit' };
	}
	if (index(content, '\0') != -1) {
		return { ok: false, error: 'NUL byte detected in profile' };
	}

	let c = content;
	if (substr(c, 0, 3) == '\xef\xbb\xbf') c = substr(c, 3);
	else if (substr(c, 0, 1) == '\ufeff') c = substr(c, 1);

	let doc = null;
	try {
		doc = json(c);
	} catch (e) {
		return { ok: false, error: 'Invalid JSON syntax: ' + e };
	}

	if (!doc || type(doc) != 'object') {
		return { ok: false, error: 'Root JSON entity must be an object' };
	}

	let remote_addr = '';
	let remote_id = '';
	if (doc.remote && type(doc.remote) == 'object') {
		remote_addr = trim(doc.remote.addr || doc.remote.address || doc.remote.host || '');
		remote_id = trim(doc.remote.id || doc.remote.identity || '');
	}

	if (!remote_addr && doc.remote_addr) remote_addr = trim(doc.remote_addr);
	if (!remote_addr && doc.server) remote_addr = trim(doc.server);
	if (!remote_addr && doc.address) remote_addr = trim(doc.address);

	if (!remote_addr || length(remote_addr) == 0) {
		return { ok: false, error: 'Missing remote server address (remote.addr)' };
	}

	let eap_id = '';
	if (doc.local && type(doc.local) == 'object') {
		eap_id = trim(doc.local.eap_id || doc.local.id || '');
	}
	if (!eap_id && doc.authentication && doc.authentication.username) eap_id = trim(doc.authentication.username);
	if (!eap_id && doc.username) eap_id = trim(doc.username);

	let pass = trim(doc.password || (doc.authentication ? doc.authentication.password : '') || '');

	let prof_name = trim(doc.name || default_name || remote_addr);
	let auth_type = 'eap-mschapv2';
	if (doc.type && doc.type != 'ikev2-eap') {
		auth_type = 'pubkey';
	}

	let warnings = [];
	if (!pass) {
		push(warnings, 'strongSwan .sswan profile imported; password is required (not stored in .sswan)');
	}

	let prof = {
		name: prof_name,
		proto: 'ikev2',
		ike_host: remote_addr,
		ike_remote_id: remote_id || remote_addr,
		ike_auth: auth_type,
		ike_username: eap_id,
		password: pass || null,
		ike_ca: (doc.remote && doc.remote.cert) ? doc.remote.cert : 'geovpn-isrg-x1.pem',
		ike_dpd: 30,
		ike_mobike: '0',
		ike_fragmentation: '1',
		ike_if_id: '4200',
		needs_credentials: !pass,
		warnings: warnings,
		notices: [],
		ignored: [],
		incomplete: pass ? [] : ['password']
	};

	return { ok: true, profile: prof, needs_password: !pass };
}

/**
 * Parses smart-paste format (key:value, URI, or whitespace-delimited triple)
 */
function parse_smart_paste(content, default_name) {
	if (type(content) != 'string' || length(content) == 0) {
		return { ok: false, error: 'Empty content' };
	}
	if (length(content) > MAX_CONFIG_SIZE) {
		return { ok: false, error: 'Configuration exceeds size limit' };
	}
	if (index(content, '\0') != -1) {
		return { ok: false, error: 'NUL byte detected in profile' };
	}

	let c = trim(content);
	if (substr(c, 0, 3) == '\xef\xbb\xbf') c = substr(c, 3);
	else if (substr(c, 0, 1) == '\ufeff') c = substr(c, 1);

	let host = '';
	let user = '';
	let pass = '';
	let remote_id = '';
	let ca = 'geovpn-isrg-x1.pem';

	// Case 1: URI ikev2://[user[:pass]@]host[:port]
	if (match(c, /^ikev2:\/\//i)) {
		let uri_body = substr(c, 8);
		let at_idx = index(uri_body, '@');
		let host_part = uri_body;
		if (at_idx != -1) {
			let userinfo = substr(uri_body, 0, at_idx);
			host_part = substr(uri_body, at_idx + 1);
			let colon_idx = index(userinfo, ':');
			if (colon_idx != -1) {
				user = substr(userinfo, 0, colon_idx);
				pass = substr(userinfo, colon_idx + 1);
			} else {
				user = userinfo;
			}
		}
		let slash_idx = index(host_part, '/');
		if (slash_idx != -1) host_part = substr(host_part, 0, slash_idx);
		let hcolon = rindex(host_part, ':');
		if (hcolon != -1 && !index(host_part, ']')) {
			host = substr(host_part, 0, hcolon);
		} else {
			host = host_part;
		}
	} else {
		// Case 2: key-value lines
		let lines = split(c, '\n');
		let kv_found = false;
		for (let line in lines) {
			let l = trim(line);
			if (!l || substr(l, 0, 1) == '#' || substr(l, 0, 1) == ';') continue;
			let col = index(l, ':');
			let eq = index(l, '=');
			let sep = (col != -1 && (eq == -1 || col < eq)) ? col : eq;
			if (sep != -1) {
				let k = lc(trim(substr(l, 0, sep)));
				let v = trim(substr(l, sep + 1));
				if (k == 'host' || k == 'server' || k == 'gateway' || k == 'remote') {
					host = v; kv_found = true;
				} else if (k == 'user' || k == 'username' || k == 'eap_id' || k == 'account') {
					user = v; kv_found = true;
				} else if (k == 'pass' || k == 'password' || k == 'secret') {
					pass = v; kv_found = true;
				} else if (k == 'remote_id' || k == 'id') {
					remote_id = v; kv_found = true;
				} else if (k == 'ca' || k == 'cacert' || k == 'cert') {
					ca = v; kv_found = true;
				}
			}
		}

		// Case 3: single-line whitespace triple: <host> <user> <pass>
		if (!kv_found && length(lines) >= 1) {
			let tokens = split(trim(lines[0]), /[ \t]+/);
			if (length(tokens) >= 1 && util.is_hostname(tokens[0])) {
				host = tokens[0];
				if (length(tokens) >= 2) user = tokens[1];
				if (length(tokens) >= 3) pass = tokens[2];
			}
		}
	}

	if (!host || length(host) == 0) {
		return { ok: false, error: 'Could not extract remote host from IKEv2 input' };
	}

	let prof_name = default_name || host;
	let needs_cred = (!pass || length(pass) == 0);

	let prof = {
		name: prof_name,
		proto: 'ikev2',
		ike_host: host,
		ike_remote_id: remote_id || host,
		ike_auth: 'eap-mschapv2',
		ike_username: user,
		ike_ca: ca,
		ike_dpd: 30,
		ike_mobike: '0',
		ike_fragmentation: '1',
		ike_if_id: '4200',
		password: pass || '',
		needs_credentials: needs_cred,
		warnings: needs_cred ? ['Password not provided; credential must be supplied before connect'] : [],
		notices: [],
		ignored: [],
		incomplete: needs_cred ? ['password'] : []
	};

	return { ok: true, profile: prof, password: pass };
}

/**
 * Universal dispatcher sniffing between .sswan JSON and smart paste
 */
function parse_ikev2(content, default_name, opts) {
	if (type(content) != 'string') return { ok: false, error: 'Invalid content type' };
	let trimmed = trim(content);
	if (substr(trimmed, 0, 1) == '{') {
		let res = parse_sswan(trimmed, default_name);
		if (res && res.ok) return res;
	}
	return parse_smart_paste(trimmed, default_name);
}

export {
	parse_sswan,
	parse_smart_paste,
	parse_ikev2
};
