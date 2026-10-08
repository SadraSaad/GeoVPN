'use strict';
'require view';
'require ui';
'require uci';
'require dom';
'require geovpn.api as api';
'require geovpn.widgets as widgets';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('geovpn'),
			api.getStatus(),
			api.getAutoconnectStatus()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var statusData = (data && data[1]) || {};
		var autoStatus = (data && data[2]) || {};

		var mainCfg = uci.get('geovpn', 'main') || {};
		var autoCfg = uci.get('geovpn', 'auto') || {};
		var profiles = uci.sections('geovpn', 'profile') || [];

		// ----------------------------------------------------
		// 1. Status & Telemetry Card
		// ----------------------------------------------------
		var healthState = (autoStatus.health && autoStatus.health.status) ? autoStatus.health.status : 'unknown';
		var healthColor = '#64748b';
		var healthLabel = _('Unknown');

		if (healthState === 'healthy') {
			healthColor = '#22c55e';
			healthLabel = _('Healthy');
		} else if (healthState === 'degraded') {
			healthColor = '#eab308';
			healthLabel = _('Degraded');
		} else if (healthState === 'failing') {
			healthColor = '#f97316';
			healthLabel = _('Failing');
		} else if (healthState === 'down') {
			healthColor = '#ef4444';
			healthLabel = _('Down');
		}

		var healthBadge = E('span', {
			'class': 'gv-badge',
			'style': 'background-color: ' + healthColor + '; color: #ffffff; font-weight: 600; padding: 4px 10px; border-radius: 4px;'
		}, [ healthLabel ]);

		var activeProfileId = autoStatus.active_profile || statusData.tunnel && statusData.tunnel.profile || mainCfg.active_profile || '';
		var isOverride = !!(autoStatus.override);
		var overrideBadge = isOverride ? E('span', {
			'class': 'gv-badge',
			'style': 'background-color: #f59e0b; color: #ffffff; margin-inline-start: 8px;'
		}, [ _('Runtime Override Active (Temporary)') ]) : E('span', {
			'class': 'gv-badge',
			'style': 'background-color: #10b981; color: #ffffff; margin-inline-start: 8px;'
		}, [ _('Persisted in UCI') ]);

		var activeProfileName = activeProfileId;
		for (var p = 0; p < profiles.length; p++) {
			if (profiles[p]['.name'] === activeProfileId) {
				activeProfileName = profiles[p].name || activeProfileId;
				break;
			}
		}

		var clearOverrideBtn = isOverride ? E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'style': 'margin-inline-start: 12px;',
			'click': function() {
				ui.showIndicator();
				api.switchProfile(mainCfg.active_profile, 1).then(function() {
					ui.hideIndicator();
					window.location.reload();
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Failed to clear override: ') + err ]), 'error');
				});
			}
		}, [ _('Switch to Primary Profile') ]) : '';

		// Alerts banner
		var alertsContainer = E('div', {});
		if (autoStatus.alerts && autoStatus.alerts.length > 0) {
			var alertElements = [];
			for (var a = 0; a < autoStatus.alerts.length; a++) {
				alertElements.push(E('div', { 'style': 'margin-bottom: 4px;' }, [
					E('strong', {}, [ '• ' ]),
					E('span', {}, [ autoStatus.alerts[a] ])
				]));
			}
			alertsContainer = E('div', {
				'class': 'gv-alert-banner',
				'style': 'background-color: #fee2e2; border-left: 4px solid #ef4444; padding: 12px 16px; margin-bottom: 16px; border-radius: 4px; color: #991b1b;'
			}, alertElements);
		}

		// Cooldown indicator
		var cooldownText = _('Ready (No cooldown)');
		if (autoStatus.in_cooldown) {
			cooldownText = String.format(_('Cooldown active: %ds remaining'), autoStatus.cooldown_remaining || 0);
		}

		var backoffText = _('None');
		if (autoStatus.in_backoff) {
			backoffText = String.format(_('Exponential backoff active: %ds remaining'), autoStatus.backoff_remaining || 0);
		}

		var checkNowBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function(ev) {
				var btn = ev.target;
				btn.disabled = true;
				btn.textContent = _('Running Health Check...');
				api.runHealthTick(true).then(function() {
					return api.getAutoconnectStatus();
				}).then(function() {
					window.location.reload();
				}).catch(function(err) {
					btn.disabled = false;
					btn.textContent = _('Run Health Check Now');
					ui.addNotification(null, E('p', {}, [ _('Health check failed: ') + err ]), 'error');
				});
			}
		}, [ _('Run Health Check Now') ]);

		var statusCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title', 'style': 'display: flex; justify-content: space-between; align-items: center;' }, [
				E('span', {}, [ _('Health & Failover Telemetry') ]),
				healthBadge
			]),
			alertsContainer,
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Active Tunnel Profile') ]),
				E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; align-items: center; flex-wrap: wrap; gap: 8px;' }, [
					E('strong', {}, [ activeProfileName ]),
					E('span', { 'style': 'color: #64748b;' }, [ ' (', E('bdi', { 'dir': 'ltr' }, [ activeProfileId ]), ')' ]),
					overrideBadge,
					clearOverrideBtn
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Consecutive Failures') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', { 'style': 'font-weight: 600;' }, [
						String.format(_('%d / %d failures'), autoStatus.fail_count || 0, autoStatus.fail_threshold || 3)
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Recent Metrics') ]),
				E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; gap: 24px; flex-wrap: wrap;' }, [
					E('div', {}, [
						E('div', { 'style': 'font-size: 11px; color: #64748b; text-transform: uppercase;' }, [ _('Handshake Age') ]),
						E('div', { 'style': 'font-weight: 600;' }, [
							(autoStatus.health && autoStatus.health.handshake_ms != null) ? (autoStatus.health.handshake_ms + ' ms') : _('N/A')
						])
					]),
					E('div', {}, [
						E('div', { 'style': 'font-size: 11px; color: #64748b; text-transform: uppercase;' }, [ _('HTTP Latency') ]),
						E('div', { 'style': 'font-weight: 600;' }, [
							(autoStatus.health && autoStatus.health.latency_ms != null) ? (autoStatus.health.latency_ms + ' ms') : _('N/A')
						])
					]),
					E('div', {}, [
						E('div', { 'style': 'font-size: 11px; color: #64748b; text-transform: uppercase;' }, [ _('Packet Loss') ]),
						E('div', { 'style': 'font-weight: 600;' }, [
							(autoStatus.health && autoStatus.health.loss_pct != null) ? (autoStatus.health.loss_pct + '%') : _('N/A')
						])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Rate Limits & Cooldown') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', {}, [
						E('span', {}, [ _('Switch Cooldown: ') ]),
						E('strong', {}, [ cooldownText ])
					]),
					E('div', { 'style': 'margin-top: 4px;' }, [
						E('span', {}, [ _('Switches in Last Hour: ') ]),
						E('strong', {}, [ String.format(_('%d / %d'), autoStatus.switches_last_hour || 0, autoStatus.max_switches_per_hour || 6) ])
					]),
					E('div', { 'style': 'margin-top: 4px;' }, [
						E('span', {}, [ _('Failover Backoff: ') ]),
						E('span', {}, [ backoffText ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Manual Health Check') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					checkNowBtn
				])
			])
		]);

		// ----------------------------------------------------
		// 2. Configuration Form Card
		// ----------------------------------------------------
		var modeSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'off', 'selected': (autoCfg.mode === 'off' || !autoCfg.mode) ? 'selected' : null }, [ _('Manual Only (Off)') ]),
			E('option', { 'value': 'gate', 'selected': (autoCfg.mode === 'gate') ? 'selected' : null }, [ _('Connect Gate Only') ]),
			E('option', { 'value': 'best', 'selected': (autoCfg.mode === 'best') ? 'selected' : null }, [ _('Connect Best After Testing') ]),
			E('option', { 'value': 'fallback', 'selected': (autoCfg.mode === 'fallback') ? 'selected' : null }, [ _('Ordered Fallback List') ])
		]);

		var connectGateSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'off', 'selected': (autoCfg.connect_gate === 'off' || !autoCfg.connect_gate) ? 'selected' : null }, [ _('Off (Connect immediately without test)') ]),
			E('option', { 'value': 'warn', 'selected': (autoCfg.connect_gate === 'warn') ? 'selected' : null }, [ _('Warn (Test before connect, warn on failure)') ]),
			E('option', { 'value': 'require', 'selected': (autoCfg.connect_gate === 'require') ? 'selected' : null }, [ _('Require (Strict: abort connect if test fails)') ])
		]);

		var healthEnabledCheck = E('input', {
			'type': 'checkbox',
			'checked': (autoCfg.health_enabled === '1') ? 'checked' : null
		});

		var healthIntervalSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '60', 'selected': (autoCfg.health_interval === '60') ? 'selected' : null }, [ _('60 seconds (1 minute)') ]),
			E('option', { 'value': '120', 'selected': (autoCfg.health_interval === '120' || !autoCfg.health_interval) ? 'selected' : null }, [ _('120 seconds (2 minutes - Default)') ]),
			E('option', { 'value': '180', 'selected': (autoCfg.health_interval === '180') ? 'selected' : null }, [ _('180 seconds (3 minutes)') ]),
			E('option', { 'value': '300', 'selected': (autoCfg.health_interval === '300') ? 'selected' : null }, [ _('300 seconds (5 minutes)') ]),
			E('option', { 'value': '600', 'selected': (autoCfg.health_interval === '600') ? 'selected' : null }, [ _('600 seconds (10 minutes)') ])
		]);

		var failThresholdInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': '1',
			'max': '10',
			'value': autoCfg.fail_threshold || '3'
		});

		var downGraceInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': '5',
			'max': '600',
			'value': autoCfg.down_grace || '30'
		});

		var failoverCheck = E('input', {
			'type': 'checkbox',
			'checked': (autoCfg.failover === '1') ? 'checked' : null
		});

		var failbackCheck = E('input', {
			'type': 'checkbox',
			'checked': (autoCfg.failback === '1') ? 'checked' : null
		});

		var persistSwitchCheck = E('input', {
			'type': 'checkbox',
			'checked': (autoCfg.persist_switch === '1') ? 'checked' : null
		});

		var minSwitchIntervalInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': '60',
			'max': '600',
			'value': autoCfg.min_switch_interval || '60'
		});

		var maxSwitchesPerHourInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'min': '1',
			'max': '20',
			'value': autoCfg.max_switches_per_hour || '6'
		});

		// Fallback profile pool ordering
		var fallbackList = autoCfg.fallback || [];
		if (typeof fallbackList === 'string') fallbackList = [fallbackList];

		var fallbackSelect = E('select', {
			'class': 'cbi-input-select',
			'multiple': 'multiple',
			'size': Math.min(6, Math.max(3, profiles.length))
		});

		for (var pr = 0; pr < profiles.length; pr++) {
			var profObj = profiles[pr];
			var pid = profObj['.name'];
			var isSelected = (fallbackList.indexOf(pid) !== -1);
			fallbackSelect.appendChild(E('option', {
				'value': pid,
				'selected': isSelected ? 'selected' : null
			}, [ (profObj.name || pid) + ' (' + pid + ')' ]));
		}

		var configCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Auto-Connect & Health Policies') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Auto-Connect Mode') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					modeSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Defines connection strategy: off (manual), gate (require test pass), best (connect top-ranked passing profile), fallback (ordered list).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Connect Gate') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					connectGateSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Enforce pre-connection test before activating a profile. Require aborts connect if test fails.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Health Checks Enabled') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						healthEnabledCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Enable periodic cron health ticks (no resident daemon)') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Health Tick Interval') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					healthIntervalSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('How frequently the router tests active tunnel health via live probe.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Failure Threshold') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					failThresholdInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Number of consecutive health check failures required before triggering failover (hysteresis).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Down Grace Period') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					downGraceInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Seconds tunnel interface can remain disconnected before triggering failover immediately.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Automatic Failover') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						failoverCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Automatically switch to another healthy profile on failure') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Automatic Failback') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						failbackCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Switch back to primary profile when it passes 3 consecutive ticks') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Persist Failover Switch') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						persistSwitchCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Commit active_profile to flash UCI on failover (off = temporary RAM override)') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Rate Limiting') ]),
				E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; gap: 16px; align-items: center;' }, [
					E('span', {}, [ _('Min interval (s):') ]),
					minSwitchIntervalInput,
					E('span', {}, [ _('Max switches/hour:') ]),
					maxSwitchesPerHourInput
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Fallback Profile Pool') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					fallbackSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Select profiles used for failover pool when in fallback mode (hold Ctrl/Cmd to select multiple).')
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 3. Save & Apply Bottom Bar
		// ----------------------------------------------------
		var saveApplyBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'padding: 8px 24px; font-weight: 600;',
			'click': function() {
				ui.showIndicator();

				// Ensure auto section exists
				var existingAuto = uci.get('geovpn', 'auto');
				if (!existingAuto) {
					uci.add('geovpn', 'autoconnect', 'auto');
				}

				uci.set('geovpn', 'auto', 'mode', modeSelect.value);
				uci.set('geovpn', 'auto', 'connect_gate', connectGateSelect.value);
				uci.set('geovpn', 'auto', 'health_enabled', healthEnabledCheck.checked ? '1' : '0');
				uci.set('geovpn', 'auto', 'health_interval', healthIntervalSelect.value);
				uci.set('geovpn', 'auto', 'fail_threshold', failThresholdInput.value.trim());
				uci.set('geovpn', 'auto', 'down_grace', downGraceInput.value.trim());
				uci.set('geovpn', 'auto', 'failover', failoverCheck.checked ? '1' : '0');
				uci.set('geovpn', 'auto', 'failback', failbackCheck.checked ? '1' : '0');
				uci.set('geovpn', 'auto', 'persist_switch', persistSwitchCheck.checked ? '1' : '0');
				uci.set('geovpn', 'auto', 'min_switch_interval', minSwitchIntervalInput.value.trim());
				uci.set('geovpn', 'auto', 'max_switches_per_hour', maxSwitchesPerHourInput.value.trim());

				var selectedFallbacks = [];
				for (var o = 0; o < fallbackSelect.options.length; o++) {
					if (fallbackSelect.options[o].selected) {
						selectedFallbacks.push(fallbackSelect.options[o].value);
					}
				}
				uci.set('geovpn', 'auto', 'fallback', selectedFallbacks);

				uci.save();
				uci.apply().then(function() {
					api.callService('reload').then(function() {
						ui.hideIndicator();
						ui.addNotification(null, E('p', {}, [ _('Auto-connect and failover settings saved and applied.') ]), 'info');
					});
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Failed to save settings: ') + err ]), 'error');
				});
			}
		}, [ _('Save & Apply') ]);

		var bottomBar = E('div', {
			'style': 'display: flex; justify-content: flex-end; margin-top: 20px;'
		}, [ saveApplyBtn ]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Auto-Connect & Failover') ]),
			statusCard,
			configCard,
			bottomBar
		]);
	}
});
