//
// GeoVPN Data Pipeline, Pack Verification & Atomic Updater
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';
import * as state from './state.uc';

const DATA_DIR = '/etc/geovpn/data';
const DATA_NEW = '/etc/geovpn/data.new';
const DATA_PREV = '/etc/geovpn/data.prev';
const LOCK_FILE = '/var/run/geovpn/update.lock';
const STATE_RECORD = DATA_DIR + '/STATE';

function ensure_data_dirs() {
	if (!fs.stat(DATA_DIR)) {
		fs.mkdir(DATA_DIR, 0o755);
		fs.mkdir(DATA_DIR + '/ip', 0o755);
		fs.mkdir(DATA_DIR + '/site', 0o755);
		fs.mkdir(DATA_DIR + '/catalog', 0o755);
	}
}

function parse_tsv(content) {
	let rows = [];
	let lines = split(content, '\n');
	for (let line in lines) {
		let l = trim(line);
		if (length(l) == 0 || l[0] == '#') continue;
		push(rows, split(l, '\t'));
	}
	return rows;
}

function sha256_file(path) {
	let res = util.safe_exec(['sha256sum', path]);
	if (res.code == 0 && res.stdout) {
		return split(res.stdout, ' ')[0];
	}
	return null;
}

function update_cron_schedule(main_cfg, data_cfg) {
	let enabled = (main_cfg.enabled == '1' || main_cfg.enabled == true);
	let auto_update = (data_cfg.auto_update != '0' && data_cfg.auto_update != false);
	let cron_expr = data_cfg.update_cron || '17 4 * * *';
	let crontab_path = '/etc/crontabs/root';

	let existing = '';
	let f = fs.open(crontab_path, 'r');
	if (f) {
		existing = f.read('all') || '';
		f.close();
	}

	let lines = split(existing, '\n');
	let clean_lines = [];
	let in_block = false;

	for (let line in lines) {
		if (trim(line) == '# geovpn begin') {
			in_block = true;
			continue;
		}
		if (trim(line) == '# geovpn end') {
			in_block = false;
			continue;
		}
		if (!in_block && length(trim(line)) > 0) {
			push(clean_lines, line);
		}
	}

	if (enabled && auto_update && util.is_cron_expr(cron_expr)) {
		push(clean_lines, '# geovpn begin');
		push(clean_lines, sprintf('%s /usr/libexec/geovpn/spawn update --cron', cron_expr));
		push(clean_lines, '# geovpn end');
	}

	let new_content = join('\n', clean_lines) + '\n';
	if (new_content != existing) {
		let out = fs.open(crontab_path + '.tmp', 'w', 0o600);
		if (out) {
			out.write(new_content);
			out.close();
			fs.rename(crontab_path + '.tmp', crontab_path);
			util.safe_exec(['/etc/init.d/cron', 'restart']);
			util.log('info', 'Updated cron schedule for automated GeoVPN updates');
		}
	}
}

function run_update(force) {
	ensure_data_dirs();

	// Check lock
	if (fs.stat(LOCK_FILE)) {
		util.log('warn', 'Update already in progress (lock exists)');
		return 1;
	}

	let lock_f = fs.open(LOCK_FILE, 'w', 0o600);
	if (lock_f) {
		lock_f.write(sprintf('%d\n', time()));
		lock_f.close();
	}

	state.update_update_status({ running: true, step: 'starting', done: 0, total: 10, error: null });

	let cursor = uci.cursor();
	cursor.load('geovpn');
	let data_cfg = cursor.get_all('geovpn', 'data') || {};
	let main_cfg = cursor.get_all('geovpn', 'main') || {};

	let base_url = data_cfg.source_url || 'https://geovpn.github.io/geovpn-data/v1/';
	if (substr(base_url, length(base_url) - 1, 1) != '/') {
		base_url += '/';
	}

	let do_verify = (data_cfg.verify != '0' && data_cfg.verify != false);
	let pubkey_path = data_cfg.pack_pubkey || '/etc/geovpn/keys/pack.pub';

	try {
		// Clean staging directory
		util.safe_exec(['rm', '-rf', DATA_NEW]);
		fs.mkdir(DATA_NEW, 0o755);
		fs.mkdir(DATA_NEW + '/ip', 0o755);
		fs.mkdir(DATA_NEW + '/site', 0o755);
		fs.mkdir(DATA_NEW + '/catalog', 0o755);

		state.update_update_status({ step: 'download_manifest', done: 1 });

		// 1. Fetch MANIFEST
		let manifest_url = base_url + 'MANIFEST';
		let manifest_tmp = DATA_NEW + '/MANIFEST';
		let f_res = util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', manifest_tmp, manifest_url]);
		if (f_res.code != 0 || !fs.stat(manifest_tmp)) {
			// If online fetch fails, check if local fixture/seed exists
			let local_seed = '/usr/share/geovpn/seed_manifest';
			if (!fs.stat(local_seed)) {
				throw sprintf('Failed to download MANIFEST from %s', manifest_url);
			}
		}

		// 2. Signature verification
		if (do_verify) {
			state.update_update_status({ step: 'verify_signature', done: 2 });
			let sig_url = base_url + 'MANIFEST.sig';
			let sig_tmp = DATA_NEW + '/MANIFEST.sig';
			util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', sig_tmp, sig_url]);

			if (fs.stat(sig_tmp) && fs.stat(pubkey_path)) {
				let v_res = util.safe_exec(['usign', '-V', '-m', manifest_tmp, '-p', pubkey_path, '-x', sig_tmp]);
				if (v_res.code != 0) {
					util.log('warn', 'usign verification failed on MANIFEST; checking downgrade or verification policy');
					if (!force) {
						throw 'Manifest cryptographic signature verification failed';
					}
				}
			}
		}

		// 3. Parse MANIFEST
		let man_f = fs.open(manifest_tmp, 'r');
		if (!man_f) throw 'Cannot read MANIFEST';
		let man_lines = split(man_f.read('all'), '\n');
		man_f.close();

		let manifest = {};
		for (let line in man_lines) {
			let parts = split(line, '=');
			if (length(parts) >= 2) {
				manifest[trim(parts[0])] = trim(join('=', slice(parts, 1)));
			}
		}

		let build_id = manifest.build_id || 'unknown';
		let build_time = +manifest.build_time || 0;

		// Monotonic check against stored state
		let stored_state = {};
		let st_f = fs.open(STATE_RECORD, 'r');
		if (st_f) {
			let st_lines = split(st_f.read('all'), '\n');
			st_f.close();
			for (let l in st_lines) {
				let p = split(l, '=');
				if (length(p) >= 2) stored_state[trim(p[0])] = trim(p[1]);
			}
		}

		let stored_time = +stored_state.build_time || 0;
		if (!force && stored_time > 0 && build_time > 0 && build_time < stored_time) {
			throw sprintf('Downgrade rejected: manifest build_time %d is older than current %d', build_time, stored_time);
		}

		state.update_update_status({ step: 'download_catalogs', done: 4 });

		// 4. Download catalogs
		let geoip_cat_file = DATA_NEW + '/catalog/geoip.tsv';
		let geosite_cat_file = DATA_NEW + '/catalog/geosite.tsv';
		util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', geoip_cat_file, base_url + 'catalog/geoip.tsv']);
		util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', geosite_cat_file, base_url + 'catalog/geosite.tsv']);

		// Verify catalog hashes
		if (manifest.geoip_catalog_sha256 && sha256_file(geoip_cat_file) != manifest.geoip_catalog_sha256) {
			throw 'GeoIP catalog hash mismatch';
		}
		if (manifest.geosite_catalog_sha256 && sha256_file(geosite_cat_file) != manifest.geosite_catalog_sha256) {
			throw 'GeoSite catalog hash mismatch';
		}

		state.update_update_status({ step: 'download_categories', done: 6 });

		// 5. Selectively download selected categories
		let all_sections = cursor.get_all('geovpn');
		for (let sname in all_sections) {
			let s = all_sections[sname];
			if (s['.type'] == 'geoip' && s.enabled != '0' && s.code) {
				let code = lc(s.code);
				if (code == 'private') continue; // built-in
				let v4_dest = sprintf('%s/ip/%s.v4.txt', DATA_NEW, code);
				let v6_dest = sprintf('%s/ip/%s.v6.txt', DATA_NEW, code);
				util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', v4_dest, sprintf('%sip/%s.v4.txt', base_url, code)]);
				util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', v6_dest, sprintf('%sip/%s.v6.txt', base_url, code)]);
			} else if (s['.type'] == 'geosite' && s.enabled != '0' && s.name) {
				let name = lc(s.name);
				let site_dest = sprintf('%s/site/%s.txt', DATA_NEW, name);
				util.safe_exec(['uclient-fetch', '-q', '-T', '20', '-O', site_dest, sprintf('%ssite/%s.txt', base_url, name)]);
			}
		}

		state.update_update_status({ step: 'validating_data', done: 8 });

		// 6. Validate downloaded files
		let ip_files = fs.glob(DATA_NEW + '/ip/*.txt');
		for (let ipf in ip_files) {
			let f = fs.open(ipf, 'r');
			if (f) {
				let lines = split(f.read('all'), '\n');
				f.close();
				let invalid = 0;
				let total = 0;
				for (let line in lines) {
					let l = trim(line);
					if (length(l) == 0) continue;
					total++;
					if (!util.is_cidr(l) && !util.is_ip(l)) invalid++;
				}
				if (total > 0 && (invalid / total) > 0.005) {
					throw sprintf('File %s has >0.5%% invalid lines (%d/%d)', ipf, invalid, total);
				}
			}
		}

		state.update_update_status({ step: 'atomic_swap', done: 9 });

		// 7. Atomic Swap: DATA_DIR -> DATA_PREV, DATA_NEW -> DATA_DIR
		util.safe_exec(['rm', '-rf', DATA_PREV]);
		util.safe_exec(['cp', '-r', DATA_DIR, DATA_PREV]);
		util.safe_exec(['cp', '-r', DATA_NEW + '/.', DATA_DIR]);

		// Write new STATE record
		let st_out = fs.open(STATE_RECORD, 'w', 0o644);
		if (st_out) {
			st_out.write(sprintf('build_id=%s\nbuild_time=%d\nupdated=%d\n', build_id, build_time, time()));
			st_out.close();
		}

		// Update runtime state
		state.update_state({
			data: {
				build_id: build_id,
				updated: time(),
				ok: true,
				stale_days: 0
			}
		});

		state.update_update_status({ running: false, step: 'done', done: 10, total: 10, error: null });
		util.log('info', sprintf('GeoVPN data updated successfully to build %s', build_id));
		fs.unlink(LOCK_FILE);
		return 0;

	} catch (err) {
		util.log('error', sprintf('Data update failed: %s', err));

		// Rollback if data.prev exists
		if (fs.stat(DATA_PREV)) {
			util.log('warn', 'Rolling back data directory to previous snapshot...');
			util.safe_exec(['cp', '-r', DATA_PREV + '/.', DATA_DIR]);
		}

		state.update_update_status({ running: false, step: 'failed', error: sprintf('%s', err) });
		fs.unlink(LOCK_FILE);
		return 1;
	}
}

export {
	ensure_data_dirs,
	parse_tsv,
	sha256_file,
	update_cron_schedule,
	run_update,
	DATA_DIR
};
