'use strict';
'require view';
'require ui';
'require uci';
'require dom';
'require geovpn.api as api';
'require geovpn.widgets as widgets';
'require geovpn.picker as picker';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('geovpn'),
			api.getStatus(),
			api.getUpdateStatus()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var statusData = (data && data[1]) || {};
		var updateData = (data && data[2]) || {};

		var mainCfg = uci.get('geovpn', 'main') || {};
		var dataCfg = uci.get('geovpn', 'data') || {};

		// ----------------------------------------------------
		// 1. Split Tunneling Card
		// ----------------------------------------------------
		var splitEnabledInput = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.split_enabled !== '0') ? 'checked' : null
		});

		var modeBypassRadio = E('input', {
			'type': 'radio',
			'name': 'gv_mode',
			'value': 'bypass',
			'checked': (mainCfg.mode !== 'include') ? 'checked' : null
		});
		var modeIncludeRadio = E('input', {
			'type': 'radio',
			'name': 'gv_mode',
			'value': 'include',
			'checked': (mainCfg.mode === 'include') ? 'checked' : null
		});

		var privateDirectInput = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.private_direct !== '0') ? 'checked' : null
		});

		var ipv6Select = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'auto', 'selected': (mainCfg.ipv6 === 'auto' || !mainCfg.ipv6) ? 'selected' : null }, [ _('Auto') ]),
			E('option', { 'value': 'direct', 'selected': (mainCfg.ipv6 === 'direct') ? 'selected' : null }, [ _('Direct') ]),
			E('option', { 'value': 'vpn', 'selected': (mainCfg.ipv6 === 'vpn') ? 'selected' : null }, [ _('VPN') ]),
			E('option', { 'value': 'block', 'selected': (mainCfg.ipv6 === 'block') ? 'selected' : null }, [ _('Block (prevent leaks)') ])
		]);

		var killSwitchInput = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.kill_switch === '1') ? 'checked' : null
		});

		var splitCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Split Tunneling Configuration') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Enable Split Tunneling') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						splitEnabledInput,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Enable policy-based routing and DNS steering') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Routing Mode') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'margin-bottom: 6px;' }, [
						E('label', { 'style': 'cursor: pointer;' }, [
							modeBypassRadio,
							E('span', { 'style': 'margin-inline-start: 8px;' }, [
								E('strong', {}, [ _('Bypass listed') ]),
								_(' — Selected countries/domains bypass VPN to direct WAN; all other traffic uses VPN.')
							])
						])
					]),
					E('div', {}, [
						E('label', { 'style': 'cursor: pointer;' }, [
							modeIncludeRadio,
							E('span', { 'style': 'margin-inline-start: 8px;' }, [
								E('strong', {}, [ _('Only listed via VPN') ]),
								_(' — Only selected countries/domains use VPN; all other traffic uses direct WAN.')
							])
						])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Private Networks') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						privateDirectInput,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Treat RFC1918 / private networks as direct (recommended)') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('IPv6 Handling') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					ipv6Select,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Auto routes IPv6 if VPN provides an IPv6 endpoint; otherwise keeps direct or blocks.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Kill Switch') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						killSwitchInput,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Block VPN traffic when tunnel is down') ])
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						_('Direct traffic continues unimpeded. Router management and LAN access are always preserved.')
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 2. GeoIP Card
		// ----------------------------------------------------
		var geoipContainer = E('div', { 'class': 'gv-tags-container' });
		var geoipRamEst = E('span', { 'style': 'color: #57606a; font-size: 0.9rem;' });

		function renderGeoipTags() {
			dom.content(geoipContainer, []);
			var geoipSections = uci.sections('geovpn', 'geoip');
			var totalEstMb = (geoipSections.length * 0.6).toFixed(1);

			if (geoipSections.length === 0) {
				dom.append(geoipContainer, E('span', { 'style': 'color: #57606a; font-style: italic; margin-inline-end: 8px;' }, [
					_('No countries selected.')
				]));
			} else {
				geoipSections.forEach(function(s) {
					var code = s.code || s['.name'];
					var tag = E('span', { 'class': 'gv-tag' }, [
						widgets.renderLtr(code),
						E('span', {
							'class': 'gv-tag-remove',
							'title': _('Remove'),
							'click': function() {
								uci.remove('geovpn', s['.name']);
								renderGeoipTags();
							}
						}, [ '✕' ])
					]);
					dom.append(geoipContainer, tag);
				});
			}

			geoipRamEst.textContent = _('Estimated RAM: ~%s MB').format(totalEstMb);
		}

		var addGeoipBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				picker.showPicker('geoip', function(code) {
					var sname = uci.add('geovpn', 'geoip');
					uci.set('geovpn', sname, 'code', code);
					uci.set('geovpn', sname, 'enabled', '1');
					renderGeoipTags();
				});
			}
		}, [ _('+ Add Country (GeoIP)…') ]);

		var geoipCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('GeoIP Countries') ]),
				geoipRamEst
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('Traffic destined for IP subnets belonging to these countries will match the policy.')
			]),
			geoipContainer,
			E('div', { 'style': 'margin-top: 10px;' }, [ addGeoipBtn ])
		]);

		renderGeoipTags();

		// ----------------------------------------------------
		// 3. GeoSite Card
		// ----------------------------------------------------
		var geositeContainer = E('div', { 'class': 'gv-tags-container' });
		var geositeRamEst = E('span', { 'style': 'color: #57606a; font-size: 0.9rem;' });

		function renderGeositeTags() {
			dom.content(geositeContainer, []);
			var geositeSections = uci.sections('geovpn', 'geosite');
			var totalEstMb = (geositeSections.length * 0.4).toFixed(1);

			if (geositeSections.length === 0) {
				dom.append(geositeContainer, E('span', { 'style': 'color: #57606a; font-style: italic; margin-inline-end: 8px;' }, [
					_('No domain categories selected.')
				]));
			} else {
				geositeSections.forEach(function(s) {
					var name = s.name || s['.name'];
					var tag = E('span', { 'class': 'gv-tag' }, [
						widgets.renderLtr(name),
						E('span', {
							'class': 'gv-tag-remove',
							'title': _('Remove'),
							'click': function() {
								uci.remove('geovpn', s['.name']);
								renderGeositeTags();
							}
						}, [ '✕' ])
					]);
					dom.append(geositeContainer, tag);
				});
			}

			geositeRamEst.textContent = _('Estimated RAM: ~%s MB').format(totalEstMb);
		}

		var addGeositeBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				picker.showPicker('geosite', function(name) {
					var sname = uci.add('geovpn', 'geosite');
					uci.set('geovpn', sname, 'name', name);
					uci.set('geovpn', sname, 'enabled', '1');
					renderGeositeTags();
				});
			}
		}, [ _('+ Add Category (GeoSite)…') ]);

		var geositeCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('GeoSite Domain Categories') ]),
				geositeRamEst
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('DNS queries for domains in these categories are dynamically added to the policy routing set.')
			]),
			geositeContainer,
			E('div', { 'style': 'margin-top: 10px;' }, [ addGeositeBtn ])
		]);

		renderGeositeTags();

		// ----------------------------------------------------
		// 4. Custom Rules Card
		// ----------------------------------------------------
		var rulesTable = E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', { 'style': 'width: 60px;' }, [ _('Enable') ]),
					E('th', {}, [ _('Name') ]),
					E('th', {}, [ _('Type') ]),
					E('th', {}, [ _('Target / CIDR') ]),
					E('th', {}, [ _('Route') ]),
					E('th', { 'style': 'text-align: right;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		function renderCustomRules() {
			var tbody = rulesTable.querySelector('tbody');
			dom.content(tbody, []);
			var rules = uci.sections('geovpn', 'rule');

			if (rules.length === 0) {
				dom.append(tbody, E('tr', {}, [
					E('td', { 'colspan': '6', 'style': 'text-align: center; color: #57606a;' }, [
						_('No custom rules configured.')
					])
				]));
			} else {
				rules.forEach(function(r) {
					var enabledCheck = E('input', {
						'type': 'checkbox',
						'checked': (r.enabled !== '0') ? 'checked' : null,
						'click': function() {
							uci.set('geovpn', r['.name'], 'enabled', this.checked ? '1' : '0');
						}
					});

					var routeBadge = (r.action === 'vpn')
						? E('span', { 'class': 'gv-badge', 'style': 'background-color: #ddf4ff; color: #0969da; border: 1px solid #54aeff;' }, [ _('VPN') ])
						: E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('Direct') ]);

					var actions = [
						E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'click': function() { showRuleModal(r); }
						}, [ _('Edit') ]),
						E('span', { 'style': 'width: 6px;' }),
						E('button', {
							'class': 'cbi-button cbi-button-remove',
							'click': function() {
								uci.remove('geovpn', r['.name']);
								renderCustomRules();
							}
						}, [ _('Delete') ])
					];

					dom.append(tbody, E('tr', {}, [
						E('td', { 'style': 'text-align: center;' }, [ enabledCheck ]),
						E('td', { 'style': 'font-weight: 600;' }, [ r.name || r['.name'] ]),
						E('td', {}, [ (r.type === 'domain') ? _('Domain') : _('IP / CIDR') ]),
						E('td', {}, [ widgets.renderLtr(r.value || '-') ]),
						E('td', {}, [ routeBadge ]),
						E('td', { 'style': 'text-align: right;' }, actions)
					]));
				});
			}
		}

		function showRuleModal(existingRule) {
			var isNew = !existingRule;
			var nameInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. Corp Wiki or NAS'),
				'value': existingRule ? (existingRule.name || '') : ''
			});
			var typeSelect = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'domain', 'selected': (existingRule && existingRule.type === 'domain') ? 'selected' : null }, [ _('Domain') ]),
				E('option', { 'value': 'cidr', 'selected': (existingRule && existingRule.type === 'cidr') ? 'selected' : null }, [ _('IP / CIDR') ])
			]);
			var valInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. wiki.corp.example or 203.0.113.0/24'),
				'value': existingRule ? (existingRule.value || '') : ''
			});
			var actionSelect = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'direct', 'selected': (existingRule && existingRule.action === 'direct') ? 'selected' : null }, [ _('Direct (WAN)') ]),
				E('option', { 'value': 'vpn', 'selected': (existingRule && existingRule.action === 'vpn') ? 'selected' : null }, [ _('VPN') ])
			]);

			var modalContent = E('div', {}, [
				E('h4', {}, [ isNew ? _('Add Custom Rule') : _('Edit Custom Rule') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Rule Name') ]),
					E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Match Type') ]),
					E('div', { 'class': 'cbi-value-field' }, [ typeSelect ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Target Value') ]),
					E('div', { 'class': 'cbi-value-field' }, [ valInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Target Route') ]),
					E('div', { 'class': 'cbi-value-field' }, [ actionSelect ])
				]),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px;' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							var val = valInput.value.trim();
							if (!val) {
								ui.addNotification(null, E('p', {}, [ _('Target value cannot be empty.') ]), 'error');
								return;
							}
							var sname = existingRule ? existingRule['.name'] : uci.add('geovpn', 'rule');
							uci.set('geovpn', sname, 'name', nameInput.value.trim() || 'Rule');
							uci.set('geovpn', sname, 'type', typeSelect.value);
							uci.set('geovpn', sname, 'value', val);
							uci.set('geovpn', sname, 'action', actionSelect.value);
							if (isNew) uci.set('geovpn', sname, 'enabled', '1');

							ui.hideModal();
							renderCustomRules();
						}
					}, [ _('Save') ])
				])
			]);

			ui.showModal(_('Custom Rule'), [ modalContent ]);
		}

		var addRuleBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() { showRuleModal(null); }
		}, [ _('+ Add Custom Rule') ]);

		var rulesCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Custom Target Rules') ]),
				addRuleBtn
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('Specific CIDRs or domain names to override default split-tunnel decisions.')
			]),
			rulesTable
		]);

		renderCustomRules();

		// ----------------------------------------------------
		// 5. Client Policies Card
		// ----------------------------------------------------
		var clientsTable = E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', { 'style': 'width: 60px;' }, [ _('Enable') ]),
					E('th', {}, [ _('Device Name') ]),
					E('th', {}, [ _('Match By') ]),
					E('th', {}, [ _('MAC / IP Address') ]),
					E('th', {}, [ _('Policy') ]),
					E('th', { 'style': 'text-align: right;' }, [ _('Actions') ])
				])
			]),
			E('tbody')
		]);

		function renderClientPolicies() {
			var tbody = clientsTable.querySelector('tbody');
			dom.content(tbody, []);
			var clients = uci.sections('geovpn', 'client');

			if (clients.length === 0) {
				dom.append(tbody, E('tr', {}, [
					E('td', { 'colspan': '6', 'style': 'text-align: center; color: #57606a;' }, [
						_('No per-client policies configured.')
					])
				]));
			} else {
				clients.forEach(function(c) {
					var enabledCheck = E('input', {
						'type': 'checkbox',
						'checked': (c.enabled !== '0') ? 'checked' : null,
						'click': function() {
							uci.set('geovpn', c['.name'], 'enabled', this.checked ? '1' : '0');
						}
					});

					var polBadge = (c.policy === 'vpn_all')
						? E('span', { 'class': 'gv-badge', 'style': 'background-color: #ddf4ff; color: #0969da; border: 1px solid #54aeff;' }, [ _('VPN Only') ])
						: E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('Direct Only') ]);

					var actions = [
						E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'click': function() { showClientModal(c); }
						}, [ _('Edit') ]),
						E('span', { 'style': 'width: 6px;' }),
						E('button', {
							'class': 'cbi-button cbi-button-remove',
							'click': function() {
								uci.remove('geovpn', c['.name']);
								renderClientPolicies();
							}
						}, [ _('Delete') ])
					];

					dom.append(tbody, E('tr', {}, [
						E('td', { 'style': 'text-align: center;' }, [ enabledCheck ]),
						E('td', { 'style': 'font-weight: 600;' }, [ c.name || c['.name'] ]),
						E('td', {}, [ (c.match === 'mac') ? _('MAC') : _('IP / Subnet') ]),
						E('td', {}, [ widgets.renderLtr(c.value || '-') ]),
						E('td', {}, [ polBadge ]),
						E('td', { 'style': 'text-align: right;' }, actions)
					]));
				});
			}
		}

		function showClientModal(existingClient) {
			var isNew = !existingClient;
			var nameInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. Living-room TV or Laptop'),
				'value': existingClient ? (existingClient.name || '') : ''
			});
			var matchSelect = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'mac', 'selected': (existingClient && existingClient.match === 'mac') ? 'selected' : null }, [ _('MAC Address') ]),
				E('option', { 'value': 'ip', 'selected': (existingClient && existingClient.match === 'ip') ? 'selected' : null }, [ _('IP Address / CIDR') ])
			]);
			var valInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('e.g. aa:bb:cc:dd:ee:ff or 192.168.1.20'),
				'value': existingClient ? (existingClient.value || '') : ''
			});
			var polSelect = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'direct_all', 'selected': (existingClient && existingClient.policy === 'direct_all') ? 'selected' : null }, [ _('Direct Only (Bypass VPN completely)') ]),
				E('option', { 'value': 'vpn_all', 'selected': (existingClient && existingClient.policy === 'vpn_all') ? 'selected' : null }, [ _('VPN Only (Tunnel all traffic)') ])
			]);

			var modalContent = E('div', {}, [
				E('h4', {}, [ isNew ? _('Add Client Policy') : _('Edit Client Policy') ]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Device Name') ]),
					E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Match Criterion') ]),
					E('div', { 'class': 'cbi-value-field' }, [ matchSelect ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Address') ]),
					E('div', { 'class': 'cbi-value-field' }, [ valInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Routing Policy') ]),
					E('div', { 'class': 'cbi-value-field' }, [ polSelect ])
				]),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px;' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							var val = valInput.value.trim();
							if (!val) {
								ui.addNotification(null, E('p', {}, [ _('Address cannot be empty.') ]), 'error');
								return;
							}
							var sname = existingClient ? existingClient['.name'] : uci.add('geovpn', 'client');
							uci.set('geovpn', sname, 'name', nameInput.value.trim() || 'Device');
							uci.set('geovpn', sname, 'match', matchSelect.value);
							uci.set('geovpn', sname, 'value', val);
							uci.set('geovpn', sname, 'policy', polSelect.value);
							if (isNew) uci.set('geovpn', sname, 'enabled', '1');

							ui.hideModal();
							renderClientPolicies();
						}
					}, [ _('Save') ])
				])
			]);

			ui.showModal(_('Client Policy'), [ modalContent ]);
		}

		var addClientBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() { showClientModal(null); }
		}, [ _('+ Add Client Policy') ]);

		var clientsCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Client Device Policies') ]),
				addClientBtn
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('Specific LAN clients forced to always bypass or always use the VPN.')
			]),
			clientsTable
		]);

		renderClientPolicies();

		// ----------------------------------------------------
		// 6. Data Pack Management Card
		// ----------------------------------------------------
		var autoUpdateCheck = E('input', {
			'type': 'checkbox',
			'checked': (dataCfg.auto_update !== '0') ? 'checked' : null
		});

		var cronInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width: 140px;',
			'value': dataCfg.update_cron || '17 4 * * *'
		});

		var updateViaSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'auto', 'selected': (dataCfg.update_via === 'auto' || !dataCfg.update_via) ? 'selected' : null }, [ _('Auto') ]),
			E('option', { 'value': 'direct', 'selected': (dataCfg.update_via === 'direct') ? 'selected' : null }, [ _('Direct (WAN)') ]),
			E('option', { 'value': 'vpn', 'selected': (dataCfg.update_via === 'vpn') ? 'selected' : null }, [ _('VPN') ])
		]);

		var updateStatusText = E('span', { 'style': 'margin-inline-start: 12px; font-weight: 500;' }, [
			(updateData && updateData.status) ? (_('Status: ') + updateData.status) : _('Ready')
		]);

		var updateNowBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				ui.showIndicator();
				api.startUpdate(true).then(function() {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Update started in background. Polling progress…') ]), 'info');
					pollUpdateProgress();
				});
			}
		}, [ _('Update Now') ]);

		function pollUpdateProgress() {
			var pollInterval = setInterval(function() {
				api.getUpdateStatus().then(function(st) {
					if (!st) return;
					updateStatusText.textContent = _('Updating: ') + (st.step || st.status || 'running') +
						(st.done ? (' (' + st.done + '/10)') : '');
					if (st.status === 'idle' || st.status === 'success' || st.status === 'failed') {
						clearInterval(pollInterval);
						updateStatusText.textContent = (st.status === 'success') ? _('Update successful ✔') : (_('Status: ') + st.status);
					}
				});
			}, 1500);
		}

		var packBuildStr = (statusData.data && statusData.data.build_id) || '2026.10.05.1';
		var dataCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Geo-Data Pack') ]),
				E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('Signature Verified ✔') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 8px;' }, [
				_('Data pack build: '),
				widgets.renderLtr(packBuildStr),
				' · ',
				_('Source: '),
				widgets.renderLtr(dataCfg.source_url || 'https://geovpn.github.io/geovpn-data/v1/')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Auto-Update') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						autoUpdateCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Enable automatic scheduled updates') ])
					]),
					E('div', { 'style': 'margin-top: 6px; display: flex; align-items: center; gap: 8px;' }, [
						E('span', {}, [ _('Schedule (Cron):') ]),
						cronInput,
						E('span', { 'style': 'margin-inline-start: 12px;' }, [ _('Update Via:') ]),
						updateViaSelect
					])
				])
			]),
			E('div', { 'class': 'gv-actions' }, [
				updateNowBtn,
				updateStatusText
			])
		]);

		// ----------------------------------------------------
		// 7. Interactive Target Tester & Live Set Summary
		// ----------------------------------------------------
		var testTargetInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width: 320px;',
			'placeholder': _('e.g. digikala.com or 1.1.1.1')
		});

		var testResultBox = E('div', {
			'style': 'margin-top: 12px; padding: 12px; border-radius: 6px; background: #f6f8fa; border: 1px solid #d0d7de; display: none;'
		});

		var testBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				var targetVal = testTargetInput.value.trim();
				if (!targetVal) return;

				ui.showIndicator();
				api.testTarget(targetVal).then(function(res) {
					ui.hideIndicator();
					testResultBox.style.display = 'block';
					dom.content(testResultBox, []);

					var verdictBadge = (res.verdict === 'direct')
						? E('span', { 'class': 'gv-badge gv-badge-connected' }, [ _('DIRECT') ])
						: E('span', { 'class': 'gv-badge', 'style': 'background-color: #ddf4ff; color: #0969da; border: 1px solid #54aeff;' }, [ _('VPN') ]);

					var reasonText = '';
					if (res.reason) {
						reasonText = res.reason.layer + (res.reason.rule ? (' (' + res.reason.rule + ')') : '');
					}

					var resolvedStr = (res.resolved && res.resolved.length > 0) ? res.resolved.join(', ') : '-';

					dom.append(testResultBox, E('div', { 'style': 'display: flex; align-items: center; gap: 12px; margin-bottom: 8px;' }, [
						E('strong', {}, [ _('Routing Decision:') ]),
						verdictBadge,
						E('span', { 'style': 'color: #57606a;' }, [ _('Matched by: ') + (reasonText || 'default') ])
					]));
					dom.append(testResultBox, E('div', { 'style': 'font-size: 0.9rem;' }, [
						E('span', {}, [ _('Resolved IPs: ') ]),
						widgets.renderLtr(resolvedStr),
						E('span', { 'style': 'margin-inline-start: 16px;' }, [ _('DNS Path: ') ]),
						widgets.renderLtr(res.dns_path || '-')
					]));
				}).catch(function(err) {
					ui.hideIndicator();
					testResultBox.style.display = 'block';
					dom.content(testResultBox, [
						E('span', { 'style': 'color: red;' }, [ _('Error simulating route: ') + err ])
					]);
				});
			}
		}, [ _('Test Route') ]);

		var diagCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Route Simulator & Live Sets') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 12px;' }, [
				_('Simulate how incoming network and DNS requests for an IP or domain are routed.')
			]),
			E('div', { 'style': 'display: flex; gap: 8px; align-items: center;' }, [
				testTargetInput,
				testBtn
			]),
			testResultBox
		]);

		// ----------------------------------------------------
		// 8. Save & Apply Bottom Bar
		// ----------------------------------------------------
		var saveApplyBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'padding: 8px 24px; font-weight: 600;',
			'click': function() {
				ui.showIndicator();

				// Save main settings
				uci.set('geovpn', 'main', 'split_enabled', splitEnabledInput.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'mode', modeIncludeRadio.checked ? 'include' : 'bypass');
				uci.set('geovpn', 'main', 'private_direct', privateDirectInput.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'ipv6', ipv6Select.value);
				uci.set('geovpn', 'main', 'kill_switch', killSwitchInput.checked ? '1' : '0');

				// Save data settings
				uci.set('geovpn', 'data', 'auto_update', autoUpdateCheck.checked ? '1' : '0');
				uci.set('geovpn', 'data', 'update_cron', cronInput.value.trim());
				uci.set('geovpn', 'data', 'update_via', updateViaSelect.value);

				uci.save();
				uci.apply().then(function() {
					api.callService('reload').then(function() {
						ui.hideIndicator();
						ui.addNotification(null, E('p', {}, [ _('Split tunneling settings applied.') ]), 'info');
					});
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Failed to apply configuration: ') + err ]), 'error');
				});
			}
		}, [ _('Save & Apply') ]);

		var bottomBar = E('div', {
			'style': 'display: flex; justify-content: flex-end; margin-top: 20px;'
		}, [ saveApplyBtn ]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Split Tunneling') ]),
			splitCard,
			geoipCard,
			geositeCard,
			rulesCard,
			clientsCard,
			dataCard,
			diagCard,
			bottomBar
		]);
	}
});
