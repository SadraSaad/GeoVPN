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
			api.getDiag(),
			uci.load('luci').catch(function() { return null; })
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var statusData = (data && data[1]) || {};
		var diagData = (data && data[2]) || {};

		var mainCfg = uci.get('geovpn', 'main') || {};
		var dataCfg = uci.get('geovpn', 'data') || {};

		// ----------------------------------------------------
		// 1. Network Settings Card
		// ----------------------------------------------------
		var lanIfs = mainCfg.lan_ifs || ['br-lan'];
		if (Array.isArray(lanIfs)) lanIfs = lanIfs.join(' ');

		var lanIfsInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'value': lanIfs
		});

		var lanZones = mainCfg.lan_zones || ['lan'];
		if (Array.isArray(lanZones)) lanZones = lanZones.join(' ');

		var lanZonesInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'value': lanZones
		});

		var routerTrafficSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'dns', 'selected': (mainCfg.router_traffic === 'dns' || !mainCfg.router_traffic) ? 'selected' : null }, [ _('Only marked DNS queries') ]),
			E('option', { 'value': 'direct', 'selected': (mainCfg.router_traffic === 'direct') ? 'selected' : null }, [ _('Always direct WAN') ]),
			E('option', { 'value': 'vpn', 'selected': (mainCfg.router_traffic === 'vpn') ? 'selected' : null }, [ _('Route through VPN') ])
		]);

		var networkCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Network Settings') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('LAN Interfaces') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					lanIfsInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Space-separated list of inbound LAN interfaces subject to split-tunneling (default: br-lan).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('LAN Firewall Zones') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					lanZonesInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Space-separated list of firewall zones allowed forwarding into geovpn zone (default: lan).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Router Self-Generated Traffic') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					routerTrafficSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('How traffic originating directly from the router itself is handled.')
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 2. DNS Settings Card
		// ----------------------------------------------------
		var dnsModeSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'follow', 'selected': (mainCfg.dns_mode === 'follow' || !mainCfg.dns_mode) ? 'selected' : null }, [ _('Follow Route (Steer by category)') ]),
			E('option', { 'value': 'direct', 'selected': (mainCfg.dns_mode === 'direct') ? 'selected' : null }, [ _('Always Direct WAN DNS') ]),
			E('option', { 'value': 'vpn', 'selected': (mainCfg.dns_mode === 'vpn') ? 'selected' : null }, [ _('Always VPN DNS') ]),
			E('option', { 'value': 'off', 'selected': (mainCfg.dns_mode === 'off') ? 'selected' : null }, [ _('Disabled (Do not touch dnsmasq)') ])
		]);

		var directDns = mainCfg.dns_direct_servers || ['auto'];
		if (Array.isArray(directDns)) directDns = directDns.join(' ');
		var directDnsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': directDns });

		var vpnDns = mainCfg.dns_vpn_servers || ['1.1.1.1', '9.9.9.9'];
		if (Array.isArray(vpnDns)) vpnDns = vpnDns.join(' ');
		var vpnDnsInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': vpnDns });

		var dnsHijackCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.dns_hijack !== '0') ? 'checked' : null
		});

		var blockDotCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.block_dot !== '0') ? 'checked' : null
		});

		var blockDohCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.block_doh === '1') ? 'checked' : null
		});

		var dnsCanaryCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.dns_canary !== '0') ? 'checked' : null
		});

		var dynTimeoutInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width: 120px;',
			'value': mainCfg.dyn_timeout || '6h'
		});

		var dnsCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('DNS & Leak Protection') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('DNS Steering Mode') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					dnsModeSelect,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Directs domain queries to appropriate resolvers and populates nftables sets.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Direct DNS Servers') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					directDnsInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Space-separated IP addresses or "auto" for WAN DHCP servers.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('VPN DNS Servers') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					vpnDnsInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Space-separated IP addresses or "pushed" to use server-pushed resolvers.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Hijack DNS (Port 53)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						dnsHijackCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Intercept port 53 UDP/TCP and redirect to router dnsmasq') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Block DNS-over-TLS (DoT)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						blockDotCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Reject port 853 to prevent client bypass') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Block DNS-over-HTTPS (DoH)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						blockDohCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Reject connections to known public DoH resolvers') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('DoH Canary Signal') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						dnsCanaryCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Respond NXDOMAIN for use-application-dns.net (disables browser auto-DoH)') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Dynamic Set Timeout') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					dynTimeoutInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('How long dynamically resolved IP addresses remain in the nftables routing sets (default: 6h).')
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 3. Advanced Routing & System Limits
		// ----------------------------------------------------
		var markShiftInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width: 100px;',
			'min': '0',
			'max': '28',
			'value': mainCfg.mark_shift || '24'
		});

		var rtTableInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width: 120px;',
			'value': mainCfg.rt_table || '4200'
		});

		var rulePriorityInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width: 120px;',
			'value': mainCfg.rule_priority || '700'
		});

		var maxCidrsInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width: 140px;',
			'value': mainCfg.max_cidrs || '150000'
		});

		var maxDomainsInput = E('input', {
			'type': 'number',
			'class': 'cbi-input-text',
			'style': 'width: 140px;',
			'value': mainCfg.max_domains || '60000'
		});

		var allowLargeCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.allow_large === '1') ? 'checked' : null
		});

		var flushConntrackCheck = E('input', {
			'type': 'checkbox',
			'checked': (mainCfg.flush_conntrack === '1') ? 'checked' : null
		});

		var logLevelSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'info', 'selected': (mainCfg.log_level === 'info' || !mainCfg.log_level) ? 'selected' : null }, [ _('Info') ]),
			E('option', { 'value': 'warn', 'selected': (mainCfg.log_level === 'warn') ? 'selected' : null }, [ _('Warning') ]),
			E('option', { 'value': 'error', 'selected': (mainCfg.log_level === 'error') ? 'selected' : null }, [ _('Error') ]),
			E('option', { 'value': 'debug', 'selected': (mainCfg.log_level === 'debug') ? 'selected' : null }, [ _('Debug') ])
		]);

		var routingLimitsCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Advanced Routing & System Limits') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Firewall Mark Shift') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					markShiftInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Bit shift for packet and connmark (bits [shift..shift+3]). Shift 24 avoids mwan3 (bits 0..15).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Routing Table ID') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					rtTableInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Linux policy routing table used for VPN traffic (default: 4200).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('IP Rule Priority') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					rulePriorityInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('Priority for policy routing lookup rules (default: 700).')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Capacity Limits') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display: flex; gap: 16px; align-items: center;' }, [
						E('span', {}, [ _('Max CIDRs:') ]),
						maxCidrsInput,
						E('span', {}, [ _('Max Domains:') ]),
						maxDomainsInput
					]),
					E('div', { 'style': 'margin-top: 8px;' }, [
						E('label', { 'style': 'cursor: pointer;' }, [
							allowLargeCheck,
							E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Allow large data packs on devices with < 512MB RAM') ])
						])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Flush Conntrack') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						flushConntrackCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Flush connection tracking table on tunnel state changes') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Logging Level') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					logLevelSelect
				])
			])
		]);

		// ----------------------------------------------------
		// 4. Data Sources Card
		// ----------------------------------------------------
		var sourceUrlInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'value': dataCfg.source_url || 'https://geovpn.github.io/geovpn-data/v1/'
		});

		var verifySigCheck = E('input', {
			'type': 'checkbox',
			'checked': (dataCfg.verify !== '0') ? 'checked' : null
		});

		var packPubkeyInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'value': dataCfg.pack_pubkey || '/etc/geovpn/keys/pack.pub'
		});

		var keepPrevCheck = E('input', {
			'type': 'checkbox',
			'checked': (dataCfg.keep_prev !== '0') ? 'checked' : null
		});

		var dataSourceCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Data Sources & Verification') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Pack Repository URL') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					sourceUrlInput,
					E('div', { 'class': 'cbi-value-description' }, [
						_('HTTPS mirror hosting MANIFEST and catalog data.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Cryptographic Verification') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						verifySigCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Require valid usign signature on pack MANIFEST') ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Public Key File') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					packPubkeyInput
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Rollback Backup') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('label', { 'style': 'cursor: pointer;' }, [
						keepPrevCheck,
						E('span', { 'style': 'margin-inline-start: 8px;' }, [ _('Retain previous data pack for instant rollback if update fails') ])
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 5. Interface Language & Localization Card
		// ----------------------------------------------------
		var currentLang = (uci.get('luci', 'main', 'lang')) || 'auto';

		var langSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'auto', 'selected': (currentLang === 'auto') ? 'selected' : null }, [ _('Automatic (System)') ]),
			E('option', { 'value': 'en', 'selected': (currentLang === 'en') ? 'selected' : null }, [ 'English' ]),
			E('option', { 'value': 'fa', 'selected': (currentLang === 'fa') ? 'selected' : null }, [ 'فارسی (Persian)' ])
		]);

		var applyLangBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				var chosen = langSelect.value;
				ui.showIndicator();
				uci.set('luci', 'main', 'lang', chosen);
				uci.save();
				uci.apply().then(function() {
					ui.hideIndicator();
					if (chosen === 'fa') {
						document.documentElement.setAttribute('dir', 'rtl');
						document.documentElement.setAttribute('lang', 'fa');
					} else if (chosen === 'en') {
						document.documentElement.setAttribute('dir', 'ltr');
						document.documentElement.setAttribute('lang', 'en');
					}
					location.reload();
				}).catch(function(err) {
					ui.hideIndicator();
					ui.addNotification(null, E('p', {}, [ _('Failed to switch language: ') + err ]), 'error');
				});
			}
		}, [ _('Apply Language') ]);

		var langCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Interface Language') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Display Language') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display: flex; gap: 10px; align-items: center; max-width: 400px;' }, [
						langSelect,
						applyLangBtn
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						_('Choose interface display language. Page will reload and update layout direction (LTR / RTL).')
					])
				])
			])
		]);

		// ----------------------------------------------------
		// 6. Updates & Version Card
		// ----------------------------------------------------
		var currentVersion = '1.1.0';
		var repoUrl = 'https://github.com/SadraSaad/GeoVPN';

		var updateStatusBox = E('div', {
			'style': 'margin-top: 14px; padding: 12px 14px; border-radius: 6px; background: var(--cbi-input-background, rgba(127,127,127,0.06)); border: 1px solid var(--cbi-border-color, rgba(127,127,127,0.15)); font-size: 0.9rem;'
		}, [
			E('span', { 'style': 'opacity: 0.8;' }, [
				_('Click "Check for Updates" to query latest releases from GitHub.')
			])
		]);

		var checkUpdatesBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function() {
				dom.content(updateStatusBox, [
					E('span', { 'class': 'cbi-progressbar-spinner', 'style': 'margin-inline-end: 8px;' }),
					E('span', {}, [ _('Checking for updates from GitHub...') ])
				]);

				function handleReleaseData(data) {
					if (!data || !data.latest_version) {
						dom.content(updateStatusBox, [
							E('span', { 'style': 'color: #cf222e;' }, [
								_('Failed to check for updates: ') + ((data && data.message) || _('No release data found.'))
							])
						]);
						return;
					}

					var isNewer = data.update_available;
					var latestTag = data.latest_version;
					var changelog = data.changelog || '';
					var assets = data.assets || [];

					if (!isNewer) {
						dom.content(updateStatusBox, [
							E('div', { 'style': 'display: flex; align-items: center; gap: 8px; color: #2da44e;' }, [
								E('span', { 'style': 'font-weight: 700;' }, [ '✔' ]),
								E('span', {}, [ _('You are running the latest version (%s).').format(currentVersion) ])
							])
						]);
						return;
					}

					var updateNowBtn = E('button', {
						'class': 'cbi-button cbi-button-positive',
						'style': 'margin-top: 10px;',
						'click': function() {
							if (!confirm(_('Upgrade GeoVPN to %s now? Downloaded packages will be installed and services restarted.').format(latestTag))) {
								return;
							}

							ui.showIndicator();
							dom.content(updateStatusBox, [
								E('span', { 'class': 'cbi-progressbar-spinner', 'style': 'margin-inline-end: 8px;' }),
								E('span', {}, [ _('Downloading and installing packages from GitHub Releases...') ])
							]);

							api.applyUpdate(latestTag, assets).then(function(upRes) {
								ui.hideIndicator();
								if (upRes && upRes.ok) {
									dom.content(updateStatusBox, [
										E('div', { 'style': 'color: #2da44e; font-weight: 600;' }, [
											_('GeoVPN updated successfully! Reloading in 3 seconds...')
										])
									]);
									ui.addNotification(null, E('p', {}, [ _('GeoVPN updated successfully! Reloading...') ]), 'info');
									window.setTimeout(function() {
										location.reload();
									}, 3500);
								} else {
									dom.content(updateStatusBox, [
										E('div', { 'style': 'color: #cf222e;' }, [
											_('Update failed: ') + ((upRes && upRes.message) || _('Unknown error'))
										])
									]);
									ui.addNotification(null, E('p', {}, [ _('Update failed: ') + ((upRes && upRes.message) || '') ]), 'error');
								}
							}).catch(function(err) {
								ui.hideIndicator();
								dom.content(updateStatusBox, [
									E('div', { 'style': 'color: #cf222e;' }, [
										_('Update failed: ') + err
									])
								]);
								ui.addNotification(null, E('p', {}, [ _('Update failed: ') + err ]), 'error');
							});
						}
					}, [ _('Update Now') ]);

					var content = [
						E('div', { 'style': 'display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;' }, [
							E('span', { 'style': 'font-weight: 600; color: #1a7f37;' }, [
								_('Update Available: %s').format(latestTag)
							]),
							E('a', {
								'href': data.url || (repoUrl + '/releases/tag/' + latestTag),
								'target': '_blank',
								'class': 'cbi-button cbi-button-neutral',
								'style': 'font-size: 0.8rem; padding: 2px 8px;'
							}, [ _('View on GitHub') ])
						]),
						changelog ? E('div', {
							'style': 'margin: 8px 0; padding: 10px; background: rgba(0,0,0,0.1); border-radius: 4px; max-height: 180px; overflow-y: auto; font-family: monospace; font-size: 0.8rem; white-space: pre-wrap;'
						}, [ changelog ]) : E('span'),
						updateNowBtn
					];

					dom.content(updateStatusBox, content);
				}

				api.checkUpdate().then(function(res) {
					if (res && res.ok) {
						handleReleaseData(res);
					} else {
						fetch('https://api.github.com/repos/SadraSaad/GeoVPN/releases/latest', {
							headers: { 'Accept': 'application/vnd.github.v3+json' }
						}).then(function(resp) {
							if (!resp.ok) throw new Error('HTTP ' + resp.status);
							return resp.json();
						}).then(function(doc) {
							var tag = doc.tag_name || '';
							var cleanLatest = tag.replace(/^v/, '');
							var cleanCur = currentVersion.replace(/^v/, '');
							var lParts = cleanLatest.split('.').map(Number);
							var cParts = cleanCur.split('.').map(Number);
							var newer = false;
							for (var i = 0; i < 3; i++) {
								if ((lParts[i] || 0) > (cParts[i] || 0)) { newer = true; break; }
								if ((lParts[i] || 0) < (cParts[i] || 0)) { newer = false; break; }
							}
							var assets = (doc.assets || []).filter(function(a) { return /\.apk$/.test(a.name); }).map(function(a) {
								return { name: a.name, url: a.browser_download_url, size: a.size };
							});
							handleReleaseData({
								ok: true,
								latest_version: tag,
								update_available: newer,
								release_name: doc.name || tag,
								changelog: doc.body || '',
								url: doc.html_url,
								assets: assets
							});
						}).catch(function(fErr) {
							dom.content(updateStatusBox, [
								E('span', { 'style': 'color: #cf222e;' }, [
									_('Could not retrieve update information from GitHub: ') + fErr
								])
							]);
						});
					}
				}).catch(function(err) {
					dom.content(updateStatusBox, [
						E('span', { 'style': 'color: #cf222e;' }, [
							_('Update check error: ') + err
						])
					]);
				});
			}
		}, [ _('Check for Updates') ]);

		var updatesCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Updates & Version') ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Installed Version') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('span', {
						'class': 'gv-badge gv-badge-connected',
						'style': 'margin-inline-end: 10px;'
					}, [ currentVersion ]),
					E('span', { 'style': 'font-size: 0.85rem; opacity: 0.8;' }, [
						_('GeoVPN OpenWrt Package Suite')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('GitHub Repository') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('a', {
						'href': repoUrl,
						'target': '_blank',
						'style': 'font-weight: 600;'
					}, [ widgets.renderLtr('https://github.com/SadraSaad/GeoVPN') ]),
					E('div', { 'class': 'cbi-value-description' }, [
						_('Official open-source repository, release tags, and issue tracker.')
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Check Releases') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					checkUpdatesBtn,
					updateStatusBox
				])
			])
		]);

		// ----------------------------------------------------
		// 7. Maintenance & Diagnostic Export
		// ----------------------------------------------------
		var exportDiagBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
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
		}, [ _('Export Diagnostics Bundle (JSON)') ]);

		var purgeBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'click': function() {
				if (confirm(_('Purge downloaded data cache? Categories will be re-downloaded on next update.'))) {
					ui.showIndicator();
					api.startUpdate(true).then(function() {
						ui.hideIndicator();
						ui.addNotification(null, E('p', {}, [ _('Data cache refreshed.') ]), 'info');
					});
				}
			}
		}, [ _('Purge Data Cache') ]);

		var maintenanceCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('Maintenance & Diagnostics') ])
			]),
			E('p', { 'style': 'color: #57606a; margin-bottom: 12px;' }, [
				_('Export comprehensive diagnostic details with all credentials and private keys scrubbed for safe sharing, or purge data caches.')
			]),
			E('div', { 'class': 'gv-actions' }, [
				exportDiagBtn,
				purgeBtn
			])
		]);

		// ----------------------------------------------------
		// 8. About Card
		// ----------------------------------------------------
		var aboutCard = E('div', { 'class': 'gv-card' }, [
			E('div', { 'class': 'gv-card-title' }, [
				E('span', {}, [ _('About GeoVPN') ])
			]),
			E('div', { 'style': 'font-size: 0.95rem; line-height: 1.6;' }, [
				E('p', {}, [
					E('strong', {}, [ _('GeoVPN for OpenWrt 25.12') ]),
					_(' — Pure embedded OpenVPN client with geo-based split tunneling, policy routing, and zero resident daemon footprint.')
				]),
				E('p', { 'style': 'color: #57606a;' }, [
					_('License: Apache-2.0. Data packs: CC0-1.0 / MIT. No proprietary components.')
				])
			])
		]);

		// ----------------------------------------------------
		// 9. Save & Apply Bottom Bar
		// ----------------------------------------------------
		var saveApplyBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'padding: 8px 24px; font-weight: 600;',
			'click': function() {
				ui.showIndicator();

				// Save Language
				uci.set('luci', 'main', 'lang', langSelect.value);

				// Save Network
				var ifs = lanIfsInput.value.trim().split(/\s+/).filter(Boolean);
				uci.set('geovpn', 'main', 'lan_ifs', ifs);
				var zones = lanZonesInput.value.trim().split(/\s+/).filter(Boolean);
				uci.set('geovpn', 'main', 'lan_zones', zones);
				uci.set('geovpn', 'main', 'router_traffic', routerTrafficSelect.value);

				// Save DNS
				uci.set('geovpn', 'main', 'dns_mode', dnsModeSelect.value);
				var dDns = directDnsInput.value.trim().split(/\s+/).filter(Boolean);
				uci.set('geovpn', 'main', 'dns_direct_servers', dDns);
				var vDns = vpnDnsInput.value.trim().split(/\s+/).filter(Boolean);
				uci.set('geovpn', 'main', 'dns_vpn_servers', vDns);
				uci.set('geovpn', 'main', 'dns_hijack', dnsHijackCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'block_dot', blockDotCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'block_doh', blockDohCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'dns_canary', dnsCanaryCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'dyn_timeout', dynTimeoutInput.value.trim() || '6h');

				// Save Routing & Limits
				uci.set('geovpn', 'main', 'mark_shift', markShiftInput.value.trim() || '24');
				uci.set('geovpn', 'main', 'rt_table', rtTableInput.value.trim() || '4200');
				uci.set('geovpn', 'main', 'rule_priority', rulePriorityInput.value.trim() || '700');
				uci.set('geovpn', 'main', 'max_cidrs', maxCidrsInput.value.trim() || '150000');
				uci.set('geovpn', 'main', 'max_domains', maxDomainsInput.value.trim() || '60000');
				uci.set('geovpn', 'main', 'allow_large', allowLargeCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'flush_conntrack', flushConntrackCheck.checked ? '1' : '0');
				uci.set('geovpn', 'main', 'log_level', logLevelSelect.value);

				// Save Data
				uci.set('geovpn', 'data', 'source_url', sourceUrlInput.value.trim());
				uci.set('geovpn', 'data', 'verify', verifySigCheck.checked ? '1' : '0');
				uci.set('geovpn', 'data', 'pack_pubkey', packPubkeyInput.value.trim());
				uci.set('geovpn', 'data', 'keep_prev', keepPrevCheck.checked ? '1' : '0');

				uci.save();
				uci.apply().then(function() {
					api.callService('reload').then(function() {
						ui.hideIndicator();
						ui.addNotification(null, E('p', {}, [ _('Settings applied successfully.') ]), 'info');
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
			E('h2', {}, [ _('GeoVPN — Settings') ]),
			networkCard,
			dnsCard,
			routingLimitsCard,
			dataSourceCard,
			langCard,
			updatesCard,
			maintenanceCard,
			aboutCard,
			bottomBar
		]);
	}
});
