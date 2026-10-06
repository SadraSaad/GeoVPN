//
// GeoVPN rpcd ucode plugin (luci.geovpn object)
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from '/usr/share/ucode/geovpn/util.uc';
import * as cfg from '/usr/share/ucode/geovpn/config.uc';
import * as state from '/usr/share/ucode/geovpn/state.uc';
import * as parse from '/usr/share/ucode/geovpn/ovpn_parse.uc';
import * as diag from '/usr/share/ucode/geovpn/diag.uc';

return {
	'luci.geovpn': {
		status: {
			call: function(req) {
				let s = state.get_state();
				let cursor = uci.cursor();
				cursor.load('geovpn');
				s.service.enabled = cursor.get('geovpn', 'main', 'enabled') == '1';
				s.service.active_profile = cursor.get('geovpn', 'main', 'active_profile') || '';

				if (s.service.active_profile) {
					let p = cfg.get_profile(s.service.active_profile);
					if (p) s.tunnel.name = p.name || s.service.active_profile;
				}

				let ifstats = state.get_interface_stats(s.tunnel.device || 'geovpn0');
				s.tunnel.rx_bytes = ifstats.rx_bytes;
				s.tunnel.tx_bytes = ifstats.tx_bytes;

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

				let res = parse.parse_ovpn(content, name);
				if (!res.ok) {
					return { error: 'PARSE_ERROR', message: res.error };
				}

				let id = cfg.create_profile(res.profile);
				return {
					ok: true,
					id: id,
					name: res.profile.name,
					warnings: res.profile.warnings,
					ignored: res.profile.ignored,
					incomplete: res.profile.incomplete
				};
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
				let allowed_roles = ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'extra-certs'];
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
				let f = fs.open(cat_file, 'r');
				if (!f) {
					return { total: 0, items: [], pack: { build_id: 'none' } };
				}
				let content = f.read('all') || '';
				f.close();

				let lines = split(content, '\n');
				let matched = [];

				for (let line in lines) {
					let l = trim(line);
					if (length(l) == 0 || l[0] == '#') continue;
					let parts = split(l, '\t');
					let name = parts[0];
					if (length(q) > 0 && index(name, q) == -1) continue;

					let count = (length(parts) > 1) ? +parts[1] : 0;
					let est_ram = (kind == 'geoip') ? sprintf('%.1f MB', (count * 64) / 1048576) : sprintf('%.1f MB', (count * 150) / 1048576);

					push(matched, {
						name: name,
						count: count,
						count_v6: (kind == 'geoip' && length(parts) > 2) ? +parts[2] : 0,
						est_ram: est_ram
					});
				}

				let total = length(matched);
				let paged = slice(matched, offset, offset + limit);

				return {
					total: total,
					offset: offset,
					limit: limit,
					items: paged
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
	}
};
