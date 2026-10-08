//
// GeoVPN WireGuard Config Parser (.conf) with Strict Allowlist (§5.3.2 / FR-31 / AT-24)
//
'use strict';

import * as util from './util.uc';
import * as cred from './cred.uc';

const MAX_CONFIG_SIZE = 131072; // 128 KB limit
const MAX_LINE_LEN = 4096;

// Obfuscation directives (e.g. AmneziaWG) explicitly rejected (VA-15)
const AMNEZIA_DIRECTIVES = {
	'jc': true,
	'jmin': true,
	'jmax': true,
	's1': true,
	's2': true,
	'h1': true,
	'h2': true,
	'h3': true,
	'h4': true
};

/**
 * Parses a WireGuard .conf INI formatted string into a normalized profile object.
 * Enforces single peer, base64 32B key validation, default route coverage,
 * and rejection of shell hooks and unsupported obfuscation parameters.
 *
 * @param {string} content - Raw WireGuard configuration file content
 * @param {string} [profile_name] - Human-friendly profile name
 * @param {object} [opts] - Optional parsing options (e.g. cred)
 * @returns {object} { ok: true, profile: {...} } or { ok: false, error: '...' }
 */
function parse_wireguard(content, profile_name, opts) {
	if (type(content) != 'string') {
		return { ok: false, error: 'Content must be string' };
	}
	if (length(content) > MAX_CONFIG_SIZE) {
		return { ok: false, error: 'Config size exceeds 128 KB limit' };
	}
	if (index(content, '\0') != -1) {
		return { ok: false, error: 'Binary NUL character detected in configuration' };
	}

	// Strip UTF-8 BOM if present
	if (substr(content, 0, 3) == '\xef\xbb\xbf') {
		content = substr(content, 3);
	} else if (substr(content, 0, 1) == '\ufeff') {
		content = substr(content, 1);
	}

	let lines = split(replace(content, /\r\n?/g, '\n'), '\n');

	let interface_count = 0;
	let peer_count = 0;
	let current_section = null;

	let profile = {
		proto: 'wireguard',
		name: profile_name || 'WireGuard Profile',
		provider: '',
		wg_address: [],
		wg_dns: [],
		wg_allowed_ips: [],
		wg_endpoint_host: '',
		wg_endpoint_port: null,
		wg_public_key: '',
		private_key: '',
		preshared_key: '',
		wg_has_psk: '0',
		wg_mtu: null,
		wg_keepalive: null,
		wg_allow_partial: '0',
		warnings: [],
		ignored: []
	};

	for (let line_idx = 0; line_idx < length(lines); line_idx++) {
		let raw_line = lines[line_idx];
		if (length(raw_line) > MAX_LINE_LEN) {
			return { ok: false, error: sprintf('Line %d exceeds 4096 character limit', line_idx + 1) };
		}

		// Strip inline and line comments (# and ;)
		let clean_line = raw_line;
		let hash_idx = index(clean_line, '#');
		let semi_idx = index(clean_line, ';');
		let comment_idx = -1;
		if (hash_idx != -1 && (semi_idx == -1 || hash_idx < semi_idx)) {
			comment_idx = hash_idx;
		} else if (semi_idx != -1) {
			comment_idx = semi_idx;
		}
		if (comment_idx != -1) {
			clean_line = substr(clean_line, 0, comment_idx);
		}
		clean_line = trim(clean_line);
		if (length(clean_line) == 0) continue;

		// Section header matching
		if (match(clean_line, /^\[\s*interface\s*\]$/i)) {
			interface_count++;
			if (interface_count > 1) {
				return { ok: false, error: 'Multiple [Interface] sections are not supported' };
			}
			current_section = 'interface';
			continue;
		}
		if (match(clean_line, /^\[\s*peer\s*\]$/i)) {
			peer_count++;
			if (peer_count > 1) {
				return { ok: false, error: 'Multiple [Peer] sections are not supported: single-peer profiles only' };
			}
			current_section = 'peer';
			continue;
		}
		if (match(clean_line, /^\[.+\]$/)) {
			return { ok: false, error: sprintf("Unsupported section '%s': only [Interface] and [Peer] are permitted", clean_line) };
		}

		// Key-Value parsing
		let eq_idx = index(clean_line, '=');
		if (eq_idx == -1) {
			return { ok: false, error: sprintf("Invalid line %d: missing '=' delimiter", line_idx + 1) };
		}
		let key = lc(trim(substr(clean_line, 0, eq_idx)));
		let val = trim(substr(clean_line, eq_idx + 1));

		if (!current_section) {
			return { ok: false, error: sprintf("Directive '%s' found outside of [Interface] or [Peer] section", key) };
		}

		// Check for AmneziaWG obfuscation parameters
		if (AMNEZIA_DIRECTIVES[key]) {
			return { ok: false, error: sprintf("Obfuscation parameters (%s) are not supported by kernel WireGuard", key) };
		}

		if (current_section == 'interface') {
			if (key == 'privatekey') {
				if (profile.private_key) {
					return { ok: false, error: 'Duplicate PrivateKey directive in [Interface]' };
				}
				if (!util.is_wireguard_key(val)) {
					return { ok: false, error: 'Invalid PrivateKey in [Interface]: must be 32-byte base64 string' };
				}
				profile.private_key = val;
			} else if (key == 'address') {
				let parts = split(val, ',');
				for (let p in parts) {
					let addr = trim(p);
					if (length(addr) == 0) continue;
					if (!util.is_cidr(addr)) {
						return { ok: false, error: sprintf("Invalid Address '%s': must be valid IPv4 or IPv6 CIDR prefix", addr) };
					}
					push(profile.wg_address, addr);
				}
			} else if (key == 'dns') {
				let parts = split(val, ',');
				for (let p in parts) {
					let d = trim(p);
					if (length(d) == 0) continue;
					if (util.is_ip(d)) {
						push(profile.wg_dns, d);
					} else {
						push(profile.warnings, sprintf("Ignored non-IP DNS search entry '%s'", d));
					}
				}
			} else if (key == 'mtu') {
				if (profile.wg_mtu != null) {
					return { ok: false, error: 'Duplicate MTU directive in [Interface]' };
				}
				if (match(val, /^[0-9]+$/) == null) {
					return { ok: false, error: sprintf("Invalid MTU '%s': must be numeric", val) };
				}
				let mtu = +val;
				if (mtu < 1280 || mtu > 1500) {
					return { ok: false, error: sprintf('MTU %d out of valid range 1280-1500', mtu) };
				}
				profile.wg_mtu = mtu;
			} else if (key == 'listenport' || key == 'fwmark' || key == 'table' || key == 'saveconfig') {
				push(profile.ignored, { directive: key, reason: 'kernel picks port; marks and routes are managed by GeoVPN' });
			} else if (key == 'preup' || key == 'postup' || key == 'predown' || key == 'postdown') {
				return { ok: false, error: sprintf("Shell hook '%s' is not permitted for security reasons (arbitrary command execution)", key) };
			} else {
				return { ok: false, error: sprintf("Unknown directive '%s' in [Interface] is not supported", key) };
			}
		} else if (current_section == 'peer') {
			if (key == 'publickey') {
				if (profile.wg_public_key) {
					return { ok: false, error: 'Duplicate PublicKey directive in [Peer]' };
				}
				if (!util.is_wireguard_key(val)) {
					return { ok: false, error: 'Invalid PublicKey in [Peer]: must be 32-byte base64 string' };
				}
				profile.wg_public_key = val;
			} else if (key == 'presharedkey') {
				if (profile.preshared_key) {
					return { ok: false, error: 'Duplicate PresharedKey directive in [Peer]' };
				}
				if (!util.is_wireguard_key(val)) {
					return { ok: false, error: 'Invalid PresharedKey in [Peer]: must be 32-byte base64 string' };
				}
				profile.preshared_key = val;
				profile.wg_has_psk = '1';
			} else if (key == 'endpoint') {
				if (profile.wg_endpoint_host) {
					return { ok: false, error: 'Duplicate Endpoint directive in [Peer]' };
				}
				let host = '';
				let port = '';
				if (substr(val, 0, 1) == '[') {
					let end_bracket = index(val, ']');
					if (end_bracket == -1 || substr(val, end_bracket + 1, 1) != ':') {
						return { ok: false, error: sprintf("Invalid IPv6 endpoint syntax: '%s'", val) };
					}
					host = substr(val, 1, end_bracket - 1);
					port = substr(val, end_bracket + 2);
				} else {
					let colon = rindex(val, ':');
					if (colon == -1) {
						return { ok: false, error: sprintf("Invalid Endpoint '%s': missing port delimiter", val) };
					}
					host = substr(val, 0, colon);
					port = substr(val, colon + 1);
				}
				if (!util.is_hostname(host) || !util.is_port(port)) {
					return { ok: false, error: sprintf("Invalid Endpoint '%s': must be valid host:port", val) };
				}
				profile.wg_endpoint_host = host;
				profile.wg_endpoint_port = +port;
			} else if (key == 'allowedips') {
				let parts = split(val, ',');
				for (let p in parts) {
					let cidr = trim(p);
					if (length(cidr) == 0) continue;
					if (!util.is_cidr(cidr)) {
						return { ok: false, error: sprintf("Invalid AllowedIPs CIDR '%s'", cidr) };
					}
					push(profile.wg_allowed_ips, cidr);
				}
			} else if (key == 'persistentkeepalive') {
				if (profile.wg_keepalive != null) {
					return { ok: false, error: 'Duplicate PersistentKeepalive directive in [Peer]' };
				}
				if (match(val, /^[0-9]+$/) == null) {
					return { ok: false, error: sprintf("Invalid PersistentKeepalive '%s': must be integer 0-600", val) };
				}
				let ka = +val;
				if (ka < 0 || ka > 600) {
					return { ok: false, error: sprintf('PersistentKeepalive %d out of valid range 0-600', ka) };
				}
				profile.wg_keepalive = ka;
			} else {
				return { ok: false, error: sprintf("Unknown directive '%s' in [Peer] is not supported", key) };
			}
		}
	}

	// Structural completeness checks
	if (interface_count == 0) {
		return { ok: false, error: 'Missing [Interface] section in configuration' };
	}
	if (peer_count == 0) {
		return { ok: false, error: 'Missing [Peer] section in configuration' };
	}
	if (!profile.private_key || length(profile.private_key) == 0) {
		let cred_id = (opts && (opts.cred || opts.cred_id)) ? (opts.cred || opts.cred_id) : null;
		if (cred_id && cred.is_valid_id(cred_id) && cred.has_secret(cred_id, 'wg.key')) {
			profile.private_key = cred.load_secret(cred_id, 'wg.key') || '';
			profile.cred = cred_id;
		} else {
			return { ok: false, error: 'Missing PrivateKey in [Interface]' };
		}
	}
	if (length(profile.wg_address) == 0) {
		return { ok: false, error: 'Missing Address in [Interface]' };
	}
	if (!profile.wg_public_key || length(profile.wg_public_key) == 0) {
		return { ok: false, error: 'Missing PublicKey in [Peer]' };
	}
	if (!profile.wg_endpoint_host || !profile.wg_endpoint_port) {
		return { ok: false, error: 'Missing Endpoint in [Peer]' };
	}
	if (length(profile.wg_allowed_ips) == 0) {
		return { ok: false, error: 'Missing AllowedIPs in [Peer]' };
	}

	// Enforce default route coverage (AllowedIPs must include 0.0.0.0/0 or ::/0)
	let has_default = false;
	for (let a in profile.wg_allowed_ips) {
		if (a == '0.0.0.0/0' || a == '::/0') {
			has_default = true;
			break;
		}
	}
	if (!has_default && profile.wg_allow_partial != '1') {
		return {
			ok: false,
			error: "AllowedIPs doesn't cover 0.0.0.0/0 or ::/0: GeoVPN routes the tunnel as a default route; narrow AllowedIPs would drop traffic"
		};
	}

	// Apply default values if not specified in file
	if (profile.wg_mtu == null) {
		profile.wg_mtu = 1420;
	}
	if (profile.wg_keepalive == null) {
		profile.wg_keepalive = 25;
	}

	// Provider detection (Windscribe fingerprints)
	if (index(profile.wg_endpoint_host, '.windscribe.com') != -1) {
		profile.provider = 'windscribe';
	}
	for (let d in profile.wg_dns) {
		if (d == '10.255.255.3') {
			profile.provider = 'windscribe';
			break;
		}
	}
	if (profile.provider == 'windscribe') {
		push(profile.warnings, 'keys are tied to this location; regenerate the config in your Windscribe account (Config Generators) if the handshake never completes');
	}

	return {
		ok: true,
		profile: profile
	};
}

export {
	parse_wireguard
};
