//
// GeoVPN Unified Multi-Profile & Batch Import Dispatcher (§5.2, §5.3, §5.4, §5.5, §5.6 / FR-31, FR-33, FR-34, FR-35, AT-24, AT-26, AT-35, AT-36)
// Supporting .ovpn (OpenVPN) and .conf (WireGuard).
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';
import * as cfg from './config.uc';
import * as cred from './cred.uc';
import * as ovpn_parse from './ovpn_parse.uc';
import * as wg_parse from './wg_parse.uc';
import * as ike_import from './ike_import.uc';

const MAX_CONFIG_SIZE = 131072; // 128 KB
const MAX_PROFILES = 100;
const MAX_BATCH_FILES = 50;

/**
 * Computes SHA-256 hash of a string using sha256sum via temporary file.
 */
function compute_content_hash(content) {
	if (type(content) != 'string') return '';
	let tmpdir = fs.mkdtemp('/tmp/geovpn_hash.XXXXXX');
	if (!tmpdir) return '';
	let tmppath = tmpdir + '/content';
	let f = fs.open(tmppath, 'w');
	if (!f) { fs.rmdir(tmpdir); return ''; }
	f.write(content);
	f.close();
	let res = util.safe_exec(['sha256sum', tmppath]);
	fs.unlink(tmppath);
	fs.rmdir(tmpdir);
	if (res.code == 0 && res.stdout) {
		let parts = split(trim(res.stdout), ' ');
		return parts[0];
	}
	return '';
}

/**
 * Normalizes a file name into a human-friendly profile name (§5.5).
 * Strips extension, replaces '-' and '_' with spaces.
 */
function normalize_name(filename, default_name) {
	if (default_name && length(default_name) > 0) {
		return trim(default_name);
	}
	if (!filename || length(filename) == 0) {
		return 'Imported Profile';
	}
	let base = fs.basename(filename);
	base = replace(base, /\.(ovpn|conf|wireguard|openvpn|sswan)$/i, '');
	base = replace(base, /[-_]+/g, ' ');
	base = replace(base, /\s+/g, ' ');
	base = trim(base);
	return (length(base) > 0) ? base : 'Imported Profile';
}

/**
 * Sniffs configuration kind from initial content and filename (§5.2).
 */
function sniff_kind(content, filename) {
	if (type(content) != 'string') return 'unknown';
	if (index(content, '\0') != -1) return 'invalid';

	let c = content;
	if (substr(c, 0, 3) == '\xef\xbb\xbf') c = substr(c, 3);
	else if (substr(c, 0, 1) == '\ufeff') c = substr(c, 1);

	let sample = substr(c, 0, 4096);

	if (match(sample, /(^|\n)\s*\[\s*Interface\s*\]/i)) {
		return 'wireguard';
	}

	if (match(sample, /^ikev2:\/\//i)) {
		return 'ikev2';
	}

	if (substr(trim(sample), 0, 1) == '{' && (index(sample, '"type"') != -1 || index(sample, '"remote"') != -1 || index(sample, '"uuid"') != -1)) {
		return 'sswan';
	}

	if (match(sample, /(^|\n)\s*(server|gateway|remote):\s*[^\r\n]+/i) && match(sample, /(^|\n)\s*(username|user|eap_id|account):\s*[^\r\n]+/i)) {
		return 'ikev2';
	}

	if (match(sample, /(^|\n)\s*(client|dev\s+tun|remote\s+|<ca>|<tls-)/i)) {
		return 'openvpn';
	}

	if (filename) {
		if (match(filename, /\.ovpn$/i)) return 'openvpn';
		if (match(filename, /\.conf$/i)) return 'wireguard';
		if (match(filename, /\.sswan$/i)) return 'sswan';
	}

	return 'unknown';
}

/**
 * Detects Stealth / WStunnel directives and returns honest limitation notice (§5.6).
 */
function detect_stealth_notice(content, filename) {
	let str = (type(content) == 'string') ? content : '';
	if (filename) str += ' ' + filename;

	if (match(str, /\b(stealth|wstunnel|shadowsocks|obfs|stunnel)\b/i) ||
	    match(str, /proto\s+stealth/i) ||
	    match(str, /transport\s+stealth/i)) {
		return 'Stealth/WStunnel encapsulation detected: GeoVPN does not directly support Stealth/WStunnel encapsulation. External transport encapsulation (e.g. wstunnel/stunnel) is required.';
	}
	return null;
}

/**
 * Computes endpoint fingerprint for deduplication.
 */
function compute_endpoint_fingerprint(profile) {
	if (!profile) return '';
	if (profile.proto == 'wireguard') {
		let host = lc(profile.wg_endpoint_host || '');
		let port = profile.wg_endpoint_port || 51820;
		let pubkey = profile.wg_public_key || '';
		return sprintf('wg:%s:%d:%s', host, port, pubkey);
	}
	if (profile.proto == 'ikev2') {
		let host = lc(profile.ike_host || '');
		let user = lc(profile.ike_username || '');
		return sprintf('ikev2:%s:%s', host, user);
	}

	let remotes = profile.remotes || profile.remote || [];
	if (type(remotes) == 'string') remotes = [remotes];
	let first_remote = (length(remotes) > 0) ? remotes[0] : '';
	let parts = split(first_remote, ' ');
	let host = (length(parts) >= 1) ? lc(parts[0]) : '';
	let port = (length(parts) >= 2) ? parts[1] : '1194';
	let proto_str = (length(parts) >= 3) ? lc(parts[2]) : 'udp';
	let tls_kind = profile.tls_kind || 'none';
	return sprintf('ovpn:%s:%s:%s:%s', host, port, proto_str, tls_kind);
}

/**
 * Applies Windscribe presets & normalizations (N1..N5).
 */
function normalize_windscribe(profile, raw_content) {
	if (!profile) return;

	let is_windscribe = false;
	if (profile.provider == 'windscribe') is_windscribe = true;
	if (profile.verify_x509_name && index(profile.verify_x509_name, '.windscribe.com') != -1) is_windscribe = true;
	if (profile.wg_endpoint_host && index(profile.wg_endpoint_host, '.windscribe.com') != -1) is_windscribe = true;
	if (profile.ike_host && index(profile.ike_host, '.windscribe.com') != -1) is_windscribe = true;

	let remotes = profile.remotes || profile.remote || [];
	if (type(remotes) == 'string') remotes = [remotes];
	for (let r in remotes) {
		if (index(r, '.windscribe.com') != -1) {
			is_windscribe = true;
			break;
		}
	}

	if (raw_content && (index(raw_content, '10.255.255.3') != -1 || index(raw_content, 'windscribe.com') != -1)) {
		is_windscribe = true;
	}

	if (is_windscribe) {
		profile.provider = 'windscribe';
	}

	// N1: ping-exit -> ping-restart (OpenVPN)
	if (profile.proto == 'openvpn') {
		if (profile.ping_exit && length(profile.ping_exit) > 0) {
			if (!profile.ping_restart || length(profile.ping_restart) == 0) {
				profile.ping_restart = profile.ping_exit;
			}
			profile.ping_exit = '';
			push(profile.warnings, 'Normalizing: ping-exit converted to ping-restart (N1)');
		}
	}

	// N2: keepalive suppression when ping directives are present
	if (profile.proto == 'openvpn') {
		let has_ping = (profile.ping && length(profile.ping) > 0) ||
		               (profile.ping_restart && length(profile.ping_restart) > 0);
		if (has_ping) {
			if (profile.keepalive && length(profile.keepalive) > 0) {
				push(profile.warnings, 'Normalizing: keepalive suppressed in favor of ping directives (N2)');
			}
			profile.keepalive = '';
		}
	}

	// N3: Remote endpoint parsing & deduplication
	if (profile.proto == 'openvpn') {
		let raw_rems = profile.remotes || profile.remote || [];
		if (type(raw_rems) == 'string') raw_rems = [raw_rems];
		let deduped = [];
		let seen = {};
		for (let r in raw_rems) {
			let parts = split(trim(r), ' ');
			if (length(parts) >= 1 && util.is_hostname(parts[0])) {
				let host = lc(parts[0]);
				let port = (length(parts) >= 2 && util.is_port(parts[1])) ? parts[1] : '1194';
				let pproto = (length(parts) >= 3) ? lc(parts[2]) : 'udp';
				let key = sprintf('%s %s %s', host, port, pproto);
				if (!seen[key]) {
					seen[key] = true;
					push(deduped, key);
				}
			}
		}
		if (length(deduped) != length(raw_rems)) {
			push(profile.warnings, sprintf('Normalizing: deduplicated remote endpoints from %d to %d (N3)', length(raw_rems), length(deduped)));
		}
		profile.remotes = deduped;
		profile.remote = deduped;
	}

	// N4: WireGuard default MTU 1420 & keepalive 25; OpenVPN mtu/mss clamping
	if (profile.proto == 'wireguard') {
		if (!profile.wg_mtu || +profile.wg_mtu == 0) {
			profile.wg_mtu = 1420;
		}
		if (profile.wg_keepalive == null || length('' + profile.wg_keepalive) == 0) {
			profile.wg_keepalive = 25;
		}
	} else if (profile.proto == 'openvpn') {
		if (!profile.tun_mtu || +profile.tun_mtu <= 0 || +profile.tun_mtu > 1500) {
			profile.tun_mtu = 1500;
		}
		if (!profile.mssfix || +profile.mssfix <= 0 || +profile.mssfix > 1450) {
			profile.mssfix = 1450;
		}
		if (+profile.tun_mtu - 40 < +profile.mssfix) {
			profile.mssfix = +profile.tun_mtu - 40;
		}
	}

	// N5: Pushed DNS normalization (e.g. 10.255.255.3 routed via pushed)
	if (profile.proto == 'wireguard') {
		if (is_windscribe && length(profile.wg_dns) == 0) {
			push(profile.wg_dns, '10.255.255.3');
		}
		for (let d in profile.wg_dns) {
			if (d == '10.255.255.3') {
				profile.provider = 'windscribe';
				break;
			}
		}
	} else if (profile.proto == 'openvpn') {
		if (raw_content && index(raw_content, '10.255.255.3') != -1) {
			profile.dns = profile.dns || [];
			let found_dns = false;
			for (let d in profile.dns) {
				if (d == '10.255.255.3') { found_dns = true; break; }
			}
			if (!found_dns) {
				push(profile.dns, '10.255.255.3');
			}
			profile.provider = 'windscribe';
			push(profile.warnings, 'Normalizing: Windscribe tunnel DNS 10.255.255.3 routed via pushed DNS resolver (N5)');
		}
	}
}

/**
 * Searches for an existing profile with matching content hash or endpoint fingerprint.
 */
function find_duplicate_profile(profile, source_sha256, fingerprint) {
	let cursor = cfg.get_cursor();
	let sections = cursor.get_all('geovpn');
	if (!sections) return null;

	for (let sname in sections) {
		let s = sections[sname];
		if (s['.type'] == 'profile' && util.is_profile_id(sname)) {
			if (source_sha256 && s.source_sha256 && s.source_sha256 == source_sha256) {
				return { id: sname, reason: 'identical content hash' };
			}
			let p = cfg.get_profile(sname);
			if (p && fingerprint) {
				let fp = compute_endpoint_fingerprint(p);
				if (fp && fp == fingerprint) {
					return { id: sname, reason: 'identical endpoint and protocol' };
				}
			}
		}
	}
	return null;
}

/**
 * Imports a single profile from string or parsed input (§5.2, §5.4).
 */
function import_profile(opts) {
	if (!opts || type(opts) != 'object') {
		return { ok: false, error: 'Options object required' };
	}
	let content = opts.content;
	let filename = opts.filename;
	let name = opts.name;
	let forced_proto = opts.proto || opts.kind;
	let cred_id = opts.cred || opts.cred_id;
	let dedupe_policy = opts.dedupe || 'skip';
	let dry_run = opts.dry_run || false;

	if (type(content) != 'string' || length(content) == 0) {
		return { ok: false, error: 'Config content cannot be empty' };
	}
	if (length(content) > MAX_CONFIG_SIZE) {
		return { ok: false, error: 'Config size exceeds 128 KB limit' };
	}
	if (index(content, '\0') != -1) {
		return { ok: false, error: 'Config contains binary NUL byte' };
	}

	if (cred_id && length(cred_id) > 0) {
		if (!cred.is_valid_id(cred_id)) {
			return { ok: false, error: 'Invalid credential set ID: ' + cred_id };
		}
	}

	let kind = (forced_proto && forced_proto != 'auto') ? forced_proto : sniff_kind(content, filename);
	if (kind == 'invalid') {
		return { ok: false, error: 'Invalid configuration: binary NUL byte detected' };
	}
	if (kind != 'openvpn' && kind != 'wireguard' && kind != 'sswan' && kind != 'ikev2' && kind != 'ikev2-form') {
		return { ok: false, error: 'Unrecognized configuration format: only .ovpn, .conf, and .sswan are supported' };
	}

	let prof_name = normalize_name(filename, name);
	let parse_res = null;

	if (kind == 'wireguard') {
		parse_res = wg_parse.parse_wireguard(content, prof_name, { cred: cred_id });
	} else if (kind == 'sswan' || kind == 'ikev2' || kind == 'ikev2-form') {
		parse_res = ike_import.parse_ikev2(content, prof_name, { cred: cred_id });
	} else {
		parse_res = ovpn_parse.parse_ovpn(content, prof_name);
	}

	if (!parse_res || !parse_res.ok) {
		return { ok: false, error: (parse_res && parse_res.error) ? parse_res.error : 'Parse failed' };
	}

	let profile = parse_res.profile;
	profile.warnings = profile.warnings || [];
	profile.notices = profile.notices || [];
	profile.ignored = profile.ignored || [];
	profile.incomplete = profile.incomplete || [];

	let stealth_notice = detect_stealth_notice(content, filename);
	if (stealth_notice) {
		push(profile.notices, stealth_notice);
		push(profile.warnings, stealth_notice);
	}

	let forced_provider = opts.provider || opts.preset;
	if (forced_provider && forced_provider != 'auto') {
		profile.provider = forced_provider;
	}

	normalize_windscribe(profile, content);

	// Shared credential set linking (§5.4 / FR-34)
	if (cred_id && length(cred_id) > 0) {
		profile.cred = cred_id;
		if (profile.proto == 'openvpn') {
			profile.auth_user_pass = true;
			// Profile needs credentials if the shared credential set has no auth secret
			profile.needs_credentials = !cred.has_secret(cred_id, 'auth');
		} else if (profile.proto == 'wireguard') {
			if (profile.private_key && !cred.has_secret(cred_id, 'wg.key')) {
				cred.store_wg_keys(cred_id, profile.private_key, profile.preshared_key);
			}
			profile.needs_credentials = !cred.has_secret(cred_id, 'wg.key') && !profile.private_key;
		} else if (profile.proto == 'ikev2') {
			if (parse_res.password && !cred.has_secret(cred_id, 'auth')) {
				cred.store_userpass(cred_id, profile.ike_username, parse_res.password);
			}
			profile.needs_credentials = !cred.has_secret(cred_id, 'auth') && (!parse_res.password || length(parse_res.password) == 0);
		}
	} else {
		if (profile.proto == 'openvpn' && profile.auth_user_pass) {
			profile.needs_credentials = true;
		}
	}

	let source_sha256 = compute_content_hash(content);
	profile.source_sha256 = source_sha256;
	let fp = compute_endpoint_fingerprint(profile);

	// Deduplication check
	let dup = find_duplicate_profile(profile, source_sha256, fp);
	if (dup) {
		if (dedupe_policy == 'skip') {
			return {
				ok: true,
				skipped: true,
				duplicate_of: dup.id,
				reason: sprintf('Profile already imported as %s (%s)', dup.id, dup.reason),
				name: profile.name,
				proto: profile.proto,
				provider: profile.provider
			};
		} else if (dedupe_policy == 'replace') {
			cfg.delete_profile(dup.id);
		} else if (dedupe_policy == 'keep_both') {
			let base_name = profile.name;
			let m = match(profile.name, /^(.*)\s+\((\d+)\)$/);
			if (m) {
				base_name = m[1];
			}
			let max_num = 0;
			let cursor = cfg.get_cursor();
			let all_sections = cursor.get_all('geovpn');
			if (all_sections) {
				for (let sid in all_sections) {
					let sec = all_sections[sid];
					if (sec['.type'] == 'profile' && sec.name) {
						if (sec.name == base_name) {
							// base profile exists
						} else {
							let sm = match(sec.name, /^(.*)\s+\((\d+)\)$/);
							if (sm && sm[1] == base_name) {
								let n = +sm[2];
								if (n > max_num) {
									max_num = n;
								}
							}
						}
					}
				}
			}
			profile.name = sprintf('%s (%d)', base_name, max_num + 1);
		}
	}

	if (dry_run) {
		return {
			ok: true,
			dry_run: true,
			profile: profile,
			name: profile.name,
			proto: profile.proto,
			provider: profile.provider,
			cred: profile.cred,
			warnings: profile.warnings,
			notices: profile.notices,
			ignored: profile.ignored,
			incomplete: profile.incomplete,
			needs_credentials: profile.needs_credentials
		};
	}

	// Profile count limits check
	let cursor = cfg.get_cursor();
	let all_sections = cursor.get_all('geovpn');
	let profile_count = 0;
	if (all_sections) {
		for (let s in all_sections) {
			if (all_sections[s]['.type'] == 'profile') profile_count++;
		}
	}
	if (profile_count >= MAX_PROFILES) {
		return { ok: false, error: sprintf('Profile limit reached: maximum %d profiles allowed', MAX_PROFILES) };
	}

	let id = cfg.create_profile(profile);
	if (!id) {
		return { ok: false, error: 'Failed to create profile' };
	}

	cursor.set('geovpn', id, 'source_sha256', source_sha256);
	cursor.commit('geovpn');

	let pdir = cfg.get_profiles_dir() + '/' + id;
	let raw_filename = (profile.proto == 'wireguard') ? 'profile.conf' : ((profile.proto == 'ikev2') ? (kind == 'sswan' ? 'profile.sswan' : 'profile.conf') : 'profile.ovpn');
	let rf = fs.open(pdir + '/' + raw_filename, 'w', 0o600);
	if (rf) {
		rf.write(content);
		rf.close();
		fs.chmod(pdir + '/' + raw_filename, 0o600);
	}

	return {
		ok: true,
		id: id,
		name: profile.name,
		proto: profile.proto,
		provider: profile.provider,
		cred: profile.cred,
		source_sha256: source_sha256,
		warnings: profile.warnings,
		notices: profile.notices,
		ignored: profile.ignored,
		incomplete: profile.incomplete,
		needs_credentials: profile.needs_credentials
	};
}

/**
 * Imports multiple profiles from an array or directory (§5.5 / FR-35).
 * Supports atomic rollback on fatal batch error.
 */
function import_batch(items_or_dir, options) {
	options = options || {};
	let cred_id = options.cred || options.cred_id;
	let dedupe_policy = options.dedupe || 'skip';
	let atomic = (options.atomic != null) ? options.atomic : false;
	let proto = options.proto;

	let items = [];

	if (type(items_or_dir) == 'string') {
		let st = fs.stat(items_or_dir);
		if (!st) {
			return { ok: false, error: sprintf('Path does not exist: %s', items_or_dir) };
		}
		if (st.type == 'directory') {
			let entries = fs.lsdir(items_or_dir);
			if (!entries) {
				return { ok: false, error: sprintf('Cannot read directory: %s', items_or_dir) };
			}
			let sorted_entries = sort(entries);
			for (let e in sorted_entries) {
				if (e != '.' && e != '..' && match(e, /\.(ovpn|conf)$/i)) {
					let fpath = items_or_dir + '/' + e;
					let st_e = fs.stat(fpath);
					if (!st_e || st_e.type != 'file') continue;
					let f = fs.open(fpath, 'r');
					if (f) {
						let content = f.read('all') || '';
						f.close();
						push(items, {
							filename: e,
							content: content,
							path: fpath,
							proto: proto
						});
					} else {
						push(items, {
							filename: e,
							content: '',
							path: fpath,
							proto: proto,
							unreadable: true
						});
					}
				}
			}
			if (length(items) == 0) {
				return { ok: false, error: sprintf('No .ovpn or .conf configuration files found in directory: %s', items_or_dir) };
			}
		} else {
			let f = fs.open(items_or_dir, 'r');
			if (!f) {
				return { ok: false, error: sprintf('Cannot read file: %s', items_or_dir) };
			}
			let content = f.read('all') || '';
			f.close();
			push(items, {
				filename: fs.basename(items_or_dir),
				content: content,
				path: items_or_dir,
				proto: proto
			});
		}
	} else if (type(items_or_dir) == 'array') {
		items = items_or_dir;
	} else {
		return { ok: false, error: 'Invalid input: expected directory path or array of items' };
	}

	if (length(items) > MAX_BATCH_FILES) {
		return { ok: false, error: sprintf('Batch size exceeds limit: maximum %d files per batch (received %d)', MAX_BATCH_FILES, length(items)) };
	}

	let cursor = cfg.get_cursor();
	let all_sections = cursor.get_all('geovpn');
	let profile_count = 0;
	if (all_sections) {
		for (let s in all_sections) {
			if (all_sections[s]['.type'] == 'profile') profile_count++;
		}
	}
	if (profile_count + length(items) > MAX_PROFILES) {
		return { ok: false, error: sprintf('Batch would exceed total profile limit of %d (currently %d, importing %d)', MAX_PROFILES, profile_count, length(items)) };
	}

	let imported = [];
	let skipped = [];
	let errors = [];
	let created_ids = [];

	for (let i = 0; i < length(items); i++) {
		let item = items[i];
		let item_content = item.content;
		let item_filename = item.filename;
		let item_name = item.name;
		let item_proto = item.proto || proto;
		let item_provider = item.provider || options.provider || options.preset;

		if (!item_content && item.path) {
			let f = fs.open(item.path, 'r');
			if (f) {
				item_content = f.read('all') || '';
				f.close();
			}
		}

		if (item.unreadable) {
			push(errors, {
				item: item_filename || sprintf('item_%d', i + 1),
				error: 'Cannot read file (permission denied or I/O error)'
			});
			if (atomic) {
				for (let cid in created_ids) {
					cfg.delete_profile(cid);
				}
				return {
					ok: false,
					error: sprintf('Batch import aborted: cannot read %s', item_filename || 'file'),
					rolled_back: true,
					rollback_count: length(created_ids),
					errors: errors
				};
			}
			continue;
		}

		let res = import_profile({
			content: item_content,
			filename: item_filename,
			name: item_name,
			proto: item_proto,
			provider: item_provider,
			cred: cred_id,
			dedupe: dedupe_policy
		});

		if (res.ok) {
			if (res.skipped) {
				push(skipped, res);
			} else {
				push(imported, res);
				push(created_ids, res.id);
			}
		} else {
			push(errors, {
				item: item_filename || item_name || sprintf('item_%d', i + 1),
				error: res.error
			});

			if (atomic) {
				for (let cid in created_ids) {
					cfg.delete_profile(cid);
				}
				return {
					ok: false,
					error: sprintf('Batch import aborted: %s (%s)', res.error, item_filename || item_name || ''),
					rolled_back: true,
					rollback_count: length(created_ids),
					errors: errors
				};
			}
		}
	}

	return {
		ok: (length(errors) == 0),
		imported: imported,
		skipped: skipped,
		errors: errors,
		total: length(items),
		count: length(imported)
	};
}

export {
	import_profile,
	import_batch,
	sniff_kind,
	normalize_name,
	compute_content_hash,
	compute_endpoint_fingerprint,
	normalize_windscribe,
	detect_stealth_notice,
	MAX_CONFIG_SIZE,
	MAX_PROFILES,
	MAX_BATCH_FILES
};
