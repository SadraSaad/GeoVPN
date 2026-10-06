//
// GeoVPN Firewall4 Zone & Forwarding Integration via UCI
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as util from './util.uc';

const BACKUP_DIR = '/etc/geovpn/backup';

function backup_firewall() {
	if (!fs.stat(BACKUP_DIR)) {
		fs.mkdir(BACKUP_DIR, 0o700);
	}
	let timestamp = sprintf('%d', time());
	let backup_file = BACKUP_DIR + '/firewall.' + timestamp;
	let src = fs.open('/etc/config/firewall', 'r');
	if (src) {
		let data = src.read('all');
		src.close();
		let dst = fs.open(backup_file, 'w', 0o600);
		if (dst) {
			dst.write(data);
			dst.close();
			util.log('info', sprintf('Firewall configuration backed up to %s', backup_file));
		}
	}
}

function ensure_firewall_zone(main_cfg) {
	let tun_dev = main_cfg.tun_dev || 'geovpn0';
	let lan_zones = main_cfg.lan_zones || ['lan'];
	if (type(lan_zones) != 'array') lan_zones = [lan_zones];

	let cursor = uci.cursor();
	cursor.load('firewall');

	// Check if this is the first edit and back up if so
	let existing_zone = cursor.get('firewall', 'geovpn_zone');
	if (!existing_zone) {
		backup_firewall();
	}

	let changed = false;

	// 1. Configure geovpn zone
	let zone = cursor.get('firewall', 'geovpn_zone');
	if (!zone) {
		cursor.set('firewall', 'geovpn_zone', 'zone');
		cursor.set('firewall', 'geovpn_zone', 'name', 'geovpn');
		cursor.set('firewall', 'geovpn_zone', 'device', [tun_dev]);
		cursor.set('firewall', 'geovpn_zone', 'input', 'REJECT');
		cursor.set('firewall', 'geovpn_zone', 'output', 'ACCEPT');
		cursor.set('firewall', 'geovpn_zone', 'forward', 'REJECT');
		cursor.set('firewall', 'geovpn_zone', 'masq', '1');
		cursor.set('firewall', 'geovpn_zone', 'mtu_fix', '1');
		changed = true;
	}

	// 2. Configure forwardings from each LAN zone to geovpn
	for (let lz in lan_zones) {
		let fwd_name = sprintf('geovpn_fwd_%s', lz);
		let fwd = cursor.get('firewall', fwd_name);
		if (!fwd) {
			cursor.set('firewall', fwd_name, 'forwarding');
			cursor.set('firewall', fwd_name, 'src', lz);
			cursor.set('firewall', fwd_name, 'dest', 'geovpn');
			changed = true;
		}
	}

	if (changed) {
		cursor.commit('firewall');
		util.log('info', 'Firewall UCI updated for GeoVPN zone');
		util.safe_exec(['fw4', 'reload']);
	}

	return true;
}

function remove_firewall_zone(main_cfg) {
	let lan_zones = (main_cfg && main_cfg.lan_zones) ? main_cfg.lan_zones : ['lan'];
	if (type(lan_zones) != 'array') lan_zones = [lan_zones];

	let cursor = uci.cursor();
	cursor.load('firewall');

	let changed = false;
	if (cursor.get('firewall', 'geovpn_zone')) {
		cursor.delete('firewall', 'geovpn_zone');
		changed = true;
	}

	for (let lz in lan_zones) {
		let fwd_name = sprintf('geovpn_fwd_%s', lz);
		if (cursor.get('firewall', fwd_name)) {
			cursor.delete('firewall', fwd_name);
			changed = true;
		}
	}

	if (changed) {
		cursor.commit('firewall');
		util.log('info', 'GeoVPN firewall zones and forwardings removed');
		util.safe_exec(['fw4', 'reload']);
	}

	return true;
}

export {
	ensure_firewall_zone,
	remove_firewall_zone,
	backup_firewall
};
