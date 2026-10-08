//
// GeoVPN OpenVPN Config Parser (.ovpn) with Strict Allowlist
//
'use strict';

import * as util from './util.uc';

const MAX_CONFIG_SIZE = 131072; // 128 KB
const MAX_LINE_LEN = 4096;
const MAX_REMOTES = 64;

// Denied directives that execute scripts, spawn processes, or touch arbitrary paths
const DENIED_DIRECTIVES = {
	'up': 'executes arbitrary external script',
	'down': 'executes arbitrary external script',
	'route-up': 'executes arbitrary external script',
	'route-pre-down': 'executes arbitrary external script',
	'up-delay': 'script execution delay option',
	'tls-verify': 'executes arbitrary verification command',
	'ipchange': 'executes arbitrary script on IP change',
	'learn-address': 'executes script on address learning',
	'client-connect': 'executes script on connection',
	'client-disconnect': 'executes script on disconnect',
	'auth-user-pass-verify': 'executes verification script',
	'plugin': 'loads arbitrary binary plugin',
	'script-security': 'script security override not permitted in profile',
	'management': 'management interface configuration',
	'management-client': 'management interface client',
	'management-query-passwords': 'management interface password option',
	'management-hold': 'management interface option',
	'daemon': 'daemonization managed by procd',
	'log': 'arbitrary log path not allowed',
	'log-append': 'arbitrary log path not allowed',
	'syslog': 'syslog managed by GeoVPN',
	'writepid': 'pid file managed by procd',
	'status': 'status file path not allowed',
	'status-version': 'status option not allowed',
	'cd': 'working directory change not allowed',
	'chroot': 'chroot directive not allowed',
	'setcon': 'SELinux context change not allowed',
	'config': 'nested config inclusion not allowed',
	'askpass': 'external askpass helper not allowed',
	'ifconfig-noexec': 'ifconfig execution modifier not allowed',
	'route-noexec': 'route execution modifier not allowed',
	'iproute': 'custom iproute binary not allowed',
	'engine': 'OpenSSL engine selection not allowed',
	'providers': 'OpenSSL provider selection not allowed',
	'echo': 'echo directive not allowed',
	'lladdr': 'link-layer address modification not allowed',
	'bind-dev': 'bind device modification not allowed',
	'mark': 'socket mark modification not allowed',
	'setenv': 'custom environment variable injection not allowed',
	'dev-node': 'custom dev node not allowed',
	'genkey': 'key generation not allowed in client profile',
	'secret': 'static key secret file not allowed'
};

const ROUTING_DIRECTIVES = {
	'redirect-gateway': 'routing is managed by GeoVPN split tunnel',
	'route': 'routing is managed by GeoVPN split tunnel',
	'route-ipv6': 'routing is managed by GeoVPN split tunnel',
	'route-metric': 'routing is managed by GeoVPN split tunnel',
	'route-delay': 'routing is managed by GeoVPN split tunnel',
	'route-gateway': 'routing is managed by GeoVPN split tunnel',
	'dhcp-option': 'DNS and DHCP options managed by GeoVPN DNS layer',
	'block-outside-dns': 'DNS protection managed by GeoVPN DNS layer',
	'ifconfig': 'tunnel IP configuration managed by server push',
	'ifconfig-ipv6': 'tunnel IPv6 configuration managed by server push'
};

const INLINE_TAGS = [
	'ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2',
	'extra-certs', 'crl-verify', 'peer-fingerprint'
];

function tokenize_line(line) {
	let chars = split(line, '');
	let len = length(chars);
	let tokens = [];
	let i = 0;
	while (i < len) {
		// Skip whitespace
		while (i < len && (chars[i] == ' ' || chars[i] == '\t')) {
			i++;
		}
		if (i >= len) break;
		if (chars[i] == '#' || chars[i] == ';') {
			break; // Comment to end of line
		}
		let token = '';
		if (chars[i] == '"' || chars[i] == "'") {
			let quote = chars[i];
			i++;
			while (i < len && chars[i] != quote) {
				if (chars[i] == '\\' && i + 1 < len) {
					token += chars[i + 1];
					i += 2;
				} else {
					token += chars[i];
					i++;
				}
			}
			if (i < len && chars[i] == quote) i++;
		} else {
			while (i < len && chars[i] != ' ' && chars[i] != '\t' && chars[i] != '#' && chars[i] != ';') {
				if (chars[i] == '\\' && i + 1 < len) {
					token += chars[i + 1];
					i += 2;
				} else {
					token += chars[i];
					i++;
				}
			}
		}
		if (length(token) > 0) {
			push(tokens, token);
		}
	}
	return tokens;
}

function parse_ovpn(content, profile_name) {
	if (type(content) != 'string') {
		return { ok: false, error: 'Content must be string' };
	}
	if (length(content) > MAX_CONFIG_SIZE) {
		return { ok: false, error: 'Config size exceeds 128 KB limit' };
	}

	if (index(content, '\0') != -1) {
		return { ok: false, error: 'Config contains NUL byte' };
	}

	// Remove UTF-8 BOM if present
	if (substr(content, 0, 3) == '\xef\xbb\xbf') {
		content = substr(content, 3);
	}

	// Normalize CRLF to LF
	content = replace(content, /\r\n/g, '\n');
	content = replace(content, /\r/g, '\n');

	let lines = split(content, '\n');
	let profile = {
		name: profile_name || 'Imported Profile',
		remotes: [],
		auth_user_pass: false,
		tls_kind: 'none',
		key_direction: '',
		cipher: '',
		data_ciphers: '',
		data_ciphers_fallback: '',
		auth: '',
		tls_version_min: '',
		verify_x509_name: '',
		peer_fingerprint: '',
		remote_cert_tls: 'server',
		mssfix: 1450,
		tun_mtu: 1500,
		keepalive: '',
		compress: 'none',
		proto: 'openvpn',
		provider: '',
		ping: '',
		ping_restart: '',
		ping_exit: '',
		explicit_exit_notify: '',
		extra: [],
		materials: {},
		ignored: [],
		warnings: [],
		incomplete: []
	};

	let in_tag = null;
	let tag_content = '';

	for (let line_num = 0; line_num < length(lines); line_num++) {
		let line = lines[line_num];
		if (length(line) > MAX_LINE_LEN) {
			push(profile.warnings, sprintf('Line %d exceeds 4096 characters (truncated)', line_num + 1));
			line = substr(line, 0, MAX_LINE_LEN);
		}

		let trimmed = replace(line, /^\s+|\s+$/g, '');

		// Handle inline tag blocks
		if (in_tag) {
			let close_tag = sprintf('</%s>', in_tag);
			if (trimmed == close_tag) {
				profile.materials[in_tag] = tag_content;
				in_tag = null;
				tag_content = '';
			} else {
				tag_content += line + '\n';
				if (length(tag_content) > 65536) {
					return { ok: false, error: sprintf('Inline <%s> block exceeds 64 KB limit', in_tag) };
				}
			}
			continue;
		}

		// Check opening inline tag
		let open_tag_match = match(trimmed, /^<([a-z0-9_-]+)>$/);
		if (open_tag_match) {
			let tag_name = open_tag_match[1];
			let found = false;
			for (let allowed_tag in INLINE_TAGS) {
				if (allowed_tag == tag_name) {
					found = true;
					break;
				}
			}
			if (found) {
				in_tag = tag_name;
				tag_content = '';
				continue;
			} else {
				push(profile.ignored, { directive: trimmed, reason: 'unknown inline tag' });
				continue;
			}
		}

		if (length(trimmed) == 0 || substr(trimmed, 0, 1) == '#' || substr(trimmed, 0, 1) == ';') {
			continue;
		}

		let tokens = tokenize_line(trimmed);
		if (length(tokens) == 0) continue;

		let cmd = lc(tokens[0]);

		// Check denied commands
		if (DENIED_DIRECTIVES[cmd]) {
			push(profile.ignored, { directive: trimmed, reason: DENIED_DIRECTIVES[cmd] });
			continue;
		}

		// Check routing commands
		if (ROUTING_DIRECTIVES[cmd]) {
			push(profile.ignored, { directive: trimmed, reason: ROUTING_DIRECTIVES[cmd] });
			continue;
		}

		// TAP interface rejection
		if (cmd == 'dev' || cmd == 'dev-type') {
			if (length(tokens) > 1 && index(lc(tokens[1]), 'tap') != -1) {
				return { ok: false, error: 'TAP device mode is unsupported. Only TUN mode is permitted.' };
			}
			continue;
		}

		// External file reference check (reject reading from host filesystem)
		let file_refs = ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'crl-verify', 'extra-certs', 'pkcs12'];
		let is_file_ref = false;
		for (let fr in file_refs) {
			if (cmd == fr) {
				is_file_ref = true;
				if (cmd == 'pkcs12') {
					return { ok: false, error: 'PKCS#12 (.p12) bundles are not supported. Please extract PEM certificates.' };
				}
				push(profile.incomplete, cmd);
				push(profile.ignored, { directive: trimmed, reason: 'external file references not loaded; please supply certificate material' });
				break;
			}
		}
		if (is_file_ref) continue;

		// Process allowlisted directives
		if (cmd == 'remote') {
			if (length(profile.remotes) >= MAX_REMOTES) {
				push(profile.warnings, 'Max 64 remote entries reached; ignoring excess remotes');
				continue;
			}
			if (length(tokens) >= 2) {
				let r_host = tokens[1];
				let r_port = (length(tokens) >= 3) ? tokens[2] : '1194';
				let r_proto = (length(tokens) >= 4) ? lc(tokens[3]) : 'udp';
				if (!util.is_hostname(r_host)) {
					push(profile.warnings, sprintf('Invalid remote hostname: %s', r_host));
					continue;
				}
				if (!util.is_port(r_port)) {
					push(profile.warnings, sprintf('Invalid remote port: %s', r_port));
					continue;
				}
				push(profile.remotes, sprintf('%s %s %s', r_host, r_port, r_proto));
			}
		} else if (cmd == 'proto') {
			// Handled in remote default or stored in extra
		} else if (cmd == 'auth-user-pass') {
			profile.auth_user_pass = true;
		} else if (cmd == 'cipher') {
			if (length(tokens) > 1) profile.cipher = tokens[1];
		} else if (cmd == 'data-ciphers') {
			if (length(tokens) > 1) profile.data_ciphers = tokens[1];
		} else if (cmd == 'ncp-ciphers') {
			if (length(tokens) > 1) {
				profile.data_ciphers = tokens[1];
				push(profile.warnings, 'ncp-ciphers is a deprecated alias for data-ciphers');
			}
		} else if (cmd == 'data-ciphers-fallback') {
			if (length(tokens) > 1) profile.data_ciphers_fallback = tokens[1];
		} else if (cmd == 'auth') {
			if (length(tokens) > 1) profile.auth = tokens[1];
		} else if (cmd == 'ping') {
			if (length(tokens) > 1) profile.ping = tokens[1];
		} else if (cmd == 'ping-restart') {
			if (length(tokens) > 1) profile.ping_restart = tokens[1];
		} else if (cmd == 'ping-exit') {
			if (length(tokens) > 1) profile.ping_exit = tokens[1];
		} else if (cmd == 'explicit-exit-notify') {
			if (length(tokens) > 1) profile.explicit_exit_notify = tokens[1];
			else profile.explicit_exit_notify = '1';
		} else if (cmd == 'comp-lzo') {
			if (length(tokens) > 1 && tokens[1] == 'no') profile.compress = 'none';
		} else if (cmd == 'tls-version-min') {
			if (length(tokens) > 1) profile.tls_version_min = tokens[1];
		} else if (cmd == 'verify-x509-name') {
			if (length(tokens) > 1) profile.verify_x509_name = join(' ', slice(tokens, 1));
		} else if (cmd == 'peer-fingerprint') {
			if (length(tokens) > 1) profile.peer_fingerprint = tokens[1];
		} else if (cmd == 'remote-cert-tls') {
			if (length(tokens) > 1) profile.remote_cert_tls = lc(tokens[1]);
		} else if (cmd == 'mssfix') {
			if (length(tokens) > 1 && +tokens[1] >= 576 && +tokens[1] <= 1500) {
				profile.mssfix = +tokens[1];
			}
		} else if (cmd == 'tun-mtu') {
			if (length(tokens) > 1 && +tokens[1] >= 576 && +tokens[1] <= 9000) {
				profile.tun_mtu = +tokens[1];
			}
		} else if (cmd == 'keepalive') {
			if (length(tokens) >= 3) {
				profile.keepalive = sprintf('%s %s', tokens[1], tokens[2]);
			}
		} else if (cmd == 'compress') {
			if (length(tokens) > 1) profile.compress = tokens[1];
		} else if (cmd == 'key-direction') {
			if (length(tokens) > 1) profile.key_direction = tokens[1];
		} else {
			// Recognized safe structural directives
			let safe_flags = ['client', 'tls-client', 'pull', 'nobind', 'persist-key', 'persist-tun',
			                   'float', 'auth-nocache', 'remote-random', 'resolv-retry', 'auth-retry'];
			let is_safe = false;
			for (let sf in safe_flags) {
				if (cmd == sf) {
					is_safe = true;
					break;
				}
			}
			if (is_safe) {
				// Re-emitted by renderer if necessary
			} else {
				push(profile.ignored, { directive: trimmed, reason: 'unrecognized or non-standard directive' });
			}
		}
	}

	// Determine tls_kind based on extracted materials
	if (profile.materials['tls-crypt-v2']) {
		profile.tls_kind = 'tls-crypt-v2';
	} else if (profile.materials['tls-crypt']) {
		profile.tls_kind = 'tls-crypt';
	} else if (profile.materials['tls-auth']) {
		profile.tls_kind = 'tls-auth';
	}

	// Provider detection
	if (profile.verify_x509_name && index(profile.verify_x509_name, '.windscribe.com') != -1) {
		profile.provider = 'windscribe';
	}
	for (let r in profile.remotes) {
		if (index(r, '.windscribe.com') != -1) {
			profile.provider = 'windscribe';
			break;
		}
	}

	if (length(profile.remotes) == 0) {
		push(profile.warnings, 'No valid remote servers found in configuration.');
	}

	return {
		ok: true,
		profile: profile
	};
}

export {
	parse_ovpn
};
