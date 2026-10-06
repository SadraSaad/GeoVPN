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

		var logPre = E('pre', { 'class': 'gv-log-box' }, [
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
			'style': 'display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 12px;'
		}, [
			E('label', {}, [ _('Source:'), E('span', { 'style': 'margin-inline-start: 4px;' }), sourceSelect ]),
			E('label', {}, [ _('Lines:'), E('span', { 'style': 'margin-inline-start: 4px;' }), linesSelect ]),
			E('label', { 'style': 'cursor: pointer; display: flex; align-items: center; gap: 4px;' }, [
				autoRefreshCheck,
				_('Auto-refresh (3s)')
			]),
			E('div', { 'style': 'margin-inline-start: auto; display: flex; gap: 8px;' }, [
				refreshBtn,
				copyBtn
			])
		]);

		var logsCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('System & OpenVPN Logs') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('All logs are automatically scrubbed on the router to remove certificates, private keys, and passwords before display.')
			]),
			logControls,
			logPre
		]);

		// ----------------------------------------------------
		// 2. Diagnostics Checklist Card
		// ----------------------------------------------------
		var diagChecksTable = E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', { 'style': 'width: 100px;' }, [ _('Status') ]),
					E('th', {}, [ _('Component Check') ]),
					E('th', {}, [ _('Details & Recommendations') ])
				])
			]),
			E('tbody')
		]);

		var tbody = diagChecksTable.querySelector('tbody');
		var checks = diagData.checks || [];

		if (checks.length === 0) {
			dom.append(tbody, E('tr', {}, [
				E('td', { 'colspan': '3', 'style': 'text-align: center; color: #57606a;' }, [
					_('No diagnostic checks available.')
				])
			]));
		} else {
			checks.forEach(function(c) {
				var badgeCls = 'gv-badge-disabled';
				var badgeText = c.level ? c.level.toUpperCase() : 'INFO';

				if (c.level === 'ok') {
					badgeCls = 'gv-badge-connected';
				} else if (c.level === 'warn') {
					badgeCls = 'gv-badge-connecting';
				} else if (c.level === 'fail') {
					badgeCls = 'gv-badge-error';
				}

				var badge = E('span', { 'class': 'gv-badge ' + badgeCls }, [ badgeText ]);

				var details = [ E('span', {}, [ c.msg || '' ]) ];
				if (c.hint) {
					details.push(E('div', { 'style': 'margin-top: 4px; font-size: 0.85rem; color: #57606a;' }, [
						_('Hint: ') + c.hint
					]));
				}

				dom.append(tbody, E('tr', {}, [
					E('td', {}, [ badge ]),
					E('td', { 'style': 'font-weight: 600;' }, [ widgets.renderLtr(c.id || '-') ]),
					E('td', {}, details)
				]));
			});
		}

		var diagCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('System Diagnostics Checklist') ]),
				diagData.ok ?
					E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('All Systems OK ✔') ]) :
					E('span', { 'class': 'gv-badge gv-badge-connecting' }, [ _('Warnings Detected') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('Preflight verification checks kernel modules, binaries, firewall rules, and coexistence with other packages.')
			]),
			diagChecksTable
		]);

		// ----------------------------------------------------
		// 3. Leak Self-Test & Diagnostic Export Card
		// ----------------------------------------------------
		var selfTestResults = E('div', {
			'style': 'margin-top: 12px; padding: 12px; border-radius: 6px; background: #f6f8fa; border: 1px solid #d0d7de; display: none;'
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
							: E('span', { 'class': 'gv-badge', 'style': 'background-color: #ddf4ff; color: #0969da; border: 1px solid #54aeff;' }, [ _('VPN') ]);

						var reason = (r.reason && r.reason.layer) ? (r.reason.layer + ' / ' + (r.reason.rule || '')) : 'default';

						dom.append(selfTestResults, E('div', {
							'style': 'display: flex; align-items: center; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #e1e4e8;'
						}, [
							E('span', { 'style': 'font-weight: 600;' }, [ widgets.renderLtr(testTargets[idx]) ]),
							E('div', { 'style': 'display: flex; gap: 10px; align-items: center;' }, [
								E('span', { 'style': 'font-size: 0.85rem; color: #57606a;' }, [ reason ]),
								verdictBadge
							])
						]));
					});
				}).catch(function(err) {
					ui.hideIndicator();
					dom.content(selfTestResults, [
						E('span', { 'style': 'color: red;' }, [ _('Test failed: ') + err ])
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

		var leakTestCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Leak Testing & Export') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 12px;' }, [
				_('Run simulated destination verification to test split-tunnel routing decisions, or export a safe, scrubbed diagnostics bundle for troubleshooting.')
			]),
			E('div', { 'class': 'gv-actions' }, [
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
