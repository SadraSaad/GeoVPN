'use strict';
'require view';
'require ui';
'require uci';
'require dom';
'require poll';
'require geovpn.api as api';
'require geovpn.widgets as widgets';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('geovpn'),
			api.getStatus()
		]);
	},

	render: function(data) {
		var statusData = data[1] || {};
		var activeProfileId = uci.get('geovpn', 'main', 'active_profile') || '';

		// 1. Status Card
		var statusCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Service Status') ]),
				widgets.renderBadge(statusData.service ? statusData.service.state : 'disabled')
			]),
			E('div', { 'class': 'gv-grid' }, [
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Active Profile') ]),
					E('div', { 'class': 'gv-metric-value' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.name) || activeProfileId || _('None'))
					])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Tunnel Device') ]),
					E('div', { 'class': 'gv-metric-value' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.device) || 'geovpn0')
					])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Assigned IP') ]),
					E('div', { 'class': 'gv-metric-value' }, [
						widgets.renderLtr((statusData.tunnel && statusData.tunnel.local_ip) || '-')
					])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Uptime') ]),
					E('div', { 'class': 'gv-metric-value' }, [
						widgets.formatUptime(statusData.tunnel ? statusData.tunnel.uptime : 0)
					])
				]),
				E('div', { 'class': 'gv-metric' }, [
					E('div', { 'class': 'gv-metric-label' }, [ _('Traffic (RX / TX)') ]),
					E('div', { 'class': 'gv-metric-value' }, [
						widgets.formatBytes((statusData.tunnel && statusData.tunnel.rx_bytes) || 0) + ' / ' +
						widgets.formatBytes((statusData.tunnel && statusData.tunnel.tx_bytes) || 0)
					])
				])
			]),
			E('div', { 'class': 'gv-actions' }, [
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

		// 2. Profiles Table
		var profilesTable = E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', {}, [ _('Name') ]),
					E('th', {}, [ _('Server Endpoint') ]),
					E('th', {}, [ _('Auth') ]),
					E('th', {}, [ _('Status') ]),
					E('th', { 'style': 'text-align: right;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		var tbody = profilesTable.querySelector('tbody');
		var profiles = uci.sections('geovpn', 'profile');

		if (profiles.length === 0) {
			dom.append(tbody, E('tr', {}, [
				E('td', { 'colspan': '5', 'style': 'text-align: center; color: #57606a;' }, [
					_('No OpenVPN profiles configured. Import an .ovpn file to get started.')
				])
			]));
		} else {
			profiles.forEach(function(p) {
				var isActive = (p['.name'] === activeProfileId);
				var remotes = p.remote || [];
				if (!Array.isArray(remotes)) remotes = [remotes];

				var actionBtns = [
					E('button', {
						'class': 'cbi-button ' + (isActive ? 'cbi-button-positive' : 'cbi-button-action'),
						'disabled': isActive ? 'true' : null,
						'click': function() {
							uci.set('geovpn', 'main', 'active_profile', p['.name']);
							uci.save();
							uci.apply().then(function() {
								location.reload();
							});
						}
					}, [ isActive ? _('Active ✔') : _('Make Active') ]),
					E('span', { 'style': 'width: 6px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							showCredentialsModal(p['.name'], p.name);
						}
					}, [ _('Credentials') ]),
					E('span', { 'style': 'width: 6px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function() {
							if (confirm(_('Delete profile "%s"?').format(p.name))) {
								api.deleteProfile(p['.name']).then(function() {
									location.reload();
								});
							}
						}
					}, [ _('Delete') ])
				];

				dom.append(tbody, E('tr', {}, [
					E('td', { 'style': 'font-weight: 600;' }, [ p.name || p['.name'] ]),
					E('td', {}, [ widgets.renderLtr(remotes[0] || '-') ]),
					E('td', {}, [ (p.auth_user_pass === '1') ? _('User/Pass') : _('Certificate') ]),
					E('td', {}, [ isActive ? E('span', { 'style': 'color: #1a7f37; font-weight: 600;' }, [ _('Active') ]) : _('Idle') ]),
					E('td', { 'style': 'text-align: right;' }, actionBtns)
				]));
			});
		}

		// 3. Import Button & Section
		var importBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-bottom: 16px;',
			'click': showImportModal
		}, [ _('+ Import .ovpn Profile') ]);

		function showImportModal() {
			var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Profile Name') });
			var fileInput = E('input', { 'type': 'file', 'accept': '.ovpn,.conf' });
			var pasteArea = E('textarea', { 'class': 'cbi-input-textarea', 'rows': '10', 'placeholder': _('Paste .ovpn content here...') });

			var modalContent = E('div', {}, [
				E('h4', {}, [ _('Import OpenVPN Profile') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Profile Name') ]),
					E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Upload File') ]),
					E('div', { 'class': 'cbi-value-field' }, [ fileInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Or Paste Config') ]),
					E('div', { 'class': 'cbi-value-field' }, [ pasteArea ])
				]),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px;' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							var name = nameInput.value.trim() || 'Imported Profile';
							if (fileInput.files.length > 0) {
								var reader = new FileReader();
								reader.onload = function(e) {
									processImport(name, e.target.result);
								};
								reader.readAsText(fileInput.files[0]);
							} else if (pasteArea.value.trim().length > 0) {
								processImport(name, pasteArea.value.trim());
							} else {
								ui.addNotification(null, E('p', {}, [ _('Please upload a file or paste config content.') ]), 'error');
							}
						}
					}, [ _('Import') ])
				])
			]);

			ui.showModal(_('Import Profile'), [ modalContent ]);
		}

		function processImport(name, content) {
			ui.showIndicator();
			api.importOvpn(name, content).then(function(res) {
				ui.hideIndicator();
				ui.hideModal();
				if (res && res.ok) {
					ui.addNotification(null, E('p', {}, [ _('Profile imported successfully: ') + res.id ]), 'info');
					location.reload();
				} else {
					ui.addNotification(null, E('p', {}, [ _('Import error: ') + (res.message || res.error) ]), 'error');
				}
			}).catch(function(err) {
				ui.hideIndicator();
				ui.addNotification(null, E('p', {}, [ _('Import failed: ') + err ]), 'error');
			});
		}

		function showCredentialsModal(profileId, profileName) {
			var userInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Username') });
			var passInput = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'placeholder': _('Password') });

			var modalContent = E('div', {}, [
				E('h4', {}, [ _('Credentials for ') + (profileName || profileId) ]),
				E('p', {}, [ _('Credentials are stored securely with 0600 root-only permissions.') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Username') ]),
					E('div', { 'class': 'cbi-value-field' }, [ userInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Password') ]),
					E('div', { 'class': 'cbi-value-field' }, [ passInput ])
				]),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px;' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							api.setCredentials(profileId, userInput.value, passInput.value).then(function() {
								ui.hideModal();
								ui.addNotification(null, E('p', {}, [ _('Credentials updated.') ]), 'info');
							});
						}
					}, [ _('Save') ])
				])
			]);

			ui.showModal(_('VPN Credentials'), [ modalContent ]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — OpenVPN Connections') ]),
			statusCard,
			E('div', { 'class': 'gv-card' }, [
				E('div', { 'class': 'gv-card-title' }, [
					E('span', {}, [ _('Configured Profiles') ]),
					importBtn
				]),
				profilesTable
			])
		]);
	}
});
