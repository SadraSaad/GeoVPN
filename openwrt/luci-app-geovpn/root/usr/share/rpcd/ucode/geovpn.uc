//
// GeoVPN rpcd ucode plugin (luci.geovpn object)
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from 'geovpn.util';
import * as cfg from 'geovpn.config';
import * as state from 'geovpn.state';
import * as parse from 'geovpn.ovpn_parse';
import * as diag from 'geovpn.diag';
import * as importer from 'geovpn.import';
import * as te from 'geovpn.test_engine';
import * as cred from 'geovpn.cred';
import * as health from 'geovpn.health';
import * as drv_common from 'geovpn.drivers.common';

function get_installed_version() {
	let res = util.safe_exec(['apk', 'info', '-v', 'geovpn-core']);
	if (res && res.code == 0 && res.stdout) {
		let m = match(res.stdout, /geovpn-core-([0-9]+\.[0-9]+(?:\.[0-9]+)?)/);
		if (m && m[1]) return m[1];
	}
	res = util.safe_exec(['apk', 'info', '-v', 'luci-app-geovpn']);
	if (res && res.code == 0 && res.stdout) {
		let m = match(res.stdout, /luci-app-geovpn-([0-9]+\.[0-9]+(?:\.[0-9]+)?)/);
		if (m && m[1]) return m[1];
	}
	return '1.1.0';
}

let base_methods = {
		status: {
			call: function(req) {
				let s = state.get_state();
				let cursor = uci.cursor();
				cursor.load('geovpn');
				s.service.enabled = cursor.get('geovpn', 'main', 'enabled') == '1';
				let ver = get_installed_version();
				s.version = ver;
				if (s.service) s.service.version = ver;
				let override = cfg.get_active_override();
				s.service.active_profile = override || cursor.get('geovpn', 'main', 'active_profile') || '';
				s.tunnel.override = override || null;

				if (s.service.active_profile) {
					let p = cfg.get_profile(s.service.active_profile);
					if (p) {
						s.tunnel.name = p.name || s.service.active_profile;
						s.tunnel.proto = p.proto || 'openvpn';
					}
				}

				let ifstats = state.get_interface_stats(s.tunnel.device || 'geovpn0');
				s.tunnel.rx_bytes = ifstats.rx_bytes;
				s.tunnel.tx_bytes = ifstats.tx_bytes;

				let h_summary = health.get_health_summary();
				s.tunnel.health = h_summary.status || 'unknown';
				s.tunnel.last_handshake = h_summary.last_handshake || null;
				s.drivers = drv_common.list_drivers();

				return s;
			}
		},

		logs: {
			args: { lines: 100, source: 'all' },
			call: function(req) {
				let lines = (req && req.args && req.args.lines) ? +req.args.lines : 100;
				let source = (req && req.args && req.args.source) ? req.args.source : 'all';
				return diag.get_scrubbed_logs(lines, source);
			}
		},

		import_ovpn: {
			args: { name: '', content: '' },
			call: function(req) {
				let name = (req && req.args && req.args.name) ? req.args.name : 'Imported Profile';
				let content = (req && req.args && req.args.content) ? req.args.content : '';

				if (!content || length(content) == 0) {
					return { error: 'BAD_REQUEST', message: 'Config content cannot be empty' };
				}

				let res = importer.import_profile({
					name: name,
					content: content,
					proto: 'openvpn',
					dedupe: 'replace'
				});
				if (!res.ok) {
					return { error: 'PARSE_ERROR', message: res.error };
				}

				return {
					ok: true,
					id: res.id,
					name: res.name,
					warnings: res.warnings || [],
					ignored: res.ignored || [],
					incomplete: res.incomplete || []
				};
			}
		},

		profile_get: {
			args: { id: '' },
			call: function(req) {
				let id = (req && req.args) ? req.args.id : null;
				if (!util.is_profile_id(id)) {
					return { error: 'INVALID_ID', message: 'Invalid profile ID' };
				}
				let p = cfg.get_profile(id);
				if (!p) {
					return { error: 'NOT_FOUND', message: 'Profile not found' };
				}
				let pdir = cfg.PROFILES_DIR + '/' + id;
				let ovpn_content = '';
				let ovpn_file = pdir + '/profile.ovpn';
				if (fs.stat(ovpn_file)) {
					let f = fs.open(ovpn_file, 'r');
					if (f) {
						ovpn_content = f.read('all') || '';
						f.close();
					}
				}
				if (!ovpn_content || length(ovpn_content) == 0) {
					let c = cfg.load_config();
					ovpn_content = render.render_ovpn(p, pdir, c.main) || '';
				}

				let auth_content = '';
				let auth_file = pdir + '/auth';
				if (fs.stat(auth_file)) {
					let af = fs.open(auth_file, 'r');
					if (af) {
						auth_content = af.read('all') || '';
						af.close();
					}
				}

				return {
					ok: true,
					id: id,
					name: p.name || id,
					proto: p.proto || 'openvpn',
					provider: p.provider || '',
					cred: p.cred || '',
					remotes: p.remotes || [],
					cipher: p.cipher || '',
					auth_user_pass: p.auth_user_pass,
					wg_endpoint_host: p.wg_endpoint_host || '',
					wg_endpoint_port: p.wg_endpoint_port || '',
					wg_public_key: p.wg_public_key || '',
					wg_address: p.wg_address || [],
					wg_dns: p.wg_dns || [],
					wg_allowed_ips: p.wg_allowed_ips || [],
					wg_mtu: p.wg_mtu || '',
					wg_keepalive: p.wg_keepalive || '',
					has_wg_key: p.has_wg_key || false,
					has_wg_psk: p.has_wg_psk || false,
					ike_host: p.ike_host || '',
					ike_remote_id: p.ike_remote_id || '',
					ike_auth: p.ike_auth || '',
					ike_username: p.ike_username || '',
					ike_ca: p.ike_ca || '',
					ike_dpd: p.ike_dpd || '',
					has_ike_secret: p.has_ike_secret || false,
					ovpn: ovpn_content,
					auth: auth_content
				};
			}
		},

		profile_save_raw: {
			args: { id: '', name: '', ovpn: '', auth: '' },
			call: function(req) {
				let id = (req && req.args) ? req.args.id : null;
				let name = (req && req.args && req.args.name) ? req.args.name : '';
				let ovpn = (req && req.args) ? req.args.ovpn : '';
				let auth = (req && req.args) ? req.args.auth : null;
				let args = (req && req.args) ? req.args : {};

				if (!util.is_profile_id(id)) {
					return { error: 'INVALID_ID', message: 'Invalid profile ID' };
				}
				let p = cfg.get_profile(id);
				if (!p) {
					return { error: 'NOT_FOUND', message: 'Profile not found' };
				}

				let pdir = cfg.PROFILES_DIR + '/' + id;
				if (!fs.stat(pdir)) fs.mkdir(pdir, 0o700);

				let cursor = uci.cursor();
				cursor.load('geovpn');

				if (name && length(name) > 0) {
					cursor.set('geovpn', id, 'name', name);
				}

				if (ovpn && length(ovpn) > 0) {
					let of = fs.open(pdir + '/profile.ovpn', 'w', 0o600);
					if (of) {
						of.write(ovpn);
						of.close();
					}
					let parse_res = parse.parse_ovpn(ovpn, name || p.name);
					if (parse_res.ok && parse_res.profile) {
						if (parse_res.profile.remotes) cursor.set('geovpn', id, 'remote', parse_res.profile.remotes);
						if (parse_res.profile.cipher) cursor.set('geovpn', id, 'cipher', parse_res.profile.cipher);
					}
				}

				if (auth != null) {
					let af = fs.open(pdir + '/auth', 'w', 0o600);
					if (af) {
						af.write(auth);
						af.close();
					}
					cursor.set('geovpn', id, 'auth_user_pass', (length(trim(auth)) > 0) ? '1' : '0');
				}

				if (args.cred != null) {
					cursor.set('geovpn', id, 'cred', args.cred);
				}

				if (p.proto == 'wireguard' || args.proto == 'wireguard' || args.wg_endpoint_host) {
					if (args.wg_endpoint_host) cursor.set('geovpn', id, 'wg_endpoint_host', args.wg_endpoint_host);
					if (args.wg_endpoint_port) cursor.set('geovpn', id, 'wg_endpoint_port', sprintf('%d', +args.wg_endpoint_port));
					if (args.wg_public_key) cursor.set('geovpn', id, 'wg_public_key', args.wg_public_key);
					if (args.wg_address) cursor.set('geovpn', id, 'wg_address', (type(args.wg_address) == 'array') ? args.wg_address : [args.wg_address]);
					if (args.wg_dns) cursor.set('geovpn', id, 'wg_dns', (type(args.wg_dns) == 'array') ? args.wg_dns : [args.wg_dns]);
					if (args.wg_allowed_ips) cursor.set('geovpn', id, 'wg_allowed_ips', (type(args.wg_allowed_ips) == 'array') ? args.wg_allowed_ips : [args.wg_allowed_ips]);
					if (args.wg_mtu) cursor.set('geovpn', id, 'wg_mtu', sprintf('%d', +args.wg_mtu));
					if (args.wg_keepalive != null) cursor.set('geovpn', id, 'wg_keepalive', sprintf('%d', +args.wg_keepalive));
					if (args.cred != null) cursor.set('geovpn', id, 'cred', args.cred);
					if (args.wg_key && length(trim(args.wg_key)) > 0) {
						let kf = fs.open(pdir + '/wg.key', 'w', 0o600);
						if (kf) {
							kf.write(trim(args.wg_key));
							kf.close();
						}
					}
					if (args.wg_psk && length(trim(args.wg_psk)) > 0) {
						let pf = fs.open(pdir + '/wg.psk', 'w', 0o600);
						if (pf) {
							pf.write(trim(args.wg_psk));
							pf.close();
						}
						cursor.set('geovpn', id, 'wg_has_psk', '1');
					}
				}

				if (p.proto == 'ikev2' || args.proto == 'ikev2' || args.ike_host) {
					if (args.ike_host) cursor.set('geovpn', id, 'ike_host', args.ike_host);
					if (args.ike_remote_id) cursor.set('geovpn', id, 'ike_remote_id', args.ike_remote_id);
					if (args.ike_username) cursor.set('geovpn', id, 'ike_username', args.ike_username);
					if (args.ike_ca) cursor.set('geovpn', id, 'ike_ca', args.ike_ca);
					if (args.ike_dpd) cursor.set('geovpn', id, 'ike_dpd', sprintf('%d', +args.ike_dpd));
					if (args.cred != null) cursor.set('geovpn', id, 'cred', args.cred);
					if (args.password && length(trim(args.password)) > 0) {
						let sf = fs.open(pdir + '/ike.secret', 'w', 0o600);
						if (sf) {
							sf.write(trim(args.password));
							sf.close();
						}
					}
				}

				cursor.commit('geovpn');
				return { ok: true };
			}
		},

		profile_set_credentials: {
			args: { id: '', username: '', password: '' },
			call: function(req) {
				let id = (req && req.args) ? req.args.id : null;
				let u = (req && req.args) ? req.args.username : '';
				let p = (req && req.args) ? req.args.password : '';

				if (!util.is_profile_id(id)) {
					return { error: 'INVALID_ID', message: 'Invalid profile ID' };
				}

				let success = cfg.set_profile_credentials(id, u, p);
				return { ok: success };
			}
		},

		profile_put_material: {
			args: { id: '', role: '', content: '' },
			call: function(req) {
				let id = (req && req.args) ? req.args.id : null;
				let role = (req && req.args) ? req.args.role : null;
				let content = (req && req.args) ? req.args.content : '';

				if (!util.is_profile_id(id)) {
					return { error: 'INVALID_ID', message: 'Invalid profile ID' };
				}
				let allowed_roles = ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'extra-certs', 'crl-verify'];
				let found = false;
				for (let r in allowed_roles) {
					if (r == role) { found = true; break; }
				}
				if (!found) {
					return { error: 'INVALID_ROLE', message: 'Disallowed material role' };
				}

				let ok = cfg.put_profile_material(id, role, content);
				return { ok: ok, bytes: length(content) };
			}
		},

		profile_delete: {
			args: { id: '' },
			call: function(req) {
				let id = (req && req.args) ? req.args.id : null;
				if (!util.is_profile_id(id)) {
					return { error: 'INVALID_ID', message: 'Invalid profile ID' };
				}
				let ok = cfg.delete_profile(id);
				return { ok: ok };
			}
		},

		service: {
			args: { action: '', profile: '' },
			call: function(req) {
				let action = (req && req.args) ? req.args.action : 'status';
				let target_profile = (req && req.args) ? req.args.profile : null;
				let persist = (req && req.args && (req.args.persist == 1 || req.args.persist == '1' || req.args.persist == true));

				if (action == 'switch') {
					if (!target_profile || !util.is_profile_id(target_profile)) {
						return { error: 'INVALID_ID', message: 'Valid profile ID required for switch' };
					}
					let sres = health.manual_switch(target_profile, persist);
					if (!sres || !sres.ok) {
						return {
							error: (sres && sres.error) ? sres.error : 'SWITCH_FAILED',
							message: (sres && sres.message) ? sres.message : 'Switch failed',
							reason: sres ? sres.reason : null
						};
					}
					return { ok: true, state: 'connected', profile: target_profile, persisted: !!persist };
				}

				if (action == 'health_tick' || action == 'health-tick') {
					let hres = health.run_health_tick({ force: true });
					return hres || { ok: false, error: 'TICK_FAILED' };
				}

				if (target_profile && util.is_profile_id(target_profile)) {
					let cursor = uci.cursor();
					cursor.load('geovpn');
					cursor.set('geovpn', 'main', 'active_profile', target_profile);
					cursor.commit('geovpn');
				}

				let res = null;
				if (action == 'start') {
					res = util.safe_exec(['/etc/init.d/geovpn', 'start']);
				} else if (action == 'stop') {
					res = util.safe_exec(['/etc/init.d/geovpn', 'stop']);
				} else if (action == 'restart') {
					res = util.safe_exec(['/etc/init.d/geovpn', 'restart']);
				} else if (action == 'reload') {
					res = util.safe_exec(['/etc/init.d/geovpn', 'reload']);
				} else {
					return { error: 'INVALID_ACTION', message: 'Unknown service action' };
				}

				return { ok: (res.code == 0) };
			}
		},

		panic: {
			call: function(req) {
				util.safe_exec(['/usr/bin/geovpn', 'panic']);
				return { ok: true, message: 'Emergency stop executed' };
			}
		},

		geo_catalog: {
			args: { kind: 'geoip', q: '', offset: 0, limit: 50 },
			call: function(req) {
				let kind = (req && req.args && req.args.kind) ? req.args.kind : 'geoip';
				let q = (req && req.args && req.args.q) ? lc(req.args.q) : '';
				let offset = (req && req.args && req.args.offset) ? +req.args.offset : 0;
				let limit = (req && req.args && req.args.limit) ? +req.args.limit : 50;
				if (limit > 100) limit = 100;

				let cat_file = sprintf('/etc/geovpn/data/catalog/%s.tsv', kind);
				let pack_info = { build_id: 'none', time: 0 };
				let st_f = fs.open('/etc/geovpn/data/STATE', 'r');
				if (st_f) {
					let st_lines = split(st_f.read('all'), '\n');
					st_f.close();
					for (let sl in st_lines) {
						let sp = split(sl, '=');
						if (length(sp) >= 2) {
							if (trim(sp[0]) == 'build_id') pack_info.build_id = trim(sp[1]);
							if (trim(sp[0]) == 'build_time') pack_info.time = +trim(sp[1]);
						}
					}
				}

				let f = fs.open(cat_file, 'r');
				if (!f) {
					return { total: 0, items: [], pack: pack_info };
				}
				let content = f.read('all') || '';
				f.close();

				let cursor = uci.cursor();
				cursor.load('geovpn');
				let selected_map = {};
				let sections = cursor.get_all('geovpn');
				if (sections) {
					for (let sname in sections) {
						let s = sections[sname];
						if (kind == 'geoip' && s['.type'] == 'geoip' && s.enabled != '0' && s.code) {
							selected_map[lc(s.code)] = true;
						} else if (kind == 'geosite' && s['.type'] == 'geosite' && s.enabled != '0' && s.name) {
							selected_map[lc(s.name)] = true;
						}
					}
				}

				let lines = split(content, '\n');
				let matched = [];

				for (let line in lines) {
					let l = trim(line);
					if (length(l) == 0 || substr(l, 0, 1) == '#') continue;
					let parts = split(l, '\t');
					let name = parts[0];
					if (length(q) > 0 && index(name, q) == -1) continue;

					let count = (length(parts) > 1) ? +parts[1] : 0;
					let count_v6 = (kind == 'geoip' && length(parts) > 2) ? +parts[2] : 0;
					let est_ram_kb = (kind == 'geoip') ? int((count * 64) / 1024) : int((count * 150) / 1024);
					let est_ram = (kind == 'geoip') ? sprintf('%.1f MB', (count * 64) / 1048576) : sprintf('%.1f MB', (count * 150) / 1048576);
					let note = (length(parts) > 3) ? parts[3] : '';

					push(matched, {
						name: name,
						count: count,
						count_v6: count_v6,
						selected: (selected_map[lc(name)] == true),
						est_ram_kb: est_ram_kb,
						est_ram: est_ram,
						note: note
					});
				}

				let total = length(matched);
				let paged = slice(matched, offset, offset + limit);

				return {
					total: total,
					offset: offset,
					limit: limit,
					items: paged,
					pack: pack_info
				};
			}
		},

		geo_update: {
			args: { force: false },
			call: function(req) {
				let force = (req && req.args && req.args.force);
				let args = force ? ['update', '--force'] : ['update'];
				util.safe_exec(['/usr/libexec/geovpn/spawn', ...args]);
				return { started: true };
			}
		},

		geo_update_status: {
			call: function(req) {
				return state.get_update_status();
			}
		},

		test_target: {
			args: { target: '', client: '' },
			call: function(req) {
				let target = (req && req.args) ? req.args.target : '';
				let client = (req && req.args) ? req.args.client : '';
				return diag.test_target(target, client);
			}
		},

		diag: {
			call: function(req) {
				return diag.run_diag();
			}
		}
};

let ext_methods = {
	import_profile: {
		args: { name: '', filename: '', content: '', proto: '', provider: '', cred: '', dry_run: false, dedupe: 'skip' },
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			if (!args.content || length(args.content) == 0) {
				return { error: 'BAD_REQUEST', message: 'Config content cannot be empty' };
			}
			let res = importer.import_profile({
				name: args.name,
				filename: args.filename,
				content: args.content,
				proto: args.proto,
				provider: args.provider || args.preset,
				cred: args.cred,
				dry_run: args.dry_run,
				dedupe: args.dedupe || 'skip'
			});
			if (!res.ok) {
				return { error: 'IMPORT_ERROR', message: res.error };
			}
			return res;
		}
	},

	import_batch: {
		args: { items: [], cred: '', dedupe: 'skip', atomic: false, proto: '', provider: '' },
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			let items = args.items || [];
			if (type(items) != 'array' || length(items) == 0) {
				return { error: 'BAD_REQUEST', message: 'Items array cannot be empty' };
			}
			let res = importer.import_batch(items, {
				cred: args.cred,
				dedupe: args.dedupe || 'skip',
				atomic: args.atomic,
				proto: args.proto,
				provider: args.provider || args.preset
			});
			if (!res.ok) {
				return {
					error: 'BATCH_ERROR',
					message: res.error,
					rolled_back: res.rolled_back || false,
					rollback_count: res.rollback_count || 0,
					errors: res.errors || []
				};
			}
			return res;
		}
	},

	test_start: {
		args: { ids: [], all: false, probe_url: '' },
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			let target = args.all ? 'all' : (args.ids || []);
			let has_spawn = fs.stat('/usr/libexec/geovpn/spawn') && fs.stat('/usr/bin/geovpn');
			if (has_spawn) {
				let t_id = 't' + substr(sprintf('%08x', time()), 0, 8) + substr(sprintf('%04x', rand() % 65536), 0, 4);
				let target_arg = (target == 'all') ? 'all' : ((type(target) == 'array') ? join(',', target) : target);
				let spawn_args = ['/usr/bin/geovpn', 'test', target_arg, '--job-id', t_id];
				if (args.probe_url) {
					push(spawn_args, '--probe-url');
					push(spawn_args, args.probe_url);
				}
				util.safe_exec(['/usr/libexec/geovpn/spawn', ...spawn_args]);
				return { ok: true, job_id: t_id, total: (type(target) == 'array' ? length(target) : 1), async: true };
			}
			let res = te.test_job_start(target, { probe_url: args.probe_url });
			if (!res.ok) {
				return { error: res.error || 'BUSY', message: res.message || 'Cannot start test' };
			}
			return { ok: true, job_id: res.job_id, total: res.total, results: res.results || [] };
		}
	},

	test_status: {
		args: { job_id: '' },
		call: function(req) {
			let jid = (req && req.args) ? req.args.job_id : null;
			if (!jid) return { error: 'INVALID_ARGS', message: 'job_id required' };
			return te.test_job_status(jid);
		}
	},

	test_cancel: {
		args: { job_id: '' },
		call: function(req) {
			let jid = (req && req.args) ? req.args.job_id : null;
			te.test_cancel(jid);
			te.test_cleanup(jid, false);
			return { ok: true };
		}
	},

	test_results: {
		args: { ids: [] },
		call: function(req) {
			let ids = (req && req.args) ? req.args.ids : [];
			let items = te.get_cached_results(ids);
			return { items: items };
		}
	},

	test_cleanup: {
		args: { verify: false },
		call: function(req) {
			let verify = (req && req.args && req.args.verify == true);
			return te.test_cleanup(null, verify);
		}
	},

	list_credentials: {
		call: function(req) {
			return { items: cred.list_credentials() };
		}
	},

	save_credential: {
		args: { id: '', username: '', password: '', wg_key: '', wg_psk: '' },
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			let id = args.id;
			if (!id || !cred.is_valid_id(id)) {
				return { error: 'INVALID_ID', message: 'Invalid credential ID' };
			}
			let saved = false;
			if (args.username || args.password) {
				cred.store_userpass(id, args.username, args.password);
				saved = true;
			}
			if (args.wg_key) {
				cred.store_wg_keys(id, args.wg_key, args.wg_psk);
				saved = true;
			}
			return { ok: true, id: id };
		}
	},

	delete_credential: {
		args: { id: '' },
		call: function(req) {
			let id = (req && req.args) ? req.args.id : null;
			if (!id || !cred.is_valid_id(id)) {
				return { error: 'INVALID_ID', message: 'Invalid credential ID' };
			}
			let ok = cred.delete_credential(id);
			return { ok: ok };
		}
	},

	autoconnect_status: {
		call: function(req) {
			return health.get_autoconnect_status();
		}
	},

	health_tick: {
		args: { force: true },
		call: function(req) {
			let force = (req && req.args && req.args.force !== false);
			return health.run_health_tick({ force: force });
		}
	},

	profile_add: {
		args: {
			name: '',
			proto: 'ikev2',
			host: '',
			username: '',
			password: '',
			remote_id: '',
			ca: 'geovpn-isrg-x1.pem',
			dpd: 30,
			port: 0,
			public_key: '',
			private_key: '',
			preshared_key: '',
			address: '',
			allowed_ips: '',
			cred: ''
		},
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			let proto = args.proto || 'ikev2';
			let host = trim(args.host || '');
			if (!host || length(host) == 0) {
				return { error: 'BAD_REQUEST', message: 'Endpoint Host / IP is required' };
			}

			let name = trim(args.name || '');
			if (!name || length(name) == 0) {
				name = host;
			}

			let cursor = cfg.get_cursor();
			let all_sections = cursor.get_all('geovpn');
			let profile_count = 0;
			if (all_sections) {
				for (let s in all_sections) {
					if (all_sections[s]['.type'] == 'profile') profile_count++;
				}
			}
			if (profile_count >= 100) {
				return { error: 'LIMIT_REACHED', message: 'Maximum 100 profiles allowed' };
			}

			let prof = {
				name: name,
				proto: proto,
				enabled: '1',
				auto_pool: '1',
				cred: args.cred || ''
			};

			if (proto == 'ikev2') {
				let username = trim(args.username || '');
				let password = trim(args.password || '');
				let remote_id = trim(args.remote_id || '') || host;
				let ca = trim(args.ca || '') || 'geovpn-isrg-x1.pem';
				let dpd = +args.dpd || 30;

				if (!username && !args.cred) {
					return { error: 'BAD_REQUEST', message: 'Username is required for IKEv2' };
				}

				prof.ike_host = host;
				prof.ike_remote_id = remote_id;
				prof.ike_auth = 'eap-mschapv2';
				prof.ike_username = username;
				prof.password = password;
				prof.ike_ca = ca;
				prof.ike_dpd = dpd;
				prof.ike_mobike = '0';
				prof.ike_fragmentation = '1';
				prof.ike_if_id = '4200';
				prof.ike_mtu = '1420';
			} else if (proto == 'wireguard') {
				prof.wg_endpoint_host = host;
				prof.wg_endpoint_port = +args.port || 51820;
				prof.wg_public_key = trim(args.public_key || '');
				prof.private_key = trim(args.private_key || '');
				prof.preshared_key = trim(args.preshared_key || '');
				prof.wg_has_psk = (length(prof.preshared_key) > 0) ? '1' : '0';
				let addrs = args.address;
				if (type(addrs) == 'string') addrs = split(addrs, /[\s,]+/);
				prof.wg_address = (type(addrs) == 'array') ? addrs : (addrs ? [addrs] : []);
				let aips = args.allowed_ips;
				if (type(aips) == 'string') aips = split(aips, /[\s,]+/);
				prof.wg_allowed_ips = (type(aips) == 'array' && length(aips) > 0) ? aips : ['0.0.0.0/0'];
				prof.wg_mtu = 1420;
				prof.wg_keepalive = 25;
			} else {
				let port = +args.port || 1194;
				let ovpn_proto = args.ovpn_proto || 'udp';
				prof.remotes = [ sprintf('%s %d %s', host, port, ovpn_proto) ];
				prof.remote = prof.remotes;
				let username = trim(args.username || '');
				let password = trim(args.password || '');
				if (username || password) {
					prof.auth_user_pass = '1';
				}
			}

			let id = cfg.create_profile(prof);
			if (!id) {
				return { error: 'CREATE_FAILED', message: 'Failed to create profile' };
			}

			if (proto == 'openvpn' && (args.username || args.password)) {
				let pdir = cfg.PROFILES_DIR + '/' + id;
				let af = fs.open(pdir + '/auth', 'w', 0o600);
				if (af) {
					af.write(sprintf('%s\n%s\n', trim(args.username || ''), trim(args.password || '')));
					af.close();
					fs.chmod(pdir + '/auth', 0o600);
				}
			}

			return { ok: true, id: id, name: name, proto: proto };
		}
	},

	check_update: {
		call: function(req) {
			let current_ver = get_installed_version();
			let repo = 'SadraSaad/GeoVPN';
			let url = 'https://api.github.com/repos/' + repo + '/releases/latest';

			let res = util.safe_exec(['curl', '-s', '-L', '-m', '10', '-H', 'User-Agent: GeoVPN-Updater', url]);
			if (!res || res.code != 0 || !res.stdout) {
				res = util.safe_exec(['wget', '-q', '-O-', '-T', '10', '--user-agent=GeoVPN-Updater', url]);
			}

			if (!res || res.code != 0 || !res.stdout || length(trim(res.stdout)) == 0) {
				return {
					ok: false,
					current_version: current_ver,
					repo: repo,
					error: 'NETWORK_ERROR',
					message: 'Could not connect to GitHub API'
				};
			}

			let doc = null;
			try {
				doc = json(res.stdout);
			} catch (e) {
				return {
					ok: false,
					current_version: current_ver,
					repo: repo,
					error: 'PARSE_ERROR',
					message: 'Failed to parse GitHub response: ' + e
				};
			}

			if (!doc || !doc.tag_name) {
				return {
					ok: false,
					current_version: current_ver,
					repo: repo,
					error: 'NO_RELEASE',
					message: (doc && doc.message) ? doc.message : 'No release found'
				};
			}

			let latest_tag = doc.tag_name;
			let clean_latest = replace(latest_tag, /^v/, '');
			let clean_curr = replace(current_ver, /^v/, '');

			let l_parts = split(clean_latest, '.');
			let c_parts = split(clean_curr, '.');
			let has_update = false;
			for (let i = 0; i < 3; i++) {
				let l_num = +l_parts[i] || 0;
				let c_num = +c_parts[i] || 0;
				if (l_num > c_num) {
					has_update = true;
					break;
				} else if (l_num < c_num) {
					has_update = false;
					break;
				}
			}

			let assets = [];
			if (doc.assets && type(doc.assets) == 'array') {
				for (let a in doc.assets) {
					if (a && a.name && match(a.name, /\.apk$/)) {
						push(assets, {
							name: a.name,
							url: a.browser_download_url,
							size: a.size || 0
						});
					}
				}
			}

			return {
				ok: true,
				current_version: current_ver,
				latest_version: latest_tag,
				update_available: has_update,
				release_name: doc.name || latest_tag,
				changelog: doc.body || '',
				published_at: doc.published_at || '',
				url: doc.html_url || ('https://github.com/' + repo),
				assets: assets
			};
		}
	},

	apply_update: {
		args: { version: '', assets: [] },
		call: function(req) {
			let args = (req && req.args) ? req.args : {};
			let assets = args.assets || [];

			if (type(assets) != 'array' || length(assets) == 0) {
				let check = ext_methods.check_update.call(req);
				if (check && check.ok && check.assets) {
					assets = check.assets;
				}
			}

			if (type(assets) != 'array' || length(assets) == 0) {
				return { error: 'NO_ASSETS', message: 'No APK package assets available to install' };
			}

			let installed_pkgs = ['geovpn-core', 'luci-app-geovpn'];
			let ike_stat = util.safe_exec(['apk', 'info', '-e', 'geovpn-ikev2']);
			if (ike_stat.code == 0 || fs.stat('/usr/share/ucode/geovpn/drivers/ikev2.uc')) {
				push(installed_pkgs, 'geovpn-ikev2');
			}
			let wg_stat = util.safe_exec(['apk', 'info', '-e', 'geovpn-wireguard']);
			if (wg_stat.code == 0 || fs.stat('/usr/share/ucode/geovpn/drivers/wireguard.uc')) {
				push(installed_pkgs, 'geovpn-wireguard');
			}
			let i18n_stat = util.safe_exec(['apk', 'info', '-e', 'luci-i18n-geovpn-fa']);
			if (i18n_stat.code == 0 || fs.stat('/usr/lib/lua/luci/i18n/geovpn.fa.lmo') || fs.stat('/www/luci-static/resources/cbi/geovpn.fa.json')) {
				push(installed_pkgs, 'luci-i18n-geovpn-fa');
			}
			let meta_stat = util.safe_exec(['apk', 'info', '-e', 'geovpn']);
			if (meta_stat.code == 0) {
				push(installed_pkgs, 'geovpn');
			}

			let tmpdir = fs.mkdtemp('/tmp/geovpn_update.XXXXXX');
			if (!tmpdir) {
				return { error: 'FS_ERROR', message: 'Failed to create temporary directory for update' };
			}

			let downloaded_apks = [];
			for (let pkg in installed_pkgs) {
				let matched_asset = null;
				for (let a in assets) {
					if (!a || !a.name || !match(a.name, /\.apk$/)) continue;
					if (pkg == 'geovpn') {
						if (match(a.name, /^geovpn[-_][0-9]/)) {
							matched_asset = a;
							break;
						}
					} else {
						if (substr(a.name, 0, length(pkg) + 1) == (pkg + '-') ||
						    substr(a.name, 0, length(pkg) + 1) == (pkg + '_')) {
							matched_asset = a;
							break;
						}
					}
				}

				if (matched_asset && matched_asset.url) {
					let dest = tmpdir + '/' + matched_asset.name;
					let dres = util.safe_exec(['curl', '-s', '-L', '-o', dest, matched_asset.url]);
					if (!dres || dres.code != 0 || !fs.stat(dest) || fs.stat(dest).size == 0) {
						dres = util.safe_exec(['wget', '-q', '-O', dest, matched_asset.url]);
					}

					if (fs.stat(dest) && fs.stat(dest).size > 0) {
						push(downloaded_apks, dest);
					}
				}
			}

			if (length(downloaded_apks) == 0) {
				fs.rmdir(tmpdir);
				return { error: 'DOWNLOAD_FAILED', message: 'Failed to download release APK assets' };
			}

			let apk_cmd = ['apk', 'add', '--allow-untrusted'];
			for (let apk_path in downloaded_apks) {
				push(apk_cmd, apk_path);
			}

			let apk_res = util.safe_exec(apk_cmd);

			for (let apk_path in downloaded_apks) {
				fs.unlink(apk_path);
			}
			fs.rmdir(tmpdir);

			if (apk_res.code != 0) {
				return {
					error: 'INSTALL_FAILED',
					message: 'apk add failed: ' + (apk_res.stderr || apk_res.stdout || 'unknown error')
				};
			}

			util.safe_exec(['sh', '-c', '(sleep 2; /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart; /etc/init.d/dnsmasq restart) >/dev/null 2>&1 &']);

			return {
				ok: true,
				version: args.version || 'latest',
				packages_updated: length(downloaded_apks),
				message: 'GeoVPN packages successfully updated. Services restarting.'
			};
		}
	}
};

let all_methods = {};
for (let k in base_methods) all_methods[k] = base_methods[k];
for (let k in ext_methods) all_methods[k] = ext_methods[k];

return {
	'luci.geovpn': all_methods
};
