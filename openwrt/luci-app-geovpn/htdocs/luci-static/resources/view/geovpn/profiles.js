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
			api.listCredentials(),
			api.testResults()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var statusData = (data && data[1]) || {};
		var credData = (data && data[2] && data[2].items) || [];
		var testCacheData = (data && data[3] && data[3].items) || [];
		var activeProfileId = uci.get('geovpn', 'main', 'active_profile') || '';

		var testResultMap = {};
		testCacheData.forEach(function(item) {
			if (item && item.id) testResultMap[item.id] = item;
		});

		// 1. Status Card
		var statusCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('Service Status') ]),
				widgets.renderBadge(statusData.service ? statusData.service.state : 'disabled')
			]),
			E('div', {
				'class': 'gv-grid',
				'style': 'display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin: 14px 0;'
			}, [
				E('div', {
					'class': 'gv-metric',
					'style': 'padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column;'
				}, [
					E('div', { 'class': 'gv-metric-label', 'style': 'font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; font-weight: 600;' }, [ _('Active Profile') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all;' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.name) || activeProfileId || _('None'))
					])
				]),
				E('div', {
					'class': 'gv-metric',
					'style': 'padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column;'
				}, [
					E('div', { 'class': 'gv-metric-label', 'style': 'font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; font-weight: 600;' }, [ _('Tunnel Device') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all;' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.device) || 'geovpn0')
					])
				]),
				E('div', {
					'class': 'gv-metric',
					'style': 'padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column;'
				}, [
					E('div', { 'class': 'gv-metric-label', 'style': 'font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; font-weight: 600;' }, [ _('Assigned IP') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all;' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.local_ip) || '-')
					])
				]),
				E('div', {
					'class': 'gv-metric',
					'style': 'padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column;'
				}, [
					E('div', { 'class': 'gv-metric-label', 'style': 'font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; font-weight: 600;' }, [ _('Uptime') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all;' }, [
						widgets.formatUptime(statusData.tunnel ? statusData.tunnel.uptime : 0)
					])
				]),
				E('div', {
					'class': 'gv-metric',
					'style': 'padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column;'
				}, [
					E('div', { 'class': 'gv-metric-label', 'style': 'font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; font-weight: 600;' }, [ _('Traffic (RX / TX)') ]),
					E('div', { 'class': 'gv-metric-value', 'style': 'font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all;' }, [
						widgets.formatBytes((statusData.tunnel && statusData.tunnel.rx_bytes) || 0) + ' / ' +
						widgets.formatBytes((statusData.tunnel && statusData.tunnel.tx_bytes) || 0)
					])
				])
			]),
			E('div', {
				'class': 'gv-actions',
				'style': 'display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; align-items: center;'
			}, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': function() {
						ui.showIndicator();
						api.callService('start').then(function() {
							ui.hideIndicator();
							location.reload();
						});
					}
				}, [ _('Start') ]),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function() {
						ui.showIndicator();
						api.callService('stop').then(function() {
							ui.hideIndicator();
							location.reload();
						});
					}
				}, [ _('Stop') ]),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function() {
						ui.showIndicator();
						api.callService('restart').then(function() {
							ui.hideIndicator();
							location.reload();
						});
					}
				}, [ _('Restart') ]),
				E('button', {
					'class': 'cbi-button cbi-button-remove',
					'style': 'margin-inline-start: auto;',
					'click': function() {
						if (confirm(_('Emergency stop: tear down all rules and disable GeoVPN?'))) {
							ui.showIndicator();
							api.callPanic().then(function() {
								ui.hideIndicator();
								location.reload();
							});
						}
					}
				}, [ _('Emergency Stop (Panic)') ])
			])
		]);

		// 2. Profiles Table Section
		var profiles = uci.sections('geovpn', 'profile') || [];
		var maxDisplay = 200;
		var displayProfiles = profiles.slice(0, maxDisplay);
		var isCapped = (profiles.length > maxDisplay);

		var profilesTable = E('table', {
			'class': 'table cbi-section-table',
			'style': 'width: 100%; border-collapse: collapse; margin-top: 8px;'
		}, [
			E('thead', {}, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Profile') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Protocol & Provider') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Server Endpoint') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Credentials') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: center;' }, [ _('Status') ]),
					E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: end;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		var tbody = profilesTable.querySelector('tbody');

		if (profiles.length === 0) {
			dom.append(tbody, E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '6', 'style': 'text-align: center; padding: 32px 16px; opacity: 0.85;' }, [
					E('p', { 'style': 'margin-bottom: 14px; font-size: 0.95rem;' }, [
						_('No VPN profiles configured. Create an IKEv2 profile directly or import .ovpn / .conf files.')
					]),
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'style': 'margin-inline-end: 8px;',
						'click': function() { showAddProfileModal(); }
					}, [ _('+ Add Profile') ]),
					E('a', {
						'class': 'cbi-button cbi-button-action',
						'href': L.url('admin/vpn/geovpn/importer')
					}, [ _('+ Import Profiles') ])
				])
			]));
		} else {
			displayProfiles.forEach(function(p, idx) {
				var pid = p['.name'];
				var isActive = (pid === activeProfileId);
				var proto = p.proto || 'openvpn';
				var provider = p.provider || 'generic';

				// Endpoint text
				var endpointText = '-';
				if (proto === 'wireguard') {
					if (p.wg_endpoint_host) {
						endpointText = p.wg_endpoint_host + ':' + (p.wg_endpoint_port || '51820');
					}
				} else if (proto === 'ikev2') {
					endpointText = p.ike_host || '-';
				} else {
					var remotes = p.remote || [];
					if (!Array.isArray(remotes)) remotes = [remotes];
					endpointText = remotes[0] || '-';
				}

				// Auth / Secret indicator
				var authDesc = _('None');
				if (proto === 'wireguard') {
					if (p.has_wg_key || p.cred) {
						authDesc = (p.has_wg_psk === '1' || p.wg_has_psk === '1') ? _('Key + PSK') : _('Key');
					} else {
						authDesc = _('Key required');
					}
				} else if (proto === 'ikev2') {
					if (p.has_ike_secret === '1' || p.has_ike_secret === true || p.cred) {
						authDesc = p.cred ? _('Shared EAP-MSCHAPv2') : _('EAP-MSCHAPv2');
					} else {
						authDesc = _('Password required');
					}
				} else {
					if (p.auth_user_pass === '1') {
						authDesc = p.cred ? _('Shared User/Pass') : _('User/Pass');
					} else {
						authDesc = _('Certificate');
					}
				}

				// Action buttons: Connect, Test, Edit, Delete
				var actionBtns = [
					E('button', {
						'class': 'cbi-button ' + (isActive ? 'cbi-button-positive' : 'cbi-button-action'),
						'disabled': isActive ? 'true' : null,
						'click': function() {
							uci.set('geovpn', 'main', 'active_profile', pid);
							uci.save();
							uci.apply().then(function() {
								location.reload();
							});
						}
					}, [ isActive ? _('Active ✔') : _('Connect') ]),
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							runSingleProfileTest(pid, p.name || pid);
						}
					}, [ _('Test') ]),
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							showEditModal(pid, p.name || pid, proto);
						}
					}, [ _('Edit') ]),
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function() {
							if (confirm(_('Delete profile "%s"?').format(p.name || pid))) {
								api.deleteProfile(pid).then(function() {
									location.reload();
								});
							}
						}
					}, [ _('Delete') ])
				];

				dom.append(tbody, E('tr', {
					'class': 'tr cbi-rowstyle-' + (idx % 2 + 1),
					'style': 'border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15));'
				}, [
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; font-weight: 600;' }, [
						E('div', {}, [ p.name || pid ]),
						(testResultMap[pid]) ? E('div', { 'style': 'margin-top: 4px;' }, [
							widgets.renderTestStatusBadge(testResultMap[pid].status),
							testResultMap[pid].url && (testResultMap[pid].url.median_ms != null || testResultMap[pid].url.median != null) ?
								E('span', { 'style': 'font-size: 0.78rem; opacity: 0.8; margin-inline-start: 6px;' }, [
									widgets.renderLtr(Math.round(testResultMap[pid].url.median_ms != null ? testResultMap[pid].url.median_ms : testResultMap[pid].url.median) + ' ms')
								]) : E('span')
						]) : E('span')
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [
						E('div', { 'style': 'display: flex; gap: 6px; align-items: center;' }, [
							widgets.renderProtoBadge(proto),
							widgets.renderProviderBadge(provider)
						])
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [ widgets.renderLtr(endpointText) ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [ authDesc ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [
						isActive ? widgets.renderBadge('connected') : widgets.renderBadge('disabled')
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: end;' }, actionBtns)
				]));
			});
		}

		// Single Profile Test Modal Runner
		function runSingleProfileTest(profileId, profileName) {
			var progressBox = E('div', { 'style': 'padding: 16px; text-align: center;' }, [
				E('div', { 'class': 'cbi-progressbar', 'title': _('Testing...') }, [
					E('div', { 'style': 'width: 100%;' })
				]),
				E('p', { 'style': 'margin-top: 12px; font-size: 0.9rem;' }, [
					_('Testing profile "%s" (handshake & HTTP probe)...').format(profileName)
				])
			]);

			ui.showModal(_('Pre-Connection Test'), [ progressBox ]);

			api.testStart([profileId], false, '').then(function(startRes) {
				if (!startRes || !startRes.job_id) {
					ui.hideModal();
					ui.addNotification(null, E('p', {}, [ _('Cannot start test: ') + ((startRes && startRes.message) || _('Engine busy')) ]), 'error');
					return;
				}

				var jobId = startRes.job_id;
				var pollTimer = null;

				function poll() {
					api.testStatus(jobId).then(function(st) {
						if (!st || st.state === 'running') {
							pollTimer = window.setTimeout(poll, 1500);
							return;
						}

						// Test done
						if (pollTimer) window.clearTimeout(pollTimer);
						var res = (st.results && st.results.length > 0) ? st.results[0] : null;
						renderTestDoneModal(profileId, profileName, res);
					}).catch(function(err) {
						if (pollTimer) window.clearTimeout(pollTimer);
						ui.hideModal();
						ui.addNotification(null, E('p', {}, [ _('Test poll error: ') + err ]), 'error');
					});
				}

				pollTimer = window.setTimeout(poll, 1200);
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ _('Test failed to launch: ') + err ]), 'error');
			});
		}

		function renderTestDoneModal(profileId, profileName, res) {
			var status = (res && res.status) ? res.status : 'fail';
			var handshakeMs = (res && res.handshake_ms != null) ? (res.handshake_ms + ' ms') : '-';
			var latVal = (res && res.url && res.url.median_ms != null) ? res.url.median_ms : ((res && res.url && res.url.median != null) ? res.url.median : null);
			var latencyMs = (latVal != null) ? (Math.round(latVal) + ' ms') : '-';
			var reason = (res && res.reason) ? res.reason : _('OK');
			var hint = (res && res.hint) ? res.hint : '';

			var content = E('div', {}, [
				E('h4', { 'style': 'margin-bottom: 12px;' }, [ _('Test Result: %s').format(profileName) ]),
				E('div', { 'style': 'margin-bottom: 14px;' }, [
					widgets.renderTestStatusBadge(status),
					E('span', { 'style': 'margin-inline-start: 10px; font-weight: 600;' }, [
						(status === 'pass') ? _('Connection & HTTP probes successful') :
						(status === 'warn') ? _('Connection succeeded with warnings') : _('Connection test failed')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Handshake Latency') ]),
					E('div', { 'class': 'cbi-value-field' }, [ widgets.renderLtr(handshakeMs) ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('HTTP Probe Latency') ]),
					E('div', { 'class': 'cbi-value-field' }, [ widgets.renderLtr(latencyMs) ])
				]),
				(hint) ? E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Diagnostic Hint') ]),
					E('div', { 'class': 'cbi-value-field', 'style': 'color: #d29922;' }, [ hint ])
				]) : E('span'),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
					E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); location.reload(); } }, [ _('Close') ]),
					(status !== 'fail') ? E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function() {
							ui.showIndicator();
							uci.set('geovpn', 'main', 'active_profile', profileId);
							uci.save();
							uci.apply().then(function() {
								api.callService('restart').then(function() {
									ui.hideIndicator();
									ui.hideModal();
									location.reload();
								});
							});
						}
					}, [ _('Connect Now') ]) : E('span')
				])
			]);

			ui.showModal(_('Test Result'), [ content ]);
		}

		// Protocol-Aware Edit Profile Modal (Write-Only Secrets)
		function showEditModal(profileId, profileName, proto) {
			ui.showIndicator();
			api.getProfile(profileId).then(function(res) {
				ui.hideIndicator();
				var pData = res || {};
				var pProto = pData.proto || proto || 'openvpn';

				var nameInput = E('input', {
					'type': 'text',
					'class': 'cbi-input-text',
					'value': pData.name || profileName || profileId,
					'style': 'width: 100%;'
				});

				var modalBody = E('div', {});

				// Header
				dom.append(modalBody, E('h4', { 'style': 'margin-bottom: 8px;' }, [
					_('Edit Profile: "%s"').format(profileName || profileId)
				]));
				dom.append(modalBody, E('div', { 'style': 'display: flex; gap: 8px; margin-bottom: 16px;' }, [
					widgets.renderProtoBadge(pProto),
					widgets.renderProviderBadge(pData.provider || 'generic')
				]));

				dom.append(modalBody, E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 12px;' }, [
					E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Profile Name') ]),
					E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
				]));

				// Protocol Branching
				if (pProto === 'wireguard') {
					var hostInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.wg_endpoint_host || '', 'placeholder': 'e.g. vpn.example.com or 198.51.100.1' });
					var portInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': pData.wg_endpoint_port || 51820, 'min': '1', 'max': '65535' });
					var pubKeyInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.wg_public_key || '', 'placeholder': 'base64 public key' });
					var allowedIpsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (pData.wg_allowed_ips || ['0.0.0.0/0']).join(', ') });
					var addrInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (pData.wg_address || []).join(', '), 'placeholder': '10.0.0.2/32' });
					var dnsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (pData.wg_dns || []).join(', '), 'placeholder': '10.255.255.3, 1.1.1.1' });
					var mtuInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': pData.wg_mtu || 1420 });
					var keepaliveInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': pData.wg_keepalive || 25 });

					// WRITE-ONLY SECRET INPUTS (never prefilled!)
					var privKeyInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter new private key (leave empty to keep unchanged)'),
						'autocomplete': 'new-password'
					});
					var pskInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter new preshared key (leave empty to keep unchanged)'),
						'autocomplete': 'new-password'
					});

					// Shared Credential Set selector
					var credOptions = [ E('option', { 'value': '' }, [ _('None (use profile key file)') ]) ];
					credData.forEach(function(c) {
						var opt = E('option', { 'value': c.id, 'selected': (pData.cred === c.id) ? 'selected' : null }, [
							c.id + (c.has_wg_key ? ' (WG key)' : '')
						]);
						credOptions.push(opt);
					});
					var credSelect = E('select', { 'class': 'cbi-input-select' }, credOptions);

					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Endpoint Host') ]),
						E('div', { 'class': 'cbi-value-field' }, [ hostInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Endpoint Port') ]),
						E('div', { 'class': 'cbi-value-field' }, [ portInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Server Public Key') ]),
						E('div', { 'class': 'cbi-value-field' }, [ pubKeyInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Interface Address') ]),
						E('div', { 'class': 'cbi-value-field' }, [ addrInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Allowed IPs') ]),
						E('div', { 'class': 'cbi-value-field' }, [ allowedIpsInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('DNS Resolvers') ]),
						E('div', { 'class': 'cbi-value-field' }, [ dnsInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('MTU / Keepalive') ]),
						E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; gap: 8px;' }, [
							mtuInput, keepaliveInput
						])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Shared Credential Set') ]),
						E('div', { 'class': 'cbi-value-field' }, [ credSelect ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Private Key (Secret)') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							privKeyInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: current private key is never displayed to prevent exposure.')
							])
						])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Preshared Key (Optional)') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							pskInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: leave empty unless updating preshared key.')
							])
						])
					]));

					var wgSaveBtn = E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function() {
							ui.showIndicator();
							var addrs = addrInput.value.split(',').map(function(s) { return s.trim(); }).filter(Boolean);
							var aips = allowedIpsInput.value.split(',').map(function(s) { return s.trim(); }).filter(Boolean);
							var dnss = dnsInput.value.split(',').map(function(s) { return s.trim(); }).filter(Boolean);

							api.saveProfileRaw(profileId, nameInput.value.trim(), '', '', {
								proto: 'wireguard',
								wg_endpoint_host: hostInput.value.trim(),
								wg_endpoint_port: portInput.value.trim(),
								wg_public_key: pubKeyInput.value.trim(),
								wg_address: addrs,
								wg_allowed_ips: aips,
								wg_dns: dnss,
								wg_mtu: mtuInput.value.trim(),
								wg_keepalive: keepaliveInput.value.trim(),
								cred: credSelect.value,
								wg_key: privKeyInput.value.trim(),
								wg_psk: pskInput.value.trim()
							}).then(function(sRes) {
								ui.hideIndicator();
								ui.hideModal();
								if (sRes && sRes.ok) {
									ui.addNotification(null, E('p', {}, [ _('WireGuard profile updated successfully.') ]), 'info');
									location.reload();
								} else {
									ui.addNotification(null, E('p', {}, [ _('Error updating profile: ') + ((sRes && sRes.message) || _('Failed')) ]), 'error');
								}
							}).catch(function(err) {
								ui.hideIndicator();
								ui.addNotification(null, E('p', {}, [ _('Save error: ') + err ]), 'error');
							});
						}
					}, [ _('Save') ]);

					dom.append(modalBody, E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
						wgSaveBtn
					]));

				} else if (pProto === 'ikev2') {
					var hostInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.ike_host || '', 'placeholder': 'e.g. vpn.example.com or 198.51.100.1' });
					var remoteIdInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.ike_remote_id || '', 'placeholder': 'e.g. vpn.example.com' });
					var userInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.ike_username || '', 'placeholder': _('Enter username') });
					var caInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': pData.ike_ca || 'geovpn-isrg-x1.pem', 'placeholder': 'geovpn-isrg-x1.pem' });
					var dpdInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': pData.ike_dpd || 30, 'min': '0', 'max': '3600' });

					// WRITE-ONLY SECRET INPUT (never prefilled!)
					var passInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter new password (leave empty to keep unchanged)'),
						'autocomplete': 'new-password'
					});

					// Shared Credential Set selector
					var credOptions = [ E('option', { 'value': '' }, [ _('None (use profile secret file)') ]) ];
					credData.forEach(function(c) {
						var opt = E('option', { 'value': c.id, 'selected': (pData.cred === c.id) ? 'selected' : null }, [
							c.id + (c.has_auth ? ' (User/Pass)' : '')
						]);
						credOptions.push(opt);
					});
					var credSelect = E('select', { 'class': 'cbi-input-select' }, credOptions);

					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Endpoint Host') ]),
						E('div', { 'class': 'cbi-value-field' }, [ hostInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Remote Identity (ID)') ]),
						E('div', { 'class': 'cbi-value-field' }, [ remoteIdInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Username') ]),
						E('div', { 'class': 'cbi-value-field' }, [ userInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Password (Write-Only)') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							passInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: current password is never displayed to prevent exposure.')
							])
						])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Shared Credential Set') ]),
						E('div', { 'class': 'cbi-value-field' }, [ credSelect ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('CA Certificate File') ]),
						E('div', { 'class': 'cbi-value-field' }, [ caInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Dead Peer Detection (s)') ]),
						E('div', { 'class': 'cbi-value-field' }, [ dpdInput ])
					]));

					var ikeSaveBtn = E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function() {
							ui.showIndicator();
							api.saveProfileRaw(profileId, nameInput.value.trim(), '', '', {
								proto: 'ikev2',
								ike_host: hostInput.value.trim(),
								ike_remote_id: remoteIdInput.value.trim(),
								ike_username: userInput.value.trim(),
								ike_ca: caInput.value.trim(),
								ike_dpd: dpdInput.value.trim(),
								cred: credSelect.value,
								password: passInput.value.trim()
							}).then(function(sRes) {
								ui.hideIndicator();
								ui.hideModal();
								if (sRes && sRes.ok) {
									ui.addNotification(null, E('p', {}, [ _('IKEv2 profile updated successfully.') ]), 'info');
									location.reload();
								} else {
									ui.addNotification(null, E('p', {}, [ _('Error updating profile: ') + ((sRes && sRes.message) || _('Failed')) ]), 'error');
								}
							}).catch(function(err) {
								ui.hideIndicator();
								ui.addNotification(null, E('p', {}, [ _('Save error: ') + err ]), 'error');
							});
						}
					}, [ _('Save') ]);

					dom.append(modalBody, E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
						ikeSaveBtn
					]));
				} else {
					// OpenVPN profile
					var ovpnText = (pData && pData.ovpn) ? pData.ovpn : '';
					var authText = (pData && pData.auth) ? pData.auth : '';

					var ovpnArea = E('textarea', {
						'class': 'gv-editor-textarea',
						'rows': '10',
						'placeholder': '# Enter OpenVPN configuration directives...'
					}, [ ovpnText ]);

					// Write-only credentials
					var userInput = E('input', {
						'type': 'text',
						'class': 'cbi-input-text',
						'placeholder': _('Enter username')
					});
					if (authText) {
						var authLines = authText.split('\n');
						if (authLines.length > 0 && authLines[0]) userInput.value = authLines[0];
					}

					var passInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter new password (leave empty to keep unchanged)'),
						'autocomplete': 'new-password'
					});

					dom.append(modalBody, E('div', { 'style': 'margin-bottom: 14px;' }, [
						E('label', { 'style': 'font-weight: 600; display: block; margin-bottom: 4px;' }, [
							_('OpenVPN Configuration File')
						]),
						ovpnArea
					]));

					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Username') ]),
						E('div', { 'class': 'cbi-value-field' }, [ userInput ])
					]));
					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Password (Write-Only)') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							passInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: current password is never prefilled to prevent exposure.')
							])
						])
					]));

					// Shared Credential Set selector
					var ovpnCredOptions = [ E('option', { 'value': '' }, [ _('None (inline username/password)') ]) ];
					credData.forEach(function(c) {
						var opt = E('option', { 'value': c.id, 'selected': (pData.cred === c.id) ? 'selected' : null }, [
							c.id + (c.has_auth ? ' [User/Pass]' : '')
						]);
						ovpnCredOptions.push(opt);
					});
					var ovpnCredSelect = E('select', { 'class': 'cbi-input-select' }, ovpnCredOptions);

					dom.append(modalBody, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Shared Credential Set') ]),
						E('div', { 'class': 'cbi-value-field' }, [ ovpnCredSelect ])
					]));

					var ovpnSaveBtn = E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function() {
							ui.showIndicator();
							var newAuth = null;
							if (userInput.value.trim() || passInput.value) {
								var pw = passInput.value;
								if (!pw && authText) {
									var aLines = authText.split('\n');
									if (aLines.length >= 2) pw = aLines[1];
								}
								newAuth = userInput.value.trim() + '\n' + pw + '\n';
							}

							api.saveProfileRaw(profileId, nameInput.value.trim(), ovpnArea.value, newAuth, {
								cred: ovpnCredSelect.value
							}).then(function(sRes) {
								ui.hideIndicator();
								ui.hideModal();
								if (sRes && sRes.ok) {
									ui.addNotification(null, E('p', {}, [ _('OpenVPN profile updated successfully.') ]), 'info');
									location.reload();
								} else {
									ui.addNotification(null, E('p', {}, [ _('Error saving profile: ') + ((sRes && sRes.message) || _('Failed')) ]), 'error');
								}
							}).catch(function(err) {
								ui.hideIndicator();
								ui.addNotification(null, E('p', {}, [ _('Save error: ') + err ]), 'error');
							});
						}
					}, [ _('Save') ]);

					dom.append(modalBody, E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
						ovpnSaveBtn
					]));
				}

				ui.showModal(_('Edit Profile'), [ modalBody ]);
			}).catch(function(err) {
				ui.hideIndicator();
				ui.addNotification(null, E('p', {}, [ _('Failed to load profile: ') + err ]), 'error');
			});
		}

		// Add Profile Modal (Manual Creation)
		function showAddProfileModal() {
			var modalBody = E('div', {});

			dom.append(modalBody, E('h4', { 'style': 'margin-bottom: 8px;' }, [
				_('Add VPN Profile')
			]));
			dom.append(modalBody, E('p', { 'style': 'color: #57606a; margin-bottom: 16px; font-size: 0.9rem;' }, [
				_('Create a new VPN connection profile directly by specifying endpoint and credentials.')
			]));

			var protoSelect = E('select', { 'class': 'cbi-input-select', 'style': 'width: 100%;' }, [
				E('option', { 'value': 'ikev2', 'selected': 'selected' }, [ _('IKEv2 / IPsec (strongSwan)') ]),
				E('option', { 'value': 'openvpn' }, [ _('OpenVPN') ]),
				E('option', { 'value': 'wireguard' }, [ _('WireGuard') ])
			]);

			var nameInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. Frankfurt Server'),
				'style': 'width: 100%;'
			});

			var hostInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. vpn.example.com or 198.51.100.1'),
				'style': 'width: 100%;'
			});

			var protoFieldsContainer = E('div', { 'style': 'margin-top: 12px;' });
			var connectImmediatelyCheck = E('input', { 'type': 'checkbox' });

			function updateProtoFields() {
				dom.content(protoFieldsContainer, []);
				var p = protoSelect.value;

				if (p === 'ikev2') {
					var userInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Enter username') });
					var passInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter password'),
						'autocomplete': 'new-password'
					});
					var remoteIdInput = E('input', {
						'type': 'text',
						'class': 'cbi-input-text',
						'placeholder': _('Defaults to Server Hostname if left empty')
					});
					var caInput = E('input', {
						'type': 'text',
						'class': 'cbi-input-text',
						'value': 'geovpn-isrg-x1.pem'
					});
					var dpdInput = E('input', {
						'type': 'number',
						'class': 'cbi-input-text',
						'value': '30',
						'min': '0',
						'max': '3600'
					});

					var credOptions = [ E('option', { 'value': '' }, [ _('None (use direct username/password)') ]) ];
					credData.forEach(function(c) {
						if (c.has_auth) {
							credOptions.push(E('option', { 'value': c.id }, [ c.id + ' (User/Pass)' ]));
						}
					});
					var credSelect = E('select', { 'class': 'cbi-input-select' }, credOptions);

					protoFieldsContainer._fields = {
						userInput: userInput,
						passInput: passInput,
						remoteIdInput: remoteIdInput,
						caInput: caInput,
						dpdInput: dpdInput,
						credSelect: credSelect
					};

					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Username') ]),
						E('div', { 'class': 'cbi-value-field' }, [ userInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Password') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							passInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: password is saved securely with 0600 permissions.')
							])
						])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Remote Identity (ID)') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							remoteIdInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Defaults to Server Hostname if left empty')
							])
						])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('CA Certificate File') ]),
						E('div', { 'class': 'cbi-value-field' }, [ caInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Dead Peer Detection (s)') ]),
						E('div', { 'class': 'cbi-value-field' }, [ dpdInput ])
					]));
					if (credOptions.length > 1) {
						dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Shared Credential Set') ]),
							E('div', { 'class': 'cbi-value-field' }, [ credSelect ])
						]));
					}
				} else if (p === 'wireguard') {
					var portInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': '51820', 'min': '1', 'max': '65535' });
					var pubKeyInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Server base64 public key') });
					var privKeyInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Client private key'),
						'autocomplete': 'new-password'
					});
					var pskInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Preshared key (optional)'),
						'autocomplete': 'new-password'
					});
					var addrInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '10.0.0.2/32' });
					var allowedIpsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': '0.0.0.0/0' });

					protoFieldsContainer._fields = {
						portInput: portInput,
						pubKeyInput: pubKeyInput,
						privKeyInput: privKeyInput,
						pskInput: pskInput,
						addrInput: addrInput,
						allowedIpsInput: allowedIpsInput
					};

					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Endpoint Port') ]),
						E('div', { 'class': 'cbi-value-field' }, [ portInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Server Public Key') ]),
						E('div', { 'class': 'cbi-value-field' }, [ pubKeyInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Client Private Key') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							privKeyInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: client private key is saved securely with 0600 permissions.')
							])
						])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Preshared Key (Optional)') ]),
						E('div', { 'class': 'cbi-value-field' }, [ pskInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Interface Address') ]),
						E('div', { 'class': 'cbi-value-field' }, [ addrInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Allowed IPs') ]),
						E('div', { 'class': 'cbi-value-field' }, [ allowedIpsInput ])
					]));
				} else {
					// OpenVPN
					var portInput = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': '1194', 'min': '1', 'max': '65535' });
					var protoModeSelect = E('select', { 'class': 'cbi-input-select' }, [
						E('option', { 'value': 'udp', 'selected': 'selected' }, [ 'UDP' ]),
						E('option', { 'value': 'tcp' }, [ 'TCP' ])
					]);
					var userInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Enter username') });
					var passInput = E('input', {
						'type': 'password',
						'class': 'cbi-input-text',
						'placeholder': _('Enter password'),
						'autocomplete': 'new-password'
					});

					protoFieldsContainer._fields = {
						portInput: portInput,
						protoModeSelect: protoModeSelect,
						userInput: userInput,
						passInput: passInput
					};

					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Server Port & Protocol') ]),
						E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; gap: 8px;' }, [
							portInput, protoModeSelect
						])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Username') ]),
						E('div', { 'class': 'cbi-value-field' }, [ userInput ])
					]));
					dom.append(protoFieldsContainer, E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('Password') ]),
						E('div', { 'class': 'cbi-value-field' }, [
							passInput,
							E('div', { 'style': 'font-size: 0.78rem; opacity: 0.75; margin-top: 4px;' }, [
								_('Write-only: password is saved securely with 0600 permissions.')
							])
						])
					]));
				}
			}

			protoSelect.addEventListener('change', updateProtoFields);
			updateProtoFields();

			dom.append(modalBody, E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 12px;' }, [
				E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Protocol') ]),
				E('div', { 'class': 'cbi-value-field' }, [ protoSelect ])
			]));

			dom.append(modalBody, E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 12px;' }, [
				E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Profile Name') ]),
				E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
			]));

			dom.append(modalBody, E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 12px;' }, [
				E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Server Hostname / IP') ]),
				E('div', { 'class': 'cbi-value-field' }, [ hostInput ])
			]));

			dom.append(modalBody, protoFieldsContainer);

			dom.append(modalBody, E('div', { 'class': 'cbi-value', 'style': 'margin-top: 14px;' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Connect Immediately') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					connectImmediatelyCheck,
					E('span', { 'style': 'margin-inline-start: 8px; font-size: 0.85rem;' }, [
						_('Connect to this profile immediately after creation')
					])
				])
			]));

			var addBtn = E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': function() {
					var hostVal = hostInput.value.trim();
					if (!hostVal) {
						ui.addNotification(null, E('p', {}, [ _('Server Hostname / IP is required') ]), 'error');
						return;
					}

					var protoVal = protoSelect.value;
					var nameVal = nameInput.value.trim() || hostVal;
					var fields = protoFieldsContainer._fields || {};

					var extra = {};
					if (protoVal === 'ikev2') {
						extra.username = fields.userInput ? fields.userInput.value.trim() : '';
						extra.password = fields.passInput ? fields.passInput.value.trim() : '';
						extra.remote_id = fields.remoteIdInput ? fields.remoteIdInput.value.trim() : '';
						extra.ca = fields.caInput ? fields.caInput.value.trim() : 'geovpn-isrg-x1.pem';
						extra.dpd = fields.dpdInput ? fields.dpdInput.value.trim() : 30;
						extra.cred = fields.credSelect ? fields.credSelect.value : '';

						if (!extra.username) {
							ui.addNotification(null, E('p', {}, [ _('Username is required for IKEv2') ]), 'error');
							return;
						}
					} else if (protoVal === 'wireguard') {
						extra.port = fields.portInput ? fields.portInput.value.trim() : 51820;
						extra.public_key = fields.pubKeyInput ? fields.pubKeyInput.value.trim() : '';
						extra.private_key = fields.privKeyInput ? fields.privKeyInput.value.trim() : '';
						extra.preshared_key = fields.pskInput ? fields.pskInput.value.trim() : '';
						extra.address = fields.addrInput ? fields.addrInput.value.trim().split(',').map(function(s){return s.trim();}).filter(Boolean) : [];
						extra.allowed_ips = fields.allowedIpsInput ? fields.allowedIpsInput.value.trim().split(',').map(function(s){return s.trim();}).filter(Boolean) : ['0.0.0.0/0'];
					} else {
						extra.port = fields.portInput ? fields.portInput.value.trim() : 1194;
						extra.ovpn_proto = fields.protoModeSelect ? fields.protoModeSelect.value : 'udp';
						extra.username = fields.userInput ? fields.userInput.value.trim() : '';
						extra.password = fields.passInput ? fields.passInput.value.trim() : '';
					}

					ui.showIndicator();
					api.addProfile(nameVal, protoVal, hostVal, extra.username || '', extra.password || '', extra).then(function(res) {
						if (!res || !res.ok) {
							ui.hideIndicator();
							ui.addNotification(null, E('p', {}, [ _('Failed to add profile: ') + ((res && res.message) || _('Unknown error')) ]), 'error');
							return;
						}

						var newId = res.id;
						if (connectImmediatelyCheck.checked && newId) {
							uci.set('geovpn', 'main', 'active_profile', newId);
							uci.save();
							uci.apply().then(function() {
								api.callService('restart').then(function() {
									ui.hideIndicator();
									ui.hideModal();
									location.reload();
								});
							});
						} else {
							ui.hideIndicator();
							ui.hideModal();
							ui.addNotification(null, E('p', {}, [ _('Profile created successfully.') ]), 'info');
							location.reload();
						}
					}).catch(function(err) {
						ui.hideIndicator();
						ui.addNotification(null, E('p', {}, [ _('Error creating profile: ') + err ]), 'error');
					});
				}
			}, [ _('Add Profile') ]);

			dom.append(modalBody, E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
				addBtn
			]));

			ui.showModal(_('Add VPN Profile'), [ modalBody ]);
		}

		// Action buttons in section title
		var headerActions = E('div', { 'style': 'display: flex; gap: 8px; align-items: center;' }, [
			E('button', {
				'class': 'cbi-button cbi-button-positive',
				'style': 'font-weight: 600;',
				'click': showAddProfileModal
			}, [ _('+ Add Profile') ]),
			E('a', {
				'class': 'cbi-button cbi-button-action',
				'href': L.url('admin/vpn/geovpn/importer')
			}, [ _('+ Import Profiles') ]),
			E('a', {
				'class': 'cbi-button cbi-button-neutral',
				'href': L.url('admin/vpn/geovpn/testpanel')
			}, [ _('Test Panel') ])
		]);

		var wgNotice = null;
		if (statusData.drivers && statusData.drivers.wireguard && !statusData.drivers.wireguard.ok) {
			wgNotice = E('div', {
				'class': 'gv-banner-warn',
				'style': 'margin-bottom: 16px; padding: 12px 16px; border-radius: 6px; background: rgba(234, 179, 8, 0.15); border: 1px solid rgba(234, 179, 8, 0.4); font-size: 0.9rem;'
			}, [
				_('The WireGuard protocol driver is not installed. To enable WireGuard tunnels, install the add-on package: apk add geovpn-wireguard')
			]);
		}

		var ikeNotice = null;
		if (statusData.drivers && statusData.drivers.ikev2 && !statusData.drivers.ikev2.ok) {
			ikeNotice = E('div', {
				'class': 'gv-banner-warn',
				'style': 'margin-bottom: 16px; padding: 12px 16px; border-radius: 6px; background: rgba(234, 179, 8, 0.15); border: 1px solid rgba(234, 179, 8, 0.4); font-size: 0.9rem;'
			}, [
				_('The IKEv2 protocol driver is not installed. To enable IKEv2 tunnels, install the add-on package: apk add geovpn-ikev2')
			]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Connection Profiles') ]),
			statusCard,
			wgNotice ? wgNotice : E('span'),
			ikeNotice ? ikeNotice : E('span'),
			E('div', {
				'class': 'cbi-section gv-card',
				'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
			}, [
				E('div', {
					'class': 'gv-card-title',
					'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
				}, [
					E('span', {}, [
						_('Configured Profiles'),
						E('span', { 'style': 'font-size: 0.85rem; font-weight: 400; opacity: 0.7; margin-inline-start: 8px;' }, [
							'(' + profiles.length + ')'
						])
					]),
					headerActions
				]),
				(isCapped) ? E('div', {
					'class': 'gv-banner-warn',
					'style': 'margin-bottom: 12px; font-size: 0.85rem;'
				}, [
					_('Display capped: Showing first 200 of %d profiles.').format(profiles.length)
				]) : E('span'),
				profilesTable
			])
		]);
	}
});
