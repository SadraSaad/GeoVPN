//
// GeoVPN Policy Routing & Route Management (ip rule / ip route)
//
'use strict';

import * as util from './util.uc';

function apply_routes(main_cfg) {
	let prio = sprintf('%d', main_cfg.rule_priority || 700);
	let table = sprintf('%d', main_cfg.rt_table || 4200);
	let shift = +main_cfg.mark_shift || 24;
	let vpn_mark = sprintf('0x%08x', (1 << shift));
	let mark_mask = sprintf('0x%08x', (0xf << shift));
	let mark_spec = sprintf('%s/%s', vpn_mark, mark_mask);
	let kill_switch = (main_cfg.kill_switch == '1' || main_cfg.kill_switch == true);
	let ipv6_mode = main_cfg.ipv6 || 'auto';

	let undo_journal = [];

	// 1. Remove any stale rules
	util.safe_exec(['ip', '-4', 'rule', 'del', 'priority', prio]);
	util.safe_exec(['ip', '-6', 'rule', 'del', 'priority', prio]);

	// 2. Add IPv4 policy routing rule
	let r4 = util.safe_exec(['ip', '-4', 'rule', 'add', 'priority', prio, 'fwmark', mark_spec, 'lookup', table]);
	if (r4.code != 0) {
		util.log('error', sprintf('Failed to add IPv4 policy rule: %s', r4.stderr));
		rollback(undo_journal);
		return false;
	}
	push(undo_journal, ['ip', '-4', 'rule', 'del', 'priority', prio]);

	// 3. Add IPv6 policy routing rule
	let r6 = util.safe_exec(['ip', '-6', 'rule', 'add', 'priority', prio, 'fwmark', mark_spec, 'lookup', table]);
	if (r6.code != 0) {
		util.log('error', sprintf('Failed to add IPv6 policy rule: %s', r6.stderr));
		rollback(undo_journal);
		return false;
	}
	push(undo_journal, ['ip', '-6', 'rule', 'del', 'priority', prio]);

	// 4. Install kill switch unreachable routes if requested
	if (kill_switch) {
		util.safe_exec(['ip', '-4', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '4000']);
		util.safe_exec(['ip', '-6', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '4000']);
		push(undo_journal, ['ip', '-4', 'route', 'del', 'unreachable', 'default', 'table', table, 'metric', '4000']);
		push(undo_journal, ['ip', '-6', 'route', 'del', 'unreachable', 'default', 'table', table, 'metric', '4000']);
	} else if (ipv6_mode == 'block') {
		// IPv6 block mode installs unreachable v6 route even if kill switch is off
		util.safe_exec(['ip', '-6', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '4000']);
		push(undo_journal, ['ip', '-6', 'route', 'del', 'unreachable', 'default', 'table', table, 'metric', '4000']);
	}

	util.log('info', sprintf('Policy routing installed: table %s, priority %s, mark %s', table, prio, mark_spec));
	return true;
}

function rollback(undo_journal) {
	util.log('warn', 'Rolling back routing changes via undo journal...');
	for (let i = length(undo_journal) - 1; i >= 0; i--) {
		util.safe_exec(undo_journal[i]);
	}
}

function set_tunnel_up(dev, has_ipv6, table_id) {
	let table = sprintf('%d', table_id || 4200);
	util.safe_exec(['ip', '-4', 'route', 'replace', 'default', 'dev', dev, 'table', table, 'metric', '10']);
	if (has_ipv6) {
		util.safe_exec(['ip', '-6', 'route', 'replace', 'default', 'dev', dev, 'table', table, 'metric', '10']);
	}
	util.log('info', sprintf('Default routes for tunnel %s installed in table %s (v6: %s)', dev, table, has_ipv6 ? 'yes' : 'no'));
}

function set_tunnel_down(table_id) {
	let table = sprintf('%d', table_id || 4200);
	util.safe_exec(['ip', '-4', 'route', 'del', 'default', 'table', table, 'metric', '10']);
	util.safe_exec(['ip', '-6', 'route', 'del', 'default', 'table', table, 'metric', '10']);
	util.log('info', sprintf('Default routes removed from table %s', table));
}

function teardown_routes(main_cfg) {
	let prio = sprintf('%d', (main_cfg && main_cfg.rule_priority) ? main_cfg.rule_priority : 700);
	let table = sprintf('%d', (main_cfg && main_cfg.rt_table) ? main_cfg.rt_table : 4200);

	util.safe_exec(['ip', '-4', 'rule', 'del', 'priority', prio]);
	util.safe_exec(['ip', '-6', 'rule', 'del', 'priority', prio]);
	util.safe_exec(['ip', '-4', 'route', 'flush', 'table', table]);
	util.safe_exec(['ip', '-6', 'route', 'flush', 'table', table]);

	util.log('info', sprintf('Routing table %s and priority %s cleared', table, prio));
	return true;
}

export {
	apply_routes,
	set_tunnel_up,
	set_tunnel_down,
	teardown_routes
};
