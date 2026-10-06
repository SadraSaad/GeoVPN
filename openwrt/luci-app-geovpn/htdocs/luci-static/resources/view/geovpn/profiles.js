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
		widgets.loadStylesheet();

		var statusData = data[1] || {};
		var activeProfileId = uci.get('geovpn', 'main', 'active_profile') || '';

		// 1. Status Card
		var statusCard = E('div', { 'class': 'cbi-section gv-card' }, [
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
		var profilesTable = E('table', { 'class': 'table cbi-section-table' }, [
			E('thead', {}, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, [ _('Name') ]),
					E('th', { 'class': 'th' }, [ _('Server Endpoint') ]),
					E('th', { 'class': 'th' }, [ _('Auth') ]),
					E('th', { 'class': 'th' }, [ _('Status') ]),
					E('th', { 'class': 'th', 'style': 'text-align: right;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		var tbody = profilesTable.querySelector('tbody');
		var profiles = uci.sections('geovpn', 'profile');

		if (profiles.length === 0) {
			dom.append(tbody, E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '5', 'style': 'text-align: center; padding: 24px; opacity: 0.7;' }, [
					_('No OpenVPN profiles configured. Import an .ovpn file to get started.')
				])
			]));
		} else {
			profiles.forEach(function(p, idx) {
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
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							showEditModal(p['.name'], p.name);
						}
					}, [ _('Edit') ]),
					E('span', { 'style': 'width: 4px;' }),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							showCredentialsModal(p['.name'], p.name);
						}
					}, [ _('Credentials') ]),
					E('span', { 'style': 'width: 4px;' }),
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

				dom.append(tbody, E('tr', { 'class': 'tr cbi-rowstyle-' + (idx % 2 + 1) }, [
					E('td', { 'class': 'td', 'style': 'font-weight: 600;' }, [ p.name || p['.name'] ]),
					E('td', { 'class': 'td' }, [ widgets.renderLtr(remotes[0] || '-') ]),
					E('td', { 'class': 'td' }, [ (p.auth_user_pass === '1') ? _('User/Pass') : _('Certificate') ]),
					E('td', { 'class': 'td' }, [ isActive ? E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('Active') ]) : E('span', { 'class': 'gv-badge gv-badge-disabled' }, [ _('Idle') ]) ]),
					E('td', { 'class': 'td', 'style': 'text-align: right;' }, actionBtns)
				]));
			});
		}

		// 3. Import Button & Section
		var importBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': showImportModal
		}, [ _('+ Import .ovpn Profile') ]);

		function showImportModal() {
			var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Profile Name') });
			var fileInput = E('input', { 'type': 'file', 'accept': '.ovpn,.conf' });
			var pasteArea = E('textarea', { 'class': 'gv-editor-textarea', 'rows': '10', 'placeholder': _('Paste .ovpn content here...') });

			var modalContent = E('div', {}, [
				E('h4', { 'style': 'margin-bottom: 12px;' }, [ _('Import OpenVPN Profile') ]),
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

		// Edit Profile Modal (Raw OVPN and auth credentials, matching luci-app-openvpn)
		function showEditModal(profileId, profileName) {
			ui.showIndicator();
			api.getProfile(profileId).then(function(res) {
				ui.hideIndicator();
				var ovpnText = (res && res.ovpn) ? res.ovpn : '';
				var authText = (res && res.auth) ? res.auth : '';

				var nameInput = E('input', {
					'type': 'text',
					'class': 'cbi-input-text',
					'value': profileName || (res && res.name) || profileId,
					'style': 'width: 100%; margin-bottom: 12px;'
				});

				var ovpnArea = E('textarea', {
					'class': 'gv-editor-textarea',
					'rows': '12',
					'placeholder': '# Enter OpenVPN configuration directives...'
				}, [ ovpnText ]);

				var authArea = E('textarea', {
					'class': 'gv-editor-textarea',
					'rows': '4',
					'placeholder': 'username\npassword'
				}, [ authText ]);

				var modalContent = E('div', {}, [
					E('h4', { 'style': 'margin-bottom: 6px;' }, [
						_('Overview » Instance "%s"').format(profileName || profileId)
					]),
					E('p', { 'style': 'font-size: 0.85rem; opacity: 0.8; margin-bottom: 14px;' }, [
						_('Edit the raw OpenVPN profile and credentials below.')
					]),

					E('div', { 'class': 'cbi-value', 'style': 'margin-bottom: 12px;' }, [
						E('label', { 'class': 'cbi-value-title', 'style': 'font-weight: 600;' }, [ _('Profile Name') ]),
						E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
					]),

					E('div', { 'style': 'margin-bottom: 16px;' }, [
						E('label', { 'style': 'font-weight: 600; display: block; margin-bottom: 4px;' }, [
							_('Section to modify the OVPN config file (/etc/geovpn/profiles/%s/profile.ovpn)').format(profileId)
						]),
						ovpnArea
					]),

					E('div', { 'style': 'margin-bottom: 16px;' }, [
						E('label', { 'style': 'font-weight: 600; display: block; margin-bottom: 4px;' }, [
							_('Section to add an optional \'auth-user-pass\' file with your credentials (/etc/geovpn/profiles/%s/auth)').format(profileId)
						]),
						E('div', { 'style': 'font-size: 0.8rem; opacity: 0.75; margin-bottom: 4px;' }, [
							_('Line 1: Username, Line 2: Password (saved securely as 0600 root-only)')
						]),
						authArea
					]),

					E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
						E('button', {
							'class': 'cbi-button',
							'click': ui.hideModal
						}, [ _('Cancel') ]),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function() {
								ui.showIndicator();
								api.saveProfileRaw(profileId, nameInput.value.trim(), ovpnArea.value, authArea.value).then(function(sRes) {
									ui.hideIndicator();
									ui.hideModal();
									if (sRes && sRes.ok) {
										ui.addNotification(null, E('p', {}, [ _('Profile updated successfully.') ]), 'info');
										location.reload();
									} else {
										ui.addNotification(null, E('p', {}, [ _('Error saving profile: ') + (sRes.message || 'Unknown error') ]), 'error');
									}
								}).catch(function(err) {
									ui.hideIndicator();
									ui.addNotification(null, E('p', {}, [ _('Save failed: ') + err ]), 'error');
								});
							}
						}, [ _('Save') ])
					])
				]);

				ui.showModal(_('Edit Profile'), [ modalContent ]);
			}).catch(function(err) {
				ui.hideIndicator();
				ui.addNotification(null, E('p', {}, [ _('Failed to load profile: ') + err ]), 'error');
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
			E('div', { 'class': 'cbi-section gv-card' }, [
				E('div', { 'class': 'gv-card-title' }, [
					E('span', {}, [ _('Configured Profiles') ]),
					importBtn
				]),
				profilesTable
			])
		]);
	}
});
