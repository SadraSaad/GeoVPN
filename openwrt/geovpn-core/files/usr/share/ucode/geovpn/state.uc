//
// GeoVPN State Manager (/var/run/geovpn/)
//
'use strict';

import * as fs from 'fs';

const RUN_DIR = '/var/run/geovpn';
const STATE_FILE = RUN_DIR + '/state.json';
const UPDATE_FILE = RUN_DIR + '/update.json';

function ensure_run_dir() {
	if (!fs.stat(RUN_DIR)) {
		fs.mkdir(RUN_DIR, 0o700);
	}
}

function get_state() {
	ensure_run_dir();
	let content = null;
	try {
		let f = fs.open(STATE_FILE, 'r');
		if (f) {
			content = f.read('all');
			f.close();
		}
	} catch (e) {}

	if (content) {
		try {
			return json(content);
		} catch (e) {}
	}

	return {
		service: { enabled: false, state: 'disabled' },
		tunnel: {
			profile: '',
			name: '',
			device: 'geovpn0',
			since: 0,
			uptime: 0,
			local_ip: '',
			remote_ip: '',
			ipv6: false,
			rx_bytes: 0,
			tx_bytes: 0
		},
		split: {
			mode: 'bypass',
			kill_switch: false,
			nft: false,
			ip_rule: false,
			route_v4: '',
			route_v6: '',
			sets: {},
			counters: { direct_pkts: 0, vpn_pkts: 0 }
		},
		dns: {
			nftset: false,
			confdir: '',
			domains: 0,
			hijack: true
		},
		data: {
			build_id: '',
			updated: 0,
			ok: false,
			stale_days: 0
		},
		warnings: []
	};
}

function update_state(diff) {
	ensure_run_dir();
	let current = get_state();
	if (diff && type(diff) == 'object') {
		for (let k in diff) {
			if (type(diff[k]) == 'object' && type(current[k]) == 'object') {
				for (let sub in diff[k]) {
					current[k][sub] = diff[k][sub];
				}
			} else {
				current[k] = diff[k];
			}
		}
	}

	let tmp_file = STATE_FILE + '.tmp.' + sprintf('%d', time());
	try {
		let f = fs.open(tmp_file, 'w', 0o600);
		if (f) {
			f.write(sprintf('%J\n', current));
			f.close();
			fs.rename(tmp_file, STATE_FILE);
		}
	} catch (e) {
		fs.unlink(tmp_file);
	}
	return current;
}

function get_update_status() {
	ensure_run_dir();
	let content = null;
	try {
		let f = fs.open(UPDATE_FILE, 'r');
		if (f) {
			content = f.read('all');
			f.close();
		}
	} catch (e) {}

	if (content) {
		try {
			return json(content);
		} catch (e) {}
	}

	return {
		running: false,
		step: 'idle',
		done: 0,
		total: 0,
		error: null
	};
}

function update_update_status(diff) {
	ensure_run_dir();
	let current = get_update_status();
	if (diff && type(diff) == 'object') {
		for (let k in diff) {
			current[k] = diff[k];
		}
	}

	let tmp_file = UPDATE_FILE + '.tmp.' + sprintf('%d', time());
	try {
		let f = fs.open(tmp_file, 'w', 0o600);
		if (f) {
			f.write(sprintf('%J\n', current));
			f.close();
			fs.rename(tmp_file, UPDATE_FILE);
		}
	} catch (e) {
		fs.unlink(tmp_file);
	}
	return current;
}

function get_interface_stats(ifname) {
	let rx = 0;
	let tx = 0;
	try {
		let f_rx = fs.open(sprintf('/sys/class/net/%s/statistics/rx_bytes', ifname), 'r');
		if (f_rx) {
			rx = +trim(f_rx.read('all'));
			f_rx.close();
		}
		let f_tx = fs.open(sprintf('/sys/class/net/%s/statistics/tx_bytes', ifname), 'r');
		if (f_tx) {
			tx = +trim(f_tx.read('all'));
			f_tx.close();
		}
	} catch (e) {}
	return { rx_bytes: rx, tx_bytes: tx };
}

export {
	ensure_run_dir,
	get_state,
	update_state,
	get_update_status,
	update_update_status,
	get_interface_stats
};
