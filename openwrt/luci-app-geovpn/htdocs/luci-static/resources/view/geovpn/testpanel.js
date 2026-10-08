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
			api.testResults()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var statusData = (data && data[1]) || {};
		var cachedTestItems = (data && data[2] && data[2].items) || [];
		var testCfg = uci.get('geovpn', 'test') || {};
		var activeProfileId = uci.get('geovpn', 'main', 'active_profile') || '';

		var profiles = uci.sections('geovpn', 'profile') || [];
		var maxDisplay = 200;
		var displayProfiles = profiles.slice(0, maxDisplay);
		var isCapped = (profiles.length > maxDisplay);

		// Map cached results by profile ID
		var resultsMap = {};
		cachedTestItems.forEach(function(item) {
			if (item && item.id) resultsMap[item.id] = item;
		});

		// State tracking
		var activeJobId = null;
		var pollTimer = null;
		var selectedIds = {};

		// 1. Diagnostics & Criteria Card
		var targetsList = testCfg.targets || ['https://www.gstatic.com/generate_204'];
		if (Array.isArray(targetsList)) targetsList = targetsList.join(', ');

		var criteriaCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 14px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('Pre-Connection Test Engine') ]),
				widgets.renderBadge(statusData.service ? statusData.service.state : 'disabled')
			]),
			E('div', {
				'class': 'gv-banner-info',
				'style': 'margin-bottom: 16px; font-size: 0.85rem;'
			}, [
				_('Pre-connection testing creates isolated temporary links (gvt0) under fail-closed table 4300 with zero leakage into the active VPN tunnel or LAN. Results are scored against configured latency and handshake thresholds.')
			]),
			E('div', {
				'class': 'gv-grid',
				'style': 'display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px;'
			}, [
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Routing Table') ]),
					E('div', { 'class': 'gv-metric-value' }, [ widgets.renderLtr('4300 (gvt0)') ])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Max Handshake') ]),
					E('div', { 'class': 'gv-metric-value' }, [ widgets.renderLtr((testCfg.max_handshake_ms || '8000') + ' ms') ])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Max Latency') ]),
					E('div', { 'class': 'gv-metric-value' }, [ widgets.renderLtr((testCfg.max_latency_ms || '800') + ' ms') ])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Max Packet Loss') ]),
					E('div', { 'class': 'gv-metric-value' }, [ widgets.renderLtr((testCfg.max_loss_pct || '34') + '%') ])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('HTTP Probe Target') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 0.95rem;' }, [ widgets.renderLtr(targetsList) ])
				])
			])
		]);

		// 2. Real-Time Job Progress Banner (Active ONLY while running)
		var progressContainer = E('div', {
			'class': 'gv-card',
			'style': 'display: none; padding: 16px 20px; margin-bottom: 20px; border-left: 4px solid #0969da;'
		}, [
			E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;' }, [
				E('strong', { 'class': 'gv-progress-title' }, [ _('Test job in progress...') ]),
				E('span', { 'class': 'gv-progress-counts', 'style': 'font-size: 0.85rem; font-weight: 600;' }, [ '0 / 0' ])
			]),
			E('div', { 'class': 'gv-progress-bar' }, [
				E('div', { 'class': 'gv-progress-fill', 'style': 'width: 0%;' })
			]),
			E('div', { 'class': 'gv-progress-desc', 'style': 'font-size: 0.82rem; opacity: 0.8; margin-top: 6px;' }, [
				_('Starting runner...')
			])
		]);

		// 3. Actions Toolbar
		var testAllBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() { startBatchTest('all'); }
		}, [ _('Test All Profiles') ]);

		var testSelectedBtn = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': function() {
				var ids = Object.keys(selectedIds).filter(function(k) { return selectedIds[k]; });
				if (ids.length === 0) {
					ui.addNotification(null, E('p', {}, [ _('Please select one or more profiles to test.') ]), 'warning');
					return;
				}
				startBatchTest(ids);
			}
		}, [ _('Test Selected') ]);

		var cancelBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'disabled': 'true',
			'click': function() {
				if (!activeJobId) return;
				api.testCancel(activeJobId).then(function() {
					stopPolling();
					ui.addNotification(null, E('p', {}, [ _('Test job cancelled.') ]), 'info');
					updateUiRunning(false);
				});
			}
		}, [ _('Cancel Job') ]);

		var cleanupBtn = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': function() {
				ui.showIndicator();
				api.testCleanup(true).then(function(cRes) {
					ui.hideIndicator();
					var leftovers = (cRes && cRes.leftovers != null) ? cRes.leftovers : 0;
					if (leftovers === 0) {
						ui.addNotification(null, E('p', {}, [
							_('Test environment cleanly verified: 0 residual routes, rules, or test interfaces.')
						]), 'info');
					} else {
						ui.addNotification(null, E('p', {}, [
							_('Cleanup completed with %d remaining items.').format(leftovers)
						]), 'warning');
					}
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Cleanup error: ') + err ]), 'error');
				});
			}
		}, [ _('Clean Up Test State') ]);

		var connectBestBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'margin-inline-start: auto;',
			'click': connectToBestProfile
		}, [ _('★ Connect to Best') ]);

		var toolbar = E('div', {
			'class': 'gv-actions',
			'style': 'display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 16px; align-items: center;'
		}, [
			testAllBtn,
			testSelectedBtn,
			cancelBtn,
			cleanupBtn,
			connectBestBtn
		]);

		// 4. Results Table
		var resultsTable = E('table', {
			'class': 'table cbi-section-table',
			'style': 'width: 100%; border-collapse: collapse;'
		}, [
			E('thead', {}, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th', 'style': 'width: 36px; padding: 8px 10px; text-align: center;' }, [
						E('input', {
							'type': 'checkbox',
							'click': function(ev) {
								var checked = ev.target.checked;
								displayProfiles.forEach(function(p) {
									selectedIds[p['.name']] = checked;
								});
								resultsTable.querySelectorAll('.gv-row-cb').forEach(function(cb) {
									cb.checked = checked;
								});
							}
						})
					]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Profile') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Protocol') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: center;' }, [ _('Score / Status') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: center;' }, [ _('Handshake') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('HTTP Probe (Latency / Loss)') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Diagnostic Detail') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: end;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		var tbody = resultsTable.querySelector('tbody');

		function renderTableRows() {
			dom.content(tbody, []);

			if (displayProfiles.length === 0) {
				dom.append(tbody, E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': '8', 'style': 'text-align: center; padding: 24px; opacity: 0.7;' }, [
						_('No VPN profiles configured to test.')
					])
				]));
				return;
			}

			displayProfiles.forEach(function(p, idx) {
				var pid = p['.name'];
				var proto = p.proto || 'openvpn';
				var provider = p.provider || 'generic';
				var r = resultsMap[pid];

				var status = (r && r.status) ? r.status : 'untested';
				var handshakeText = '-';
				if (r && r.handshake_ms != null) {
					handshakeText = Math.round(r.handshake_ms) + ' ms';
				}

				var httpText = '-';
				var httpLat = (r && r.url && r.url.median_ms != null) ? r.url.median_ms : ((r && r.url && r.url.median != null) ? r.url.median : null);
				if (httpLat != null) {
					httpText = Math.round(httpLat) + ' ms';
					if (r.url.loss_pct != null && r.url.loss_pct > 0) {
						httpText += ' (' + Math.round(r.url.loss_pct) + '% loss)';
					}
				}

				var diagText = '-';
				if (r) {
					if (r.hint) {
						diagText = r.hint;
					} else if (r.reason) {
						diagText = r.reason;
					} else if (r.status === 'pass') {
						diagText = _('Optimal route');
					}
				}

				var cb = E('input', {
					'type': 'checkbox',
					'class': 'gv-row-cb',
					'click': function(ev) {
						selectedIds[pid] = ev.target.checked;
					}
				});
				if (selectedIds[pid]) cb.checked = true;

				var rowActions = [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() { startBatchTest([pid]); }
					}, [ _('Test') ]),
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button ' + (pid === activeProfileId ? 'cbi-button-positive' : 'cbi-button-neutral'),
						'disabled': (pid === activeProfileId) ? 'true' : null,
						'click': function() {
							ui.showIndicator();
							uci.set('geovpn', 'main', 'active_profile', pid);
							uci.save();
							uci.apply().then(function() {
								api.callService('restart').then(function() {
									ui.hideIndicator();
									location.reload();
								});
							});
						}
					}, [ (pid === activeProfileId) ? _('Active ✔') : _('Connect') ])
				];

				dom.append(tbody, E('tr', {
					'class': 'tr cbi-rowstyle-' + (idx % 2 + 1),
					'style': 'border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15));'
				}, [
					E('td', { 'class': 'td', 'style': 'text-align: center; padding: 10px 8px;' }, [ cb ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; font-weight: 600;' }, [
						E('div', {}, [ p.name || pid ]),
						E('div', { 'style': 'margin-top: 2px;' }, [ widgets.renderProviderBadge(provider) ])
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [ widgets.renderProtoBadge(proto) ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [
						(status === 'untested') ? E('span', { 'style': 'opacity: 0.6; font-size: 0.8rem;' }, [ _('Untested') ]) :
						widgets.renderTestStatusBadge(status)
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [ widgets.renderLtr(handshakeText) ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [ widgets.renderLtr(httpText) ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; font-size: 0.85rem;' }, [ diagText ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: end;' }, rowActions)
				]));
			});
		}

		renderTableRows();

		// Real-Time Job Polling Lifecycle (Zero Polling when Idle)
		function updateUiRunning(isRunning) {
			cancelBtn.disabled = !isRunning;
			testAllBtn.disabled = isRunning;
			testSelectedBtn.disabled = isRunning;
			progressContainer.style.display = isRunning ? 'block' : 'none';
		}

		function startBatchTest(target) {
			stopPolling();
			updateUiRunning(true);

			var isAll = (target === 'all');
			var ids = isAll ? [] : (Array.isArray(target) ? target : [target]);

			progressContainer.querySelector('.gv-progress-title').textContent = _('Launching pre-connection test job...');
			progressContainer.querySelector('.gv-progress-fill').style.width = '5%';

			api.testStart(ids, isAll, '').then(function(startRes) {
				if (!startRes || !startRes.job_id) {
					updateUiRunning(false);
					ui.addNotification(null, E('p', {}, [ _('Cannot start test: ') + ((startRes && startRes.message) || _('Engine busy')) ]), 'error');
					return;
				}

				activeJobId = startRes.job_id;
				pollJob();
			}).catch(function(err) {
				updateUiRunning(false);
				ui.addNotification(null, E('p', {}, [ _('Test launch failed: ') + err ]), 'error');
			});
		}

		function pollJob() {
			if (!activeJobId) return;

			api.testStatus(activeJobId).then(function(st) {
				if (!st || st.error) {
					stopPolling();
					updateUiRunning(false);
					return;
				}

				var total = st.total || 1;
				var idx = st.index || 0;
				var pct = Math.round((idx / total) * 100);

				progressContainer.querySelector('.gv-progress-counts').textContent = idx + ' / ' + total;
				progressContainer.querySelector('.gv-progress-fill').style.width = Math.min(100, Math.max(5, pct)) + '%';

				if (st.current && st.current.id) {
					var curName = st.current.id;
					displayProfiles.forEach(function(p) {
						if (p['.name'] === st.current.id) curName = p.name || curName;
					});
					progressContainer.querySelector('.gv-progress-desc').textContent = _('Currently probing "%s"...').format(curName);
				}

				// Update results map incrementally
				if (st.results && Array.isArray(st.results)) {
					st.results.forEach(function(item) {
						if (item && item.id) resultsMap[item.id] = item;
					});
					renderTableRows();
				}

				if (st.state === 'running') {
					// Schedule next poll in 1.5s
					pollTimer = window.setTimeout(pollJob, 1500);
				} else {
					// State is done or cancelled
					stopPolling();
					updateUiRunning(false);
					ui.addNotification(null, E('p', {}, [
						(st.state === 'cancelled') ? _('Test job cancelled.') : _('Test job finished successfully.')
					]), 'info');
				}
			}).catch(function(err) {
				stopPolling();
				updateUiRunning(false);
			});
		}

		function stopPolling() {
			if (pollTimer) {
				window.clearTimeout(pollTimer);
				pollTimer = null;
			}
			activeJobId = null;
		}

		// Connect to Best Profile Logic
		function connectToBestProfile() {
			var bestProfile = null;
			var bestLatency = Infinity;
			var bestStatusWeight = 0; // pass = 2, warn = 1

			displayProfiles.forEach(function(p) {
				var r = resultsMap[p['.name']];
				if (!r || (r.status !== 'pass' && r.status !== 'warn')) return;

				var weight = (r.status === 'pass') ? 2 : 1;
				var lat = (r.url && r.url.median_ms != null) ? r.url.median_ms : ((r.url && r.url.median != null) ? r.url.median : ((r.handshake_ms != null) ? r.handshake_ms : 9999));

				if (weight > bestStatusWeight || (weight === bestStatusWeight && lat < bestLatency)) {
					bestStatusWeight = weight;
					bestLatency = lat;
					bestProfile = {
						id: p['.name'],
						name: p.name || p['.name'],
						status: r.status,
						latency: lat
					};
				}
			});

			if (!bestProfile) {
				ui.addNotification(null, E('p', {}, [ _('No passing or warning profiles found to connect. Run tests first.') ]), 'warning');
				return;
			}

			var confirmMsg = _('Connect to top-scoring profile "%s" (Status: %s, Latency: %d ms)?').format(
				bestProfile.name,
				bestProfile.status.toUpperCase(),
				Math.round(bestProfile.latency)
			);

			if (confirm(confirmMsg)) {
				ui.showIndicator();
				uci.set('geovpn', 'main', 'active_profile', bestProfile.id);
				uci.save();
				uci.apply().then(function() {
					api.callService('restart').then(function() {
						ui.hideIndicator();
						location.reload();
					});
				});
			}
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Test Panel') ]),
			criteriaCard,
			progressContainer,
			E('div', {
				'class': 'cbi-section gv-card',
				'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px;'
			}, [
				E('div', {
					'class': 'gv-card-title',
					'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
				}, [
					E('span', {}, [ _('Pre-Connection Test Results') ]),
					E('span', { 'style': 'font-size: 0.85rem; font-weight: 400; opacity: 0.7;' }, [
						_('%d Profiles Ready').format(profiles.length)
					])
				]),
				toolbar,
				(isCapped) ? E('div', {
					'class': 'gv-banner-warn',
					'style': 'margin-bottom: 12px; font-size: 0.85rem;'
				}, [
					_('Display capped: Showing first 200 of %d profiles.').format(profiles.length)
				]) : E('span'),
				resultsTable
			])
		]);
	}
});
