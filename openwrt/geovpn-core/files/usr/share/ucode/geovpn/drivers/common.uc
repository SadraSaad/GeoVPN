//
// GeoVPN Driver Common Abstraction & Base Contract
//
'use strict';

import * as fs from 'fs';
import * as util from '../util.uc';
import * as openvpn_drv from './openvpn.uc';
import * as wireguard_drv from './wireguard.uc';
import * as ikev2_drv from './ikev2.uc';

/**
 * Creates a normalized context object for driver operations
 * @param {string} kind - 'active' or 'test'
 * @param {string} id - Profile identifier (e.g. 'p12345678')
 * @param {object} [opts] - Optional overrides (dev, table, rundir, ifid, unit, deadline, jid)
 * @returns {object} Context object
 */
function create_context(kind, id, opts) {
	let k = kind || 'active';
	opts = opts || {};
	let rundir_base = getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn';
	return {
		kind: k,
		id: id,
		jid: opts.jid || null,
		proto: opts.proto || 'openvpn',
		dev: opts.dev || (k == 'test' ? 'gvt0' : 'geovpn0'),
		table: opts.table || (k == 'test' ? 4300 : 4200),
		rundir: opts.rundir || (k == 'test' ? (rundir_base + '/test/' + (opts.jid || id)) : rundir_base),
		ifid: opts.ifid || (k == 'test' ? 4300 : 4200),
		unit: opts.unit || (k == 'test' ? 'geovpn-test' : 'geovpn'),
		deadline: opts.deadline || null
	};
}

/**
 * Executes a command safely without shell interpolation, enforcing array argv and output caps
 * @param {array} argv - Command line array
 * @param {object} [opts] - Execution options (input, max_bytes, timeout_s)
 * @returns {object} { ok: boolean, code: number, stdout: string, stderr: string }
 */
function exec(argv, opts) {
	if (type(argv) != 'array') {
		return { ok: false, code: -1, stdout: '', stderr: 'argv must be an array' };
	}
	opts = opts || {};
	let max_bytes = opts.max_bytes || 65536;
	let res = util.safe_exec(argv, opts.input);
	if (res && res.stdout && length(res.stdout) > max_bytes) {
		res.stdout = substr(res.stdout, 0, max_bytes);
	}
	return {
		ok: (res && res.code == 0),
		code: res ? res.code : -1,
		stdout: res ? res.stdout : '',
		stderr: res ? res.stderr : 'Execution failed'
	};
}

/**
 * Journal management for reversible driver and test operations
 */
function create_journal(journal_path) {
	return {
		path: journal_path || null,
		entries: []
	};
}

function journal_record(journal, action_desc, undo_cmd) {
	if (!journal) return;
	push(journal.entries, {
		desc: action_desc,
		undo: undo_cmd,
		ts: time()
	});
}

function journal_rollback(journal) {
	if (!journal || !journal.entries) return;
	for (let i = length(journal.entries) - 1; i >= 0; i--) {
		let entry = journal.entries[i];
		if (entry.undo && type(entry.undo) == 'array') {
			exec(entry.undo);
		}
	}
	journal.entries = [];
}

/**
 * Returns the registered driver instance for the given protocol
 * @param {string} proto - 'openvpn', 'wireguard', 'ikev2'
 * @returns {object|null} Driver module or null if unsupported
 */
function get_driver(proto) {
	let p = proto || 'openvpn';
	if (p == 'openvpn') {
		return openvpn_drv;
	}
	if (p == 'wireguard') {
		return wireguard_drv;
	}
	if (p == 'ikev2') {
		return ikev2_drv;
	}
	return null;
}

/**
 * Lists availability of all supported protocol drivers
 */
function list_drivers() {
	return {
		openvpn: openvpn_drv.available(),
		wireguard: wireguard_drv.available(),
		ikev2: ikev2_drv.available()
	};
}

/**
 * Checks availability of a specific protocol driver
 * @param {string} proto - 'openvpn', 'wireguard', 'ikev2'
 * @returns {object} { ok: boolean, missing: array, note: string }
 */
function available(proto) {
	let p = proto || 'openvpn';
	let drv = get_driver(p);
	if (drv && drv.available) {
		return drv.available();
	}
	return { ok: false, missing: [sprintf('geovpn-%s', p)], note: sprintf('Driver for %s not found or installed', p) };
}

/**
 * Driver interface dispatchers implementing the base contract (§6.2 / FR-28)
 */
function start(ctx, profile, creds) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let proto = ctx.proto || (profile && profile.proto) || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.start) {
		return { ok: false, err: sprintf('Driver for %s not found or does not support start', proto) };
	}
	return drv.start(ctx, profile, creds);
}

function stop(ctx) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let proto = ctx.proto || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.stop) {
		return { ok: false, err: sprintf('Driver for %s not found or does not support stop', proto) };
	}
	return drv.stop(ctx);
}

function facts(ctx) {
	if (!ctx) return null;
	let proto = ctx.proto || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.facts) {
		return null;
	}
	return drv.facts(ctx);
}

function prepare(ctx, profile, cfg) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let proto = ctx.proto || (profile && profile.proto) || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.prepare) {
		return { ok: false, err: sprintf('Driver for %s not found or does not support prepare', proto) };
	}
	return drv.prepare(ctx, profile, cfg);
}

function cleanup(ctx) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let proto = ctx.proto || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.cleanup) {
		return { ok: false, err: sprintf('Driver for %s not found or does not support cleanup', proto) };
	}
	return drv.cleanup(ctx);
}

function refresh(ctx) {
	if (!ctx) return { ok: false, err: 'Context required' };
	let proto = ctx.proto || 'openvpn';
	let drv = get_driver(proto);
	if (!drv || !drv.refresh) {
		return { ok: false, err: sprintf('Driver for %s not found or does not support refresh', proto) };
	}
	return drv.refresh(ctx);
}

function endpoints(arg1, arg2) {
	let profile = (type(arg1) == 'object') ? arg1 : arg2;
	let proto = (type(arg1) == 'string') ? arg1 : ((type(arg2) == 'string') ? arg2 : (profile ? profile.proto : null));
	let p = proto || 'openvpn';
	let drv = get_driver(p);
	if (!drv || !drv.endpoints) return [];
	return drv.endpoints(profile);
}

function validate(profile, cfg, proto) {
	let p = proto || (profile && profile.proto) || 'openvpn';
	let drv = get_driver(p);
	if (!drv || !drv.validate) return { errors: ['Driver not found'], warnings: [] };
	return drv.validate(profile, cfg);
}

export {
	create_context,
	exec,
	create_journal,
	journal_record,
	journal_rollback,
	get_driver,
	list_drivers,
	available,
	start,
	stop,
	facts,
	prepare,
	cleanup,
	refresh,
	endpoints,
	validate
};
