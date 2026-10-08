//
// GeoVPN Auto-Connect, Health Tick & Failover Engine (§7.7, §11 A6 / FR-40, FR-41 / AT-32, AT-33)
// Strictly adheres to C-05: Periodic cron tick execution (NO resident daemon process).
//
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as math from 'math';
import * as util from './util.uc';
import * as cfg from './config.uc';
import * as state from './state.uc';
import * as route from './route.uc';
import * as drv_common from './drivers/common.uc';
import * as te from './test_engine.uc';

const DEFAULT_HEALTH_INTERVAL = 120; // seconds (multiples of 60s)
const DEFAULT_FAIL_THRESHOLD = 3;   // consecutive failures before failover
const DEFAULT_DOWN_GRACE = 30;       // seconds down before failover
const DEFAULT_MIN_SWITCH_INTERVAL = 60; // seconds minimum between switches
const DEFAULT_MAX_SWITCHES_PER_HOUR = 6;
const DEFAULT_TEST_TTL = 300;        // seconds a test pass stays valid
const DEFAULT_FAILOVER_MAX_CANDIDATES = 3;
const BACKOFF_INTERVALS = [60, 120, 240, 480, 960, 1800]; // 1, 2, 4, 8, 16, 30 min (capped at 1800s)

function get_run_dir() {
	return getenv('GEOVPN_RUN_DIR') || '/var/run/geovpn';
}

function get_health_file() {
	return get_run_dir() + '/health.json';
}

function get_health_lock_file() {
	return get_run_dir() + '/health.lock';
}

function load_health_state() {
	let hfile = get_health_file();
	let def = {
		fail_count: 0,
		down_since: 0,
		last_tick: 0,
		last_switch: 0,
		switch_history: [],
		backoff_step: 0,
		backoff_until: 0,
		primary_pass_ticks: 0,
		original_primary: null,
		last_health: {
			status: 'unknown',
			reason: null,
			hint: null,
			handshake_ms: null,
			latency_ms: null,
			loss_pct: null,
			http_probe: null,
			timestamp: 0
		},
		alerts: []
	};

	if (!fs.stat(hfile)) return def;
	let f = fs.open(hfile, 'r');
	if (!f) return def;
	let content = f.read('all');
	f.close();

	try {
		let parsed = json(content);
		if (parsed && type(parsed) == 'object') {
			parsed.switch_history = (parsed.switch_history && type(parsed.switch_history) == 'array') ? parsed.switch_history : [];
			parsed.alerts = (parsed.alerts && type(parsed.alerts) == 'array') ? parsed.alerts : [];
			parsed.last_health = (parsed.last_health && type(parsed.last_health) == 'object') ? parsed.last_health : def.last_health;
			return parsed;
		}
	} catch (e) {}

	return def;
}

function save_health_state(st) {
	let rdir = get_run_dir();
	if (!fs.stat(rdir)) fs.mkdir(rdir, 0o755);
	let hfile = get_health_file();
	let tmp = hfile + '.tmp';
	let f = fs.open(tmp, 'w', 0o600);
	if (!f) return false;
	f.write(sprintf('%J\n', st));
	f.close();
	fs.rename(tmp, hfile);
	return true;
}

function acquire_health_lock() {
	let rdir = get_run_dir();
	if (!fs.stat(rdir)) fs.mkdir(rdir, 0o755);
	let lfile = get_health_lock_file();

	// Check existing lock and freshness
	if (fs.stat(lfile)) {
		let st = fs.stat(lfile);
		let now = time();
		// Stale lock expiry after 60s, or clock stepped backward (mtime > now)
		if (st && ((now - st.mtime > 60) || (st.mtime > now))) {
			fs.unlink(lfile);
		} else {
			return false; // Locked by another tick
		}
	}

	let f = fs.open(lfile, 'w', 0o600);
	if (!f) return false;
	f.write(sprintf('%d\n', time()));
	f.close();
	return true;
}

function release_health_lock() {
	let lfile = get_health_lock_file();
	if (fs.stat(lfile)) fs.unlink(lfile);
}

// ----------------------------------------------------------------------------
// Candidate Endpoint Resolution & Direct Sets (§7.7)
// ----------------------------------------------------------------------------

function resolve_hosts_to_ips(hosts) {
	let ips_v4 = [];
	let ips_v6 = [];

	for (let h in hosts) {
		if (!h) continue;
		if (util.is_ipv4(h)) {
			push(ips_v4, h);
		} else if (util.is_ipv6(h)) {
			push(ips_v6, h);
		} else {
			// Resolve hostname
			let res = util.safe_exec(['nslookup', h]);
			if (res && res.code == 0 && res.stdout) {
				let lines = split(res.stdout, '\n');
				for (let line in lines) {
					let m4 = match(line, /Address[ 0-9]*:?\s+([0-9.]+)/);
					if (m4 && util.is_ipv4(m4[1]) && m4[1] != '127.0.0.1') push(ips_v4, m4[1]);
					let m6 = match(line, /Address[ 0-9]*:?\s+([0-9a-fA-F:]+)/);
					if (m6 && util.is_ipv6(m6[1]) && m6[1] != '::1') push(ips_v6, m6[1]);
				}
			}
			if (length(ips_v4) == 0 && length(ips_v6) == 0) {
				let gres = util.safe_exec(['getent', 'hosts', h]);
				if (gres && gres.code == 0 && gres.stdout) {
					let glines = split(gres.stdout, '\n');
					for (let line in glines) {
						let parts = split(trim(line), /[ \t]+/);
						if (parts && parts[0]) {
							if (util.is_ipv4(parts[0]) && parts[0] != '127.0.0.1') push(ips_v4, parts[0]);
							else if (util.is_ipv6(parts[0]) && parts[0] != '::1') push(ips_v6, parts[0]);
						}
					}
				}
			}
		}
	}

	return { v4: ips_v4, v6: ips_v6 };
}

function add_endpoint_ips_direct(profile_id) {
	let p = cfg.get_profile(profile_id);
	if (!p) return;

	let hosts = [];
	let known_ips = [];

	let eps = drv_common.endpoints(p);
	if (eps && length(eps) > 0) {
		for (let ep in eps) {
			if (ep.host) push(hosts, ep.host);
			if (ep.ips && length(ep.ips) > 0) {
				for (let ip in ep.ips) push(known_ips, ip);
			}
		}
	}

	if (p.proto == 'wireguard' && p.wg_endpoint_host) {
		push(hosts, p.wg_endpoint_host);
	} else if (p.proto == 'ikev2' && p.ike_host) {
		push(hosts, p.ike_host);
	} else if (p.remotes || p.remote) {
		let rem_list = p.remotes || p.remote;
		if (type(rem_list) == 'string') rem_list = [rem_list];
		for (let r in rem_list) {
			let h = split(r, ' ')[0];
			if (h) push(hosts, h);
		}
	}

	let resolved = resolve_hosts_to_ips(hosts);

	// Fallback to cached test results or known IPs if DNS resolution fails/times out
	let cached = te.get_cached_results([profile_id]);
	if (cached && length(cached) > 0 && cached[0].endpoint_ip) {
		let cip = cached[0].endpoint_ip;
		if (util.is_ipv4(cip)) push(resolved.v4, cip);
		else if (util.is_ipv6(cip)) push(resolved.v6, cip);
	}
	for (let kip in known_ips) {
		if (util.is_ipv4(kip)) push(resolved.v4, kip);
		else if (util.is_ipv6(kip)) push(resolved.v6, kip);
	}

	for (let ip in resolved.v4) {
		util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', 'always4', sprintf('{ %s }', ip)]);
		util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', 'always4_dyn', sprintf('{ %s }', ip)]);
	}

	for (let ip in resolved.v6) {
		util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', 'always6', sprintf('{ %s }', ip)]);
		util.safe_exec(['nft', 'add', 'element', 'inet', 'geovpn', 'always6_dyn', sprintf('{ %s }', ip)]);
	}
}

// ----------------------------------------------------------------------------
// Rate Limiting & Cooldown Calculations (§7.7)
// ----------------------------------------------------------------------------

function get_recent_switches_count(history, now, window_seconds) {
	let cutoff = now - (window_seconds || 3600);
	let count = 0;
	if (!history || type(history) != 'array') return 0;
	for (let ts in history) {
		if (+ts >= cutoff) count++;
	}
	return count;
}

function prune_switch_history(history, now) {
	let cutoff = now - 3600;
	let pruned = [];
	if (!history || type(history) != 'array') return pruned;
	for (let ts in history) {
		if (+ts >= cutoff) push(pruned, +ts);
	}
	return pruned;
}

// ----------------------------------------------------------------------------
// Tunnel Switch Execution (§7.7)
// ----------------------------------------------------------------------------

function switch_active_tunnel(target_profile_id, persist, config) {
	if (!util.is_profile_id(target_profile_id)) return { ok: false, error: 'invalid_id' };
	let p = cfg.get_profile(target_profile_id);
	if (!p) return { ok: false, error: 'profile_not_found' };

	// 1. Add candidate endpoint IPs to always-direct sets BEFORE switch (§7.7)
	add_endpoint_ips_direct(target_profile_id);

	// 2. Persist to UCI if persist=1, else write active_override file
	let rundir = get_run_dir();
	let ov_file = rundir + '/active_override';

	if (persist) {
		let confdir = getenv('UCI_CONFIG_DIR');
		let cursor = confdir ? uci.cursor(confdir) : uci.cursor();
		cursor.load('geovpn');
		cursor.set('geovpn', 'main', 'active_profile', target_profile_id);
		cursor.commit('geovpn');
		if (fs.stat(ov_file)) fs.unlink(ov_file);
	} else {
		if (!fs.stat(rundir)) fs.mkdir(rundir, 0o755);
		let f = fs.open(ov_file, 'w', 0o600);
		if (f) {
			f.write(target_profile_id + '\n');
			f.close();
		}
	}

	// 3. Break-before-make: Restart service with new profile
	let init_script = getenv('GEOVPN_INIT_SCRIPT') || '/etc/init.d/geovpn';
	util.safe_exec([init_script, 'restart']);

	return { ok: true, id: target_profile_id, persist: !!persist };
}

function manual_switch(target_profile_id, persist) {
	if (!util.is_profile_id(target_profile_id)) {
		return { ok: false, error: 'INVALID_ID', message: 'Invalid profile ID' };
	}

	let c = cfg.load_config();
	let p = cfg.get_profile(target_profile_id);
	if (!p) {
		return { ok: false, error: 'NOT_FOUND', message: 'Target profile not found' };
	}

	let now = time();
	let auto_cfg = c.autoconnect || {};
	let connect_gate = auto_cfg.connect_gate || 'off';
	let test_ttl = +auto_cfg.test_ttl || DEFAULT_TEST_TTL;

	// Honor connect_gate policy (§7.7)
	if (connect_gate == 'require' || connect_gate == 'warn') {
		let recent = te.get_cached_results([target_profile_id]);
		let has_pass = false;
		if (recent && length(recent) > 0) {
			let r0 = recent[0];
			if ((r0.status == 'pass' || r0.status == 'warn') && (now - (r0.tested_at || 0) <= test_ttl)) {
				has_pass = true;
			}
		}

		if (!has_pass) {
			let test_res = te.test_profile(target_profile_id);
			if (!test_res || (test_res.status != 'pass' && test_res.status != 'warn')) {
				if (connect_gate == 'require') {
					return {
						ok: false,
						error: 'CONNECT_GATE_FAILED',
						message: sprintf('Pre-connection test failed (%s: %s). Switch aborted because connect_gate=require',
							test_res ? test_res.reason : 'unknown',
							test_res ? test_res.hint : 'failed'),
						reason: test_res ? test_res.reason : 'test_failed'
					};
				} else {
					util.log('warn', sprintf('Pre-connection test warned on profile %s: %s', target_profile_id, test_res ? test_res.hint : 'warn'));
				}
			}
		}
	}

	let should_persist = (persist != null) ? !!persist : (auto_cfg.persist_switch == '1' || auto_cfg.persist_switch == true);
	let sw_res = switch_active_tunnel(target_profile_id, should_persist, c);
	if (!sw_res.ok) return sw_res;

	// Update health state
	let st = load_health_state();
	st.last_switch = now;
	st.switch_history = prune_switch_history(st.switch_history, now);
	push(st.switch_history, now);
	st.fail_count = 0;
	st.down_since = 0;
	st.backoff_step = 0;
	st.backoff_until = 0;
	st.primary_pass_ticks = 0;
	st.original_primary = null;
	st.alerts = [sprintf('Manually switched active tunnel to %s', target_profile_id)];
	save_health_state(st);

	return { ok: true, id: target_profile_id, persisted: should_persist };
}

// ----------------------------------------------------------------------------
// Health Tick & Automated Failover Algorithm (§7.7)
// ----------------------------------------------------------------------------

function run_health_tick(opts) {
	let options = opts || {};
	let force = !!options.force;

	if (!acquire_health_lock()) {
		return { ok: false, skipped: true, reason: 'locked', message: 'Health tick currently locked by active check' };
	}

	let now = time();
	let c = cfg.load_config();
	let main_cfg = c.main || {};
	let auto_cfg = c.autoconnect || {};

	if (main_cfg.enabled != '1' && main_cfg.enabled != true) {
		release_health_lock();
		return { ok: true, skipped: true, reason: 'service_disabled', message: 'GeoVPN service is disabled' };
	}

	let st = load_health_state();
	st.switch_history = prune_switch_history(st.switch_history, now);

	// Check exponential backoff timer
	if (!force && st.backoff_until) {
		if (now < st.backoff_until) {
			let remaining = st.backoff_until - now;
			if (remaining > 1800) {
				st.backoff_until = now + 60;
				remaining = 60;
			}
			save_health_state(st);
			release_health_lock();
			return { ok: true, skipped: true, reason: 'in_backoff', message: sprintf('In backoff cooldown (%ds remaining)', remaining), remaining: remaining };
		}
	}

	// Check tick interval gating
	let interval = +auto_cfg.health_interval || DEFAULT_HEALTH_INTERVAL;
	if (!force && st.last_tick && (now - st.last_tick < (interval - 5))) {
		release_health_lock();
		return { ok: true, skipped: true, reason: 'interval_not_reached', message: 'Health check interval not yet reached' };
	}

	st.last_tick = now;

	let active_id = cfg.get_effective_active_profile_id(c);
	if (!active_id) {
		st.last_health = {
			status: 'down',
			reason: 'no_active_profile',
			hint: 'No active profile configured',
			timestamp: now
		};
		save_health_state(st);
		release_health_lock();
		return { ok: true, health: st.last_health, message: 'No active profile' };
	}

	let active_profile = cfg.get_profile(active_id);
	if (!active_profile) {
		st.last_health = {
			status: 'down',
			reason: 'active_profile_not_found',
			hint: sprintf('Active profile %s not found in configuration', active_id),
			timestamp: now
		};
		save_health_state(st);
		release_health_lock();
		return { ok: true, health: st.last_health, message: 'Active profile not found' };
	}

	// 1. Live health assessment (handshake, latency, packet loss, HTTP probe)
	let live_res = te.run_live_check(active_profile, null, active_id);
	let is_pass = (live_res && live_res.status == 'pass');
	let is_warn = (live_res && live_res.status == 'warn');

	let health_status = 'healthy';
	if (!is_pass) {
		if (is_warn) {
			health_status = 'degraded';
		} else if (live_res.reason == 'active_tunnel_down' || live_res.reason == 'no_handshake') {
			health_status = 'down';
		} else {
			health_status = 'failing';
		}
	}

	st.last_health = {
		status: health_status,
		reason: live_res.reason,
		hint: live_res.hint,
		handshake_ms: live_res.handshake_ms,
		latency_ms: (live_res.url && live_res.url.median_ms != null) ? live_res.url.median_ms : null,
		loss_pct: (live_res.url && live_res.url.loss_pct != null) ? live_res.url.loss_pct : null,
		http_probe: (live_res.url && live_res.url.ok > 0),
		timestamp: now
	};

	let failover_enabled = (auto_cfg.failover == '1' || auto_cfg.failover == true);
	let fail_threshold = +auto_cfg.fail_threshold || DEFAULT_FAIL_THRESHOLD;
	let down_grace = +auto_cfg.down_grace || DEFAULT_DOWN_GRACE;
	let min_switch_interval = +auto_cfg.min_switch_interval || DEFAULT_MIN_SWITCH_INTERVAL;
	let max_switches_per_hour = +auto_cfg.max_switches_per_hour || DEFAULT_MAX_SWITCHES_PER_HOUR;
	let test_ttl = +auto_cfg.test_ttl || DEFAULT_TEST_TTL;
	let persist_switch = (auto_cfg.persist_switch == '1' || auto_cfg.persist_switch == true);
	let failback_enabled = (auto_cfg.failback == '1' || auto_cfg.failback == true);
	let current_override = cfg.get_active_override();

	// 2. Health Hysteresis & State Updates
	if (health_status == 'healthy') {
		st.fail_count = 0;
		st.down_since = 0;
		st.backoff_step = 0;
		st.backoff_until = 0;

		// Failback evaluation (§7.7)
		let primary_id = st.original_primary || main_cfg.active_profile;
		let effective_id = cfg.get_effective_active_profile_id(c);
		if (failback_enabled && primary_id && effective_id != primary_id) {
			let pri_cached = te.get_cached_results([primary_id]);
			let pri_pass = false;
			if (pri_cached && length(pri_cached) > 0 && (pri_cached[0].status == 'pass' || pri_cached[0].status == 'warn') && (now - pri_cached[0].tested_at <= test_ttl)) {
				pri_pass = true;
			} else {
				let ptest = te.test_profile(primary_id);
				pri_pass = (ptest && (ptest.status == 'pass' || ptest.status == 'warn'));
			}

			if (pri_pass) {
				st.primary_pass_ticks = (st.primary_pass_ticks || 0) + 1;
				if (st.primary_pass_ticks >= 3) {
					// Check rate limits before failback switch
					let switches_last_hour = get_recent_switches_count(st.switch_history, now, 3600);
					if (now - (st.last_switch || 0) >= min_switch_interval && switches_last_hour < max_switches_per_hour) {
						util.log('info', sprintf('Failback: Primary profile %s passed 3 consecutive ticks. Switching back.', primary_id));
						switch_active_tunnel(primary_id, persist_switch, c);
						st.last_switch = now;
						push(st.switch_history, now);
						st.primary_pass_ticks = 0;
						st.original_primary = null;
						st.alerts = [sprintf('Failback: switched back to primary profile %s', primary_id)];
					}
				}
			} else {
				st.primary_pass_ticks = 0;
			}
		}

		save_health_state(st);
		release_health_lock();
		return { ok: true, health: st.last_health, fail_count: 0, alerts: st.alerts };
	}

	// Tunnel has issues: degraded, failing, or down
	st.fail_count = (st.fail_count || 0) + 1;
	if (health_status == 'down') {
		if (!st.down_since) st.down_since = now;
	} else {
		st.down_since = 0;
	}

	// 3. Failover Trigger Gating
	let is_down_past_grace = (st.down_since > 0 && (now - st.down_since >= down_grace));
	let trigger_failover = failover_enabled && (st.fail_count >= fail_threshold || is_down_past_grace);

	if (!trigger_failover) {
		save_health_state(st);
		release_health_lock();
		return { ok: true, health: st.last_health, fail_count: st.fail_count, alerts: st.alerts };
	}

	// 4. Rate Limiting Check (§7.7)
	// (a) Min switch interval
	if (now - (st.last_switch || 0) < min_switch_interval) {
		let remaining_cd = min_switch_interval - (now - (st.last_switch || 0));
		let alert_msg = sprintf('Failover rate limit: min switch interval not reached (%ds cooldown remaining)', remaining_cd);
		st.alerts = [alert_msg];
		util.log('warn', alert_msg);
		save_health_state(st);
		release_health_lock();
		return { ok: true, rate_limited: true, health: st.last_health, alerts: st.alerts };
	}

	// (b) Hourly cap
	let switches_last_hour = get_recent_switches_count(st.switch_history, now, 3600);
	if (switches_last_hour >= max_switches_per_hour) {
		let alert_msg = sprintf('Failover rate limit: maximum switches per hour (%d/%d) reached. Failover suspended.', switches_last_hour, max_switches_per_hour);
		st.alerts = [alert_msg];
		util.log('warn', alert_msg);
		save_health_state(st);
		release_health_lock();
		return { ok: true, rate_limited: true, health: st.last_health, alerts: st.alerts };
	}

	// (c) Service lock
	let tlock = get_run_dir() + '/test.lock';
	if (fs.stat(tlock)) {
		let alert_msg = 'Failover paused: pre-connection test lock is held by user job';
		st.alerts = [alert_msg];
		save_health_state(st);
		release_health_lock();
		return { ok: true, skipped: true, reason: 'test_locked', alerts: st.alerts };
	}

	// 5. Candidate Pool Selection
	let candidates = [];
	let mode = auto_cfg.mode || 'off';

	if (mode == 'fallback') {
		let fb_list = auto_cfg.fallback || [];
		if (type(fb_list) == 'string') fb_list = [fb_list];
		for (let fid in fb_list) {
			if (fid != active_id && cfg.get_profile(fid)) push(candidates, fid);
		}
	} else {
		// mode == 'best' or standard auto-failover pool
		let all_profiles = c.profiles || {};
		let pool_pids = [];
		for (let pid in all_profiles) {
			let prof = all_profiles[pid];
			if (pid != active_id && prof.enabled != '0' && prof.auto_pool != '0') {
				push(pool_pids, pid);
			}
		}
		// Rank candidate pool by last-known metrics if available (§7.5, §7.7)
		let cached = te.get_cached_results(pool_pids);
		if (cached && length(cached) > 0) {
			let ranked = te.rank_results(cached, c.test);
			let seen = {};
			for (let r in ranked) {
				push(candidates, r.id);
				seen[r.id] = true;
			}
			for (let pid in pool_pids) {
				if (!seen[pid]) push(candidates, pid);
			}
		} else {
			candidates = pool_pids;
		}
	}

	// Exclude current active profile and limit to failover_max_candidates (default 3)
	let max_cands = +auto_cfg.failover_max_candidates || DEFAULT_FAILOVER_MAX_CANDIDATES;
	if (length(candidates) > max_cands) {
		candidates = slice(candidates, 0, max_cands);
	}

	if (length(candidates) == 0) {
		let alert_msg = 'Failover triggered but no alternative candidates available in pool';
		let step = st.backoff_step || 0;
		let backoff_s = BACKOFF_INTERVALS[step] || 1800;
		st.backoff_step = (step + 1 < length(BACKOFF_INTERVALS)) ? step + 1 : step;
		st.backoff_until = now + backoff_s;
		st.alerts = [alert_msg, sprintf('Backing off failover for %d seconds', backoff_s)];
		util.log('warn', alert_msg);
		save_health_state(st);
		release_health_lock();
		return { ok: true, failover_failed: true, reason: 'no_candidates', alerts: st.alerts };
	}

	// 6. Test-Before-Switch: Candidate Testing (§7.7)
	let selected_candidate = null;
	for (let cand_id in candidates) {
		// Check recent pass
		let recent = te.get_cached_results([cand_id]);
		let pass = false;
		if (recent && length(recent) > 0) {
			let r0 = recent[0];
			if ((r0.status == 'pass' || r0.status == 'warn') && (now - (r0.tested_at || 0) <= test_ttl)) {
				pass = true;
			}
		}

		// If no cached pass, perform real isolated test
		if (!pass) {
			let tr = te.test_profile(cand_id);
			if (tr && (tr.status == 'pass' || tr.status == 'warn')) {
				pass = true;
			}
		}

		if (pass) {
			selected_candidate = cand_id;
			break;
		}
	}

	// 7. Perform Switch or Apply Backoff
	if (selected_candidate) {
		util.log('info', sprintf('Failover: Candidate %s passed test. Initiating switch.', selected_candidate));
		if (!st.original_primary) {
			st.original_primary = main_cfg.active_profile;
		}
		switch_active_tunnel(selected_candidate, persist_switch, c);

		st.last_switch = now;
		st.switch_history = prune_switch_history(st.switch_history, now);
		push(st.switch_history, now);
		st.fail_count = 0;
		st.down_since = 0;
		st.backoff_step = 0;
		st.backoff_until = 0;
		st.primary_pass_ticks = 0;
		st.alerts = [sprintf('Successfully failed over to profile %s', selected_candidate)];

		save_health_state(st);
		release_health_lock();
		return { ok: true, switched: true, target: selected_candidate, alerts: st.alerts };
	}

	// All failover candidates failed
	let step = st.backoff_step || 0;
	let backoff_s = BACKOFF_INTERVALS[step] || 1800;
	st.backoff_step = (step + 1 < length(BACKOFF_INTERVALS)) ? step + 1 : step;
	st.backoff_until = now + backoff_s;

	let kill_switch = (main_cfg.kill_switch == '1' || main_cfg.kill_switch == true);
	let ks_note = kill_switch ? 'Traffic remains strictly blocked by kill switch (no leak)' : 'Traffic failing open to WAN per kill_switch=off';
	let alert_fail = sprintf('All failover candidates failed pre-switch tests. %s. Backing off for %ds.', ks_note, backoff_s);
	st.alerts = [alert_fail];
	util.log('warn', alert_fail);

	save_health_state(st);
	release_health_lock();
	return { ok: true, failover_failed: true, reason: 'all_candidates_unhealthy', alerts: st.alerts };
}

// ----------------------------------------------------------------------------
// Autoconnect Status & Cron Schedule Maintenance (§7.7, §8.2)
// ----------------------------------------------------------------------------

function get_autoconnect_status() {
	let c = cfg.load_config();
	let main_cfg = c.main || {};
	let auto_cfg = c.autoconnect || {};
	let st = load_health_state();
	let now = time();

	let min_switch_interval = +auto_cfg.min_switch_interval || DEFAULT_MIN_SWITCH_INTERVAL;
	let max_switches_per_hour = +auto_cfg.max_switches_per_hour || DEFAULT_MAX_SWITCHES_PER_HOUR;
	let switches_last_hour = get_recent_switches_count(st.switch_history, now, 3600);

	let cooldown_rem = 0;
	if (st.last_switch) {
		let elapsed = now - st.last_switch;
		if (elapsed < min_switch_interval) cooldown_rem = min_switch_interval - elapsed;
	}

	let backoff_rem = 0;
	if (st.backoff_until && now < st.backoff_until) {
		backoff_rem = st.backoff_until - now;
	}

	let override = cfg.get_active_override();

	return {
		mode: auto_cfg.mode || 'off',
		health_enabled: (auto_cfg.health_enabled == '1' || auto_cfg.health_enabled == true),
		failover: (auto_cfg.failover == '1' || auto_cfg.failover == true),
		fail_count: st.fail_count || 0,
		fail_threshold: +auto_cfg.fail_threshold || DEFAULT_FAIL_THRESHOLD,
		down_grace: +auto_cfg.down_grace || DEFAULT_DOWN_GRACE,
		down_since: st.down_since || 0,
		last_tick: st.last_tick || 0,
		last_switch: st.last_switch || 0,
		switches_last_hour: switches_last_hour,
		max_switches_per_hour: max_switches_per_hour,
		min_switch_interval: min_switch_interval,
		override: override,
		primary_profile: st.original_primary || main_cfg.active_profile || '',
		active_profile: cfg.get_effective_active_profile_id(c) || '',
		health: st.last_health || {},
		in_cooldown: (cooldown_rem > 0),
		cooldown_remaining: cooldown_rem,
		in_backoff: (backoff_rem > 0),
		backoff_remaining: backoff_rem,
		alerts: st.alerts || []
	};
}

function get_health_summary() {
	let st = load_health_state();
	return {
		status: (st.last_health && st.last_health.status) ? st.last_health.status : 'unknown',
		last_handshake: (st.last_health && st.last_health.handshake_ms != null) ? st.last_health.handshake_ms : null
	};
}

function update_cron_schedule(main_cfg, auto_cfg, active_proto) {
	let crontab_path = '/etc/crontabs/root';
	let enabled = (main_cfg && (main_cfg.enabled == '1' || main_cfg.enabled == true));
	let health_on = (auto_cfg && (auto_cfg.health_enabled == '1' || auto_cfg.health_enabled == true));
	let need_tick = enabled && (health_on || active_proto == 'wireguard' || active_proto == 'ikev2');

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
		if (trim(line) == '# geovpn health begin') {
			in_block = true;
			continue;
		}
		if (trim(line) == '# geovpn health end') {
			in_block = false;
			continue;
		}
		if (!in_block && length(trim(line)) > 0) {
			push(clean_lines, line);
		}
	}

	if (need_tick) {
		push(clean_lines, '# geovpn health begin');
		push(clean_lines, '* * * * * /usr/bin/geovpn health-tick');
		push(clean_lines, '# geovpn health end');
	}

	let new_content = join('\n', clean_lines) + '\n';
	if (new_content != existing) {
		let out = fs.open(crontab_path + '.tmp', 'w', 0o600);
		if (out) {
			out.write(new_content);
			out.close();
			fs.rename(crontab_path + '.tmp', crontab_path);
			util.safe_exec(['/etc/init.d/cron', 'restart']);
			util.log('info', 'Updated cron schedule for GeoVPN health check');
		}
	}
}

export {
	load_health_state,
	save_health_state,
	run_health_tick,
	manual_switch,
	switch_active_tunnel,
	add_endpoint_ips_direct,
	get_autoconnect_status,
	get_health_summary,
	update_cron_schedule,
	acquire_health_lock,
	release_health_lock
};
