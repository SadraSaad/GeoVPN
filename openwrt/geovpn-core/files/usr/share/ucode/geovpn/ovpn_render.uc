//
// GeoVPN OpenVPN Configuration Renderer
//
'use strict';

import * as fs from 'fs';
import * as util from './util.uc';

function render_ovpn(profile, profile_dir, main_cfg) {
	if (!profile || type(profile) != 'object') return null;

	let tun_dev = (main_cfg && main_cfg.tun_dev) ? main_cfg.tun_dev : 'geovpn0';
	let lines = [];

	push(lines, '# Managed by GeoVPN — do not edit manually');
	push(lines, 'client');
	push(lines, sprintf('dev %s', tun_dev));
	push(lines, 'dev-type tun');
	push(lines, 'nobind');
	push(lines, 'persist-key');
	push(lines, 'persist-tun');

	// Remote endpoints
	if (profile.remotes && type(profile.remotes) == 'array') {
		for (let r in profile.remotes) {
			let parts = split(r, ' ');
			if (length(parts) >= 1 && util.is_hostname(parts[0])) {
				let port = (length(parts) >= 2 && util.is_port(parts[1])) ? parts[1] : '1194';
				let proto = (length(parts) >= 3) ? parts[2] : 'udp';
				push(lines, sprintf('remote %s %s %s', parts[0], port, proto));
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

	if (profile.keepalive) {
		push(lines, sprintf('keepalive %s', profile.keepalive));
	} else {
		push(lines, 'keepalive 10 60');
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
	push(lines, 'syslog geovpn');
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

	// Key materials from profile directory
	if (profile_dir) {
		let ca_file = profile_dir + '/ca.crt';
		let cert_file = profile_dir + '/cert.crt';
		let key_file = profile_dir + '/key.pem';
		let tls_file = profile_dir + '/tls.key';
		let auth_file = profile_dir + '/auth';

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

export {
	render_ovpn
};
