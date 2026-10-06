'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require geovpn.api as api';
'require geovpn.widgets as widgets';

return view.extend({
	load: function() {
		return Promise.all([
			api.getLogs(100, 'all'),
			api.getDiag()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var initialLogs = (data && data[0] && data[0].lines) ? data[0].lines : [];
		var diagData = (data && data[1]) || {};

		// ----------------------------------------------------
		// 1. Log Viewer Card
		// ----------------------------------------------------
		var sourceSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'all', 'selected': 'selected' }, [ _('All GeoVPN Logs') ]),
			E('option', { 'value': 'openvpn' }, [ _('OpenVPN Process') ]),
			E('option', { 'value': 'geovpn' }, [ _('GeoVPN System Events') ])
		]);

		var linesSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '100', 'selected': 'selected' }, [ _('100 Lines') ]),
			E('option', { 'value': '200' }, [ _('200 Lines') ]),
			E('option', { 'value': '500' }, [ _('500 Lines') ])
		]);

		var autoRefreshCheck = E('input', { 'type': 'checkbox' });

		var logPre = E('pre', {
			'class': 'gv-log-box',
			'style': 'background: #161b22; color: #c9d1d9; border: 1px solid rgba(127, 127, 127, 0.2); font-family: monospace; font-size: 0.85rem; line-height: 1.5; padding: 14px; border-radius: 6px; max-height: 450px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; direction: ltr; text-align: left;'
		}, [
			initialLogs.length > 0 ? initialLogs.join('\n') : _('No log entries found.')
		]);

		function fetchLogs() {
			var numLines = +linesSelect.value;
			var src = sourceSelect.value;
			api.getLogs(numLines, src).then(function(res) {
				var lines = (res && res.lines) ? res.lines : [];
				logPre.textContent = lines.length > 0 ? lines.join('\n') : _('No log entries found.');
				logPre.scrollTop = logPre.scrollHeight;
			});
		}

		sourceSelect.addEventListener('change', fetchLogs);
		linesSelect.addEventListener('change', fetchLogs);

		var refreshBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				fetchLogs();
			}
		}, [ _('Refresh') ]);

		var copyBtn = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': function() {
				navigator.clipboard.writeText(logPre.textContent).then(function() {
					ui.addNotification(null, E('p', {}, [ _('Logs copied to clipboard.') ]), 'info');
				}).catch(function() {
					ui.addNotification(null, E('p', {}, [ _('Failed to copy to clipboard.') ]), 'error');
				});
			}
		}, [ _('Copy Logs') ]);

		var pollTimer = null;
		autoRefreshCheck.addEventListener('change', function() {
			if (this.checked) {
				pollTimer = setInterval(fetchLogs, 3000);
			} else if (pollTimer) {
				clearInterval(pollTimer);
				pollTimer = null;
			}
		});

		var logControls = E('div', {
			'style': 'display: flex; flex-wrap: wrap; gap: 12px; align-items: center; margin-bottom: 14px;'
		}, [
			E('label', { 'style': 'display: flex; align-items: center; gap: 6px;' }, [
				E('span', { 'style': 'font-weight: 500;' }, [ _('Source:') ]),
				sourceSelect
			]),
			E('label', { 'style': 'display: flex; align-items: center; gap: 6px;' }, [
				E('span', { 'style': 'font-weight: 500;' }, [ _('Lines:') ]),
				linesSelect
			]),
			E('label', { 'style': 'cursor: pointer; display: flex; align-items: center; gap: 6px;' }, [
				autoRefreshCheck,
				_('Auto-refresh (3s)')
			]),
			E('div', { 'style': 'margin-inline-start: auto; display: flex; gap: 8px;' }, [
				refreshBtn,
				copyBtn
			])
		]);

		var logsCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('System & OpenVPN Logs') ])
			]),
			E('p', { 'style': 'font-size: 0.85rem; opacity: 0.75; margin-bottom: 12px;' }, [
				_('All logs are automatically scrubbed on the router to remove certificates, private keys, and passwords before display.')
			]),
			logControls,
			logPre
		]);

		// ----------------------------------------------------
		// 2. Diagnostics Checklist Card
		// ----------------------------------------------------
		var diagChecksTable = E('table', {
			'class': 'table cbi-section-table',
			'style': 'width: 100%; border-collapse: collapse; margin-top: 10px;'
		}, [
			E('thead', {}, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th', 'style': 'width: 90px; padding: 8px 12px; text-align: center;' }, [ _('Status') ]),
					E('th', { 'class': 'th', 'style': 'width: 200px; padding: 8px 12px; text-align: start;' }, [ _('Component Check') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Details & Recommendations') ])
				])
			]),
			E('tbody')
		]);

		var tbody = diagChecksTable.querySelector('tbody');
		var checks = diagData.checks || [];

		if (checks.length === 0) {
			dom.append(tbody, E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '3', 'style': 'text-align: center; padding: 20px; opacity: 0.7;' }, [
					_('No diagnostic checks available.')
				])
			]));
		} else {
			checks.forEach(function(c, idx) {
				var badge = widgets.renderCheckBadge(c.level);
				var details = [ E('span', { 'style': 'font-size: 0.95rem;' }, [ c.msg || '' ]) ];

				if (c.hint) {
					details.push(E('div', {
						'style': 'margin-top: 6px; font-size: 0.85rem; padding: 6px 10px; border-radius: 4px; background: var(--cbi-input-background, rgba(127,127,127,0.1)); border-inline-start: 3px solid #d29922;'
					}, [
						E('strong', {}, [ _('Recommendation: ') ]),
						c.hint
					]));
				}

				dom.append(tbody, E('tr', {
					'class': 'tr cbi-rowstyle-' + (idx % 2 + 1),
					'style': 'border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15));'
				}, [
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [ badge ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; font-weight: 600;' }, [ widgets.renderLtr(c.id || '-') ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, details)
				]));
			});
		}

		var diagCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('System Diagnostics Checklist') ]),
				diagData.ok ?
					E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('All Systems OK ✔') ]) :
					E('span', { 'class': 'gv-badge gv-badge-connecting' }, [ _('Action Needed') ])
			]),
			E('p', { 'style': 'font-size: 0.85rem; opacity: 0.75; margin-bottom: 12px;' }, [
				_('Preflight verification checks kernel modules, binaries, firewall rules, and coexistence with other packages.')
			]),
			diagChecksTable
		]);

		// ----------------------------------------------------
		// 3. Leak Self-Test & Diagnostic Export Card
		// ----------------------------------------------------
		var selfTestResults = E('div', {
			'style': 'margin-top: 14px; padding: 14px; border-radius: 6px; background: var(--cbi-input-background, rgba(127,127,127,0.08)); border: 1px solid var(--cbi-border-color, rgba(127,127,127,0.2)); display: none;'
		});

		var runSelfTestBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				ui.showIndicator();
				selfTestResults.style.display = 'block';
				dom.content(selfTestResults, [ E('p', {}, [ _('Testing route simulator on sample targets…') ]) ]);

				var testTargets = ['digikala.com', 'google.com', '1.1.1.1'];
				Promise.all(testTargets.map(function(t) { return api.testTarget(t); })).then(function(results) {
					ui.hideIndicator();
					dom.content(selfTestResults, []);

					results.forEach(function(r, idx) {
						var verdictBadge = (r.verdict === 'direct')
							? E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('DIRECT') ])
							: E('span', { 'class': 'gv-badge', 'style': 'background-color: rgba(9,105,218,0.2); color: #58a6ff; border: 1px solid #58a6ff;' }, [ _('VPN') ]);

						var reason = (r.reason && r.reason.layer) ? (r.reason.layer + ' / ' + (r.reason.rule || '')) : 'default';

						dom.append(selfTestResults, E('div', {
							'style': 'display: flex; align-items: center; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid var(--cbi-border-color, rgba(127,127,127,0.15));'
						}, [
							E('span', { 'style': 'font-weight: 600;' }, [ widgets.renderLtr(testTargets[idx]) ]),
							E('div', { 'style': 'display: flex; gap: 12px; align-items: center;' }, [
								E('span', { 'style': 'font-size: 0.85rem; opacity: 0.75;' }, [ reason ]),
								verdictBadge
							])
						]));
					});
				}).catch(function(err) {
					ui.hideIndicator();
					dom.content(selfTestResults, [
						E('span', { 'style': 'color: #f85149;' }, [ _('Test failed: ') + err ])
					]);
				});
			}
		}, [ _('Run Leak Self-Test') ]);

		var exportBundleBtn = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': function() {
				ui.showIndicator();
				api.getDiag().then(function(diag) {
					ui.hideIndicator();
					var jsonStr = JSON.stringify(diag, null, 2);
					var blob = new Blob([jsonStr], { type: 'application/json' });
					var url = URL.createObjectURL(blob);
					var a = E('a', {
						'href': url,
						'download': 'geovpn-diagnostics-' + Math.floor(Date.now() / 1000) + '.json',
						'style': 'display: none;'
					});
					document.body.appendChild(a);
					a.click();
					document.body.removeChild(a);
					URL.revokeObjectURL(url);
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Error exporting diagnostics: ') + err ]), 'error');
				});
			}
		}, [ _('Download Diagnostics (JSON)') ]);

		var leakTestCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('Leak Testing & Export') ])
			]),
			E('p', { 'style': 'font-size: 0.85rem; opacity: 0.75; margin-bottom: 14px;' }, [
				_('Run simulated destination verification to test split-tunnel routing decisions, or export a safe, scrubbed diagnostics bundle for troubleshooting.')
			]),
			E('div', { 'class': 'gv-actions', 'style': 'display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; align-items: center;' }, [
				runSelfTestBtn,
				exportBundleBtn
			]),
			selfTestResults
		]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Logs & Diagnostics') ]),
			logsCard,
			diagCard,
			leakTestCard
		]);
	}
});
