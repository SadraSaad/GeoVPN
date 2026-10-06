//
// GeoVPN Utility and Validation Library
//
'use strict';

import * as fs from 'fs';

const RE_IFNAME = /^[A-Za-z0-9_.@-]{1,15}$/;
const RE_PROFILE_ID = /^p[0-9a-f]{8}$/;
const RE_CATEGORY = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const RE_GEOSITE = /^[a-z0-9][a-z0-9@._-]{0,63}$/;
const RE_MAC = /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/;
const RE_PORT = /^[0-9]{1,5}$/;
const RE_TIMEOUT = /^[0-9]{1,4}[smhd]$/;
const RE_CRON = /^[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+$/;

function is_ifname(s) {
	return (type(s) == 'string' && match(s, RE_IFNAME) != null);
}

function is_profile_id(s) {
	return (type(s) == 'string' && match(s, RE_PROFILE_ID) != null);
}

function is_category_code(s) {
	return (type(s) == 'string' && match(s, RE_CATEGORY) != null);
}

function is_geosite_name(s) {
	return (type(s) == 'string' && match(s, RE_GEOSITE) != null);
}

function is_mac(s) {
	return (type(s) == 'string' && match(s, RE_MAC) != null);
}

function is_port(n) {
	let num = +n;
	return (num >= 1 && num <= 65535);
}

function is_dyn_timeout(s) {
	return (type(s) == 'string' && match(s, RE_TIMEOUT) != null);
}

function is_cron_expr(s) {
	return (type(s) == 'string' && match(s, RE_CRON) != null);
}

function is_ipv4(s) {
	if (type(s) != 'string') return false;
	let parts = split(s, '.');
	if (length(parts) != 4) return false;
	for (let p in parts) {
		if (match(p, /^[0-9]{1,3}$/) == null) return false;
		let n = +p;
		if (n < 0 || n > 255) return false;
		if (length(p) > 1 && substr(p, 0, 1) == '0') return false;
	}
	return true;
}

function is_ipv6(s) {
	if (type(s) != 'string') return false;
	if (length(s) < 2 || length(s) > 39) return false;
	if (match(s, /^[0-9a-fA-F:]+$/) == null) return false;
	let colons = split(s, ':');
	if (length(colons) < 3 || length(colons) > 8) return false;
	return true;
}

function is_ip(s) {
	return is_ipv4(s) || is_ipv6(s);
}

function is_cidr4(s) {
	if (type(s) != 'string') return false;
	let parts = split(s, '/');
	if (length(parts) != 2) return false;
	if (!is_ipv4(parts[0])) return false;
	if (match(parts[1], /^[0-9]{1,2}$/) == null) return false;
	let prefix = +parts[1];
	return (prefix >= 0 && prefix <= 32);
}

function is_cidr6(s) {
	if (type(s) != 'string') return false;
	let parts = split(s, '/');
	if (length(parts) != 2) return false;
	if (!is_ipv6(parts[0])) return false;
	if (match(parts[1], /^[0-9]{1,3}$/) == null) return false;
	let prefix = +parts[1];
	return (prefix >= 0 && prefix <= 128);
}

function is_cidr(s) {
	return is_cidr4(s) || is_cidr6(s);
}

function is_domain(s) {
	if (type(s) != 'string') return false;
	if (is_ipv4(s)) return false;
	if (length(s) < 1 || length(s) > 253) return false;
	// Suffix normalized: strip leading '.' if present
	if (substr(s, 0, 1) == '.') s = substr(s, 1);
	let labels = split(s, '.');
	if (length(labels) < 1) return false;
	for (let label in labels) {
		if (length(label) < 1 || length(label) > 63) return false;
		if (match(label, /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/) == null) return false;
	}
	return true;
}

function is_hostname(s) {
	return is_domain(s) || is_ip(s);
}

function is_url(s) {
	if (type(s) != 'string') return false;
	if (substr(s, 0, 8) != 'https://') return false;
	if (match(s, /^https:\/\/[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+$/) == null) return false;
	if (index(s, '127.0.0.1') != -1 || index(s, 'localhost') != -1 || index(s, '169.254.') != -1) {
		return false;
	}
	return true;
}

function is_pem_block(text, tag) {
	if (type(text) != 'string' || length(text) > 65536) return false;
	let header = '-----BEGIN ' + tag + '-----';
	let footer = '-----END ' + tag + '-----';
	let start_pos = index(text, header);
	let end_pos = index(text, footer);
	if (start_pos == -1 || end_pos == -1 || end_pos <= start_pos) return false;
	let body = substr(text, start_pos + length(header), end_pos - (start_pos + length(header)));
	return (match(body, /^[A-Za-z0-9+/=\r\n\s]+$/) != null);
}

function safe_path(base_dir, sub_path) {
	if (type(sub_path) != 'string' || length(sub_path) == 0) return null;
	if (index(sub_path, '..') != -1 || substr(sub_path, 0, 1) == '/') return null;
	let clean = match(sub_path, /^[a-zA-Z0-9_.-]+(\/[a-zA-Z0-9_.-]+)*$/);
	if (!clean) return null;
	return base_dir + '/' + sub_path;
}

function scrub_secrets(text) {
	if (type(text) != 'string') return '';
	let scrubbed = text;
	scrubbed = replace(scrubbed, /-----BEGIN [A-Z0-9 _-]+-----[\s\S]*?-----END [A-Z0-9 _-]+-----/g, '[REDACTED PEM BLOCK]');
	scrubbed = replace(scrubbed, /password\s+[^\r\n]+/gi, 'password [REDACTED]');
	scrubbed = replace(scrubbed, /auth-user-pass\s+[^\r\n]+/gi, 'auth-user-pass [REDACTED]');
	return scrubbed;
}

function argv_to_cmd(argv) {
	if (type(argv) == 'string') return argv;
	if (type(argv) != 'array') return '';
	let cmd = [];
	for (let arg in argv) {
		let s = '' + arg;
		if (match(s, /^[a-zA-Z0-9_.\/=+-]+$/)) {
			push(cmd, s);
		} else {
			push(cmd, "'" + replace(s, /'/g, "'\\''") + "'");
		}
	}
	return join(' ', cmd);
}

function safe_exec(argv, input_data) {
	if (type(argv) != 'array' && type(argv) != 'string') {
		return { code: -1, stdout: '', stderr: 'Invalid argv' };
	}
	let cmd_str = (type(argv) == 'array') ? argv_to_cmd(argv) : argv;
	if (length(cmd_str) == 0) {
		return { code: -1, stdout: '', stderr: 'Empty command' };
	}

	let proc = fs.popen(cmd_str, input_data ? 'r+' : 'r');
	if (!proc) return { code: -1, stdout: '', stderr: 'Failed to spawn process' };
	if (input_data) {
		proc.write(input_data);
	}
	let out = proc.read('all') || '';
	let status = proc.close();
	return { code: status, stdout: out, stderr: '' };
}

function log(level, msg) {
	let tag = '[geovpn]';
	let line = sprintf('%s %s: %s\n', tag, uc(level), scrub_secrets(msg));
	fs.stderr.write(line);
}

export {
	is_ifname,
	is_profile_id,
	is_category_code,
	is_geosite_name,
	is_mac,
	is_port,
	is_dyn_timeout,
	is_cron_expr,
	is_ipv4,
	is_ipv6,
	is_ip,
	is_cidr4,
	is_cidr6,
	is_cidr,
	is_domain,
	is_hostname,
	is_url,
	is_pem_block,
	safe_path,
	scrub_secrets,
	safe_exec,
	log
};
