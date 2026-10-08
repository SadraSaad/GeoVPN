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
			api.listCredentials()
		]);
	},

	render: function(data) {
		widgets.loadStylesheet();

		var credItems = (data && data[1] && data[1].items) || [];
		var queue = []; // Array of { file, filename, content, name, proto, size, sizeKb, valid, error }

		// 1. Honest Limitation Banner
		var limitationBanner = E('div', {
			'class': 'gv-banner-warn',
			'style': 'margin-bottom: 20px; font-size: 0.9rem; line-height: 1.5;'
		}, [
			E('strong', { 'style': 'display: block; margin-bottom: 4px;' }, [
				_('Windscribe Protocol Support Notice')
			]),
			E('span', {}, [
				_('Standard OpenVPN (UDP/TCP) and WireGuard configurations are fully supported with high performance. Please note that Windscribe "Stealth" (TLS encapsulation over TCP 443 via Stunnel) and "WStunnel" (WebSocket encapsulation) require proprietary wrapper binaries not included in standard OpenWrt.')
			])
		]);

		// 2. Preset & Deduplication Settings Card
		var presetSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'generic', 'selected': 'selected' }, [ _('Generic (Standard OpenVPN & WireGuard)') ]),
			E('option', { 'value': 'windscribe' }, [ _('Windscribe (Automatic DNS 10.255.255.3 & port tuning)') ])
		]);

		var dedupeSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'skip', 'selected': 'selected' }, [ _('Skip duplicates (preserve existing profile)') ]),
			E('option', { 'value': 'overwrite' }, [ _('Overwrite duplicates (update endpoints and keys)') ]),
			E('option', { 'value': 'keep_both' }, [ _('Keep both (rename duplicates with numbered suffix)') ])
		]);

		// Shared Credential Select
		var credOptions = [ E('option', { 'value': '' }, [ _('None / Inline credentials') ]) ];
		credItems.forEach(function(c) {
			var desc = c.id + (c.has_auth ? ' [User/Pass]' : '') + (c.has_wg_key ? ' [WG Key]' : '');
			credOptions.push(E('option', { 'value': c.id }, [ desc ]));
		});
		var credSelect = E('select', { 'class': 'cbi-input-select' }, credOptions);

		var newCredBtn = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': showNewCredentialModal
		}, [ _('+ New Credential Set') ]);

		var configCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 14px; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				_('Import Settings & Credentials')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Import Preset') ]),
				E('div', { 'class': 'cbi-value-field' }, [ presetSelect ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Deduplication Policy') ]),
				E('div', { 'class': 'cbi-value-field' }, [ dedupeSelect ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Shared Credential Set') ]),
				E('div', { 'class': 'cbi-value-field', 'style': 'display: flex; gap: 8px; align-items: center;' }, [
					credSelect,
					newCredBtn
				])
			])
		]);

		function showNewCredentialModal() {
			var idInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': 'e.g. windscribe_vpn'
			});
			var userInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'placeholder': _('Username (for OpenVPN)')
			});
			var passInput = E('input', {
				'type': 'password',
				'class': 'cbi-input-text',
				'placeholder': _('Password (for OpenVPN)'),
				'autocomplete': 'new-password'
			});
			var wgKeyInput = E('input', {
				'type': 'password',
				'class': 'cbi-input-text',
				'placeholder': _('WireGuard Private Key (optional)'),
				'autocomplete': 'new-password'
			});
			var wgPskInput = E('input', {
				'type': 'password',
				'class': 'cbi-input-text',
				'placeholder': _('WireGuard Pre-shared Key (optional)'),
				'autocomplete': 'new-password'
			});

			var modalContent = E('div', {}, [
				E('h4', { 'style': 'margin-bottom: 10px;' }, [ _('Create Shared Credential Set') ]),
				E('p', { 'style': 'font-size: 0.85rem; opacity: 0.8; margin-bottom: 14px;' }, [
					_('Credentials are saved securely as root-only 0600 secret files under /etc/geovpn/credentials/. Multiple profiles can reference the same credential set.')
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Credential Set ID') ]),
					E('div', { 'class': 'cbi-value-field' }, [ idInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Username') ]),
					E('div', { 'class': 'cbi-value-field' }, [ userInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Password') ]),
					E('div', { 'class': 'cbi-value-field' }, [ passInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('WG Private Key') ]),
					E('div', { 'class': 'cbi-value-field' }, [ wgKeyInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('WG Pre-shared Key') ]),
					E('div', { 'class': 'cbi-value-field' }, [ wgPskInput ])
				]),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function() {
							var cid = idInput.value.trim().toLowerCase().replace(/[^a-z0-9_-]/g, '_');
							if (!cid) {
								ui.addNotification(null, E('p', {}, [ _('Please specify a credential set ID.') ]), 'warning');
								return;
							}
							ui.showIndicator();
							api.saveCredential(
								cid,
								userInput.value.trim(),
								passInput.value,
								wgKeyInput.value.trim(),
								wgPskInput.value.trim()
							).then(function(sRes) {
								ui.hideIndicator();
								ui.hideModal();
								if (sRes && sRes.ok) {
									ui.addNotification(null, E('p', {}, [ _('Credential set created: ') + cid ]), 'info');
									// Add to dropdown
									var newOpt = E('option', { 'value': cid, 'selected': 'selected' }, [ cid ]);
									credSelect.appendChild(newOpt);
								} else {
									ui.addNotification(null, E('p', {}, [ _('Failed to create credential set: ') + ((sRes && sRes.message) || _('Error')) ]), 'error');
								}
							}).catch(function(err) {
								ui.hideIndicator();
								ui.addNotification(null, E('p', {}, [ _('Save error: ') + err ]), 'error');
							});
						}
					}, [ _('Save Credentials') ])
				])
			]);

			ui.showModal(_('New Credential Set'), [ modalContent ]);
		}

		// 3. Drop Zone & Multi-File Input Area
		var fileInputEl = E('input', {
			'type': 'file',
			'multiple': 'multiple',
			'accept': '.ovpn,.conf,.sswan',
			'style': 'display: none;'
		});

		var dropZone = E('div', {
			'class': 'gv-dropzone',
			'style': 'margin-bottom: 24px;'
		}, [
			E('div', { 'style': 'font-size: 2.2rem; margin-bottom: 8px;' }, [ '📁' ]),
			E('div', { 'style': 'font-size: 1.1rem; font-weight: 600; margin-bottom: 6px;' }, [
				_('Drag & Drop .ovpn, .conf, and .sswan Configuration Files Here')
			]),
			E('div', { 'style': 'font-size: 0.85rem; opacity: 0.75; margin-bottom: 12px;' }, [
				_('Supports multiple files at once (up to 50 files, max 128 KB each)')
			]),
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function(ev) {
					ev.stopPropagation();
					fileInputEl.click();
				}
			}, [ _('Browse Files') ])
		]);

		dropZone.appendChild(fileInputEl);

		// Event handlers for drag & drop
		dropZone.addEventListener('dragover', function(e) {
			e.preventDefault();
			e.stopPropagation();
			dropZone.classList.add('gv-dropzone-dragover');
		});

		dropZone.addEventListener('dragleave', function(e) {
			e.preventDefault();
			e.stopPropagation();
			dropZone.classList.remove('gv-dropzone-dragover');
		});

		dropZone.addEventListener('drop', function(e) {
			e.preventDefault();
			e.stopPropagation();
			dropZone.classList.remove('gv-dropzone-dragover');
			if (e.dataTransfer && e.dataTransfer.files) {
				handleIncomingFiles(e.dataTransfer.files);
			}
		});

		dropZone.addEventListener('click', function() {
			fileInputEl.click();
		});

		fileInputEl.addEventListener('change', function() {
			if (fileInputEl.files) {
				handleIncomingFiles(fileInputEl.files);
			}
		});

		function handleIncomingFiles(fileList) {
			var files = Array.prototype.slice.call(fileList);
			if (files.length === 0) return;

			var readPromises = files.map(function(f) {
				return new Promise(function(resolve) {
					if (f.size > 131072) {
						resolve({
							file: f,
							filename: f.name,
							content: '',
							name: f.name,
							proto: 'unknown',
							sizeKb: (f.size / 1024).toFixed(1),
							valid: false,
							error: _('Exceeds 128 KB size limit')
						});
						return;
					}

					var reader = new FileReader();
					reader.onload = function(e) {
						var content = e.target.result || '';
						var lowerName = f.name.toLowerCase();
						var proto = 'openvpn';
						if (lowerName.endsWith('.conf') || content.indexOf('[Interface]') !== -1) {
							proto = 'wireguard';
						}

						// Deduce human name
						var humanName = f.name.replace(/\.(ovpn|conf)$/i, '').replace(/[-_]+/g, ' ').trim();

						resolve({
							file: f,
							filename: f.name,
							content: content,
							name: humanName,
							proto: proto,
							sizeKb: (f.size / 1024).toFixed(1),
							valid: true,
							error: null
						});
					};
					reader.onerror = function() {
						resolve({
							file: f,
							filename: f.name,
							content: '',
							name: f.name,
							proto: 'unknown',
							sizeKb: '0',
							valid: false,
							error: _('Read error')
						});
					};
					reader.readAsText(f);
				});
			});

			Promise.all(readPromises).then(function(items) {
				items.forEach(function(item) {
					queue.push(item);
				});
				renderPreviewTable();
			});
		}

		// 4. Batch Preview Table Card
		var previewCard = E('div', {
			'class': 'cbi-section gv-card',
			'style': 'background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 20px; margin-bottom: 24px;'
		}, [
			E('div', {
				'class': 'gv-card-title',
				'style': 'font-size: 1.2rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 10px;'
			}, [
				E('span', {}, [ _('Batch Preview & Review') ]),
				E('span', { 'class': 'gv-queue-counter', 'style': 'font-size: 0.85rem; font-weight: 400; opacity: 0.75;' }, [
					_('0 files in queue')
				])
			]),
			E('div', { 'class': 'gv-preview-content' })
		]);

		var previewContainer = previewCard.querySelector('.gv-preview-content');

		function renderPreviewTable() {
			dom.content(previewContainer, []);

			var counterEl = previewCard.querySelector('.gv-queue-counter');
			if (counterEl) {
				counterEl.textContent = _('%d files ready').format(queue.length);
			}

			if (queue.length === 0) {
				dom.append(previewContainer, E('div', {
					'style': 'text-align: center; padding: 24px; opacity: 0.6;'
				}, [
					_('No files selected yet. Drag and drop configuration files above.')
				]));
				return;
			}

			var table = E('table', {
				'class': 'table cbi-section-table',
				'style': 'width: 100%; border-collapse: collapse;'
			}, [
				E('thead', {}, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('File Name') ]),
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Protocol') ]),
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: start;' }, [ _('Profile Name') ]),
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: center;' }, [ _('Size') ]),
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: center;' }, [ _('Status') ]),
						E('th', { 'class': 'th', 'style': 'padding: 8px 12px; text-align: end;' }, [ _('Action') ])
					])
				]),
				E('tbody')
			]);

			var ptbody = table.querySelector('tbody');

			queue.forEach(function(item, idx) {
				var nameInput = E('input', {
					'type': 'text',
					'class': 'cbi-input-text',
					'value': item.name,
					'style': 'width: 100%; min-width: 160px;'
				});
				nameInput.addEventListener('input', function() {
					item.name = nameInput.value;
				});

				var removeBtn = E('button', {
					'class': 'cbi-button cbi-button-remove',
					'click': function() {
						queue.splice(idx, 1);
						renderPreviewTable();
					}
				}, [ _('Remove') ]);

				dom.append(ptbody, E('tr', {
					'class': 'tr cbi-rowstyle-' + (idx % 2 + 1),
					'style': 'border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15));'
				}, [
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; font-weight: 600;' }, [
						widgets.renderLtr(item.filename)
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [
						widgets.renderProtoBadge(item.proto)
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px;' }, [ nameInput ]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [
						widgets.renderLtr(item.sizeKb + ' KB')
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: center;' }, [
						item.valid ?
							widgets.renderCheckBadge('ok') :
							E('span', { 'class': 'gv-badge gv-badge-error', 'style': 'font-size: 0.75rem;' }, [ item.error || _('Invalid') ])
					]),
					E('td', { 'class': 'td', 'style': 'padding: 10px 12px; text-align: end;' }, [ removeBtn ])
				]));
			});

			dom.append(previewContainer, table);

			// Action bar under table
			var commitBtn = E('button', {
				'class': 'cbi-button cbi-button-positive',
				'style': 'font-size: 1rem; padding: 8px 20px;',
				'click': commitBatchImport
			}, [ _('Commit Batch Import (%d profiles)').format(queue.filter(function(i) { return i.valid; }).length) ]);

			var clearBtn = E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': function() {
					queue = [];
					renderPreviewTable();
				}
			}, [ _('Clear Queue') ]);

			dom.append(previewContainer, E('div', {
				'style': 'display: flex; justify-content: flex-end; gap: 10px; margin-top: 18px; align-items: center;'
			}, [ clearBtn, commitBtn ]));
		}

		renderPreviewTable();

		// Commit Batch Import Action
		function commitBatchImport() {
			var validItems = queue.filter(function(i) { return i.valid && i.content; });
			if (validItems.length === 0) {
				ui.addNotification(null, E('p', {}, [ _('No valid files in queue to import.') ]), 'warning');
				return;
			}

			ui.showIndicator();

			var selectedPreset = presetSelect.value || 'generic';
			var payload = validItems.map(function(i) {
				return {
					filename: i.filename,
					content: i.content,
					name: i.name || i.filename,
					proto: i.proto,
					provider: selectedPreset
				};
			});

			var dedupePolicy = dedupeSelect.value || 'skip';
			var sharedCred = credSelect.value || '';

			var CHUNK_SIZE = 50;
			var chunks = [];
			for (var c = 0; c < payload.length; c += CHUNK_SIZE) {
				chunks.push(payload.slice(c, c + CHUNK_SIZE));
			}

			var totalImported = 0;
			var totalSkipped = 0;
			var totalErrors = 0;
			var errorMessages = [];

			function processChunk(idx) {
				if (idx >= chunks.length) {
					ui.hideIndicator();
					showImportReport(totalImported, totalSkipped, totalErrors, errorMessages);
					return;
				}

				api.importBatch(chunks[idx], sharedCred, dedupePolicy, false, '', selectedPreset).then(function(res) {
					if (!res || res.error) {
						totalErrors += chunks[idx].length;
						errorMessages.push((res && res.message) || _('Failed to process batch slice'));
					} else {
						totalImported += (res.imported && res.imported.length) || 0;
						totalSkipped += (res.skipped && res.skipped.length) || 0;
						totalErrors += (res.errors && res.errors.length) || 0;
						if (res.errors && Array.isArray(res.errors)) {
							res.errors.forEach(function(e) {
								if (e && e.error) errorMessages.push((e.item || 'Item') + ': ' + e.error);
							});
						}
					}
					processChunk(idx + 1);
				}).catch(function(err) {
					totalErrors += chunks[idx].length;
					errorMessages.push(String(err));
					processChunk(idx + 1);
				});
			}

			processChunk(0);
		}

		function showImportReport(importedCount, skippedCount, errCount, errorMessages) {
			var reportContent = E('div', {}, [
				E('h4', { 'style': 'margin-bottom: 12px;' }, [ _('Batch Import Summary') ]),
				E('div', { 'class': 'gv-grid', 'style': 'margin-bottom: 16px;' }, [
					E('div', { 'class': 'gv-metric' }, [
						E('div', { 'class': 'gv-metric-label' }, [ _('Successfully Imported') ]),
						E('div', { 'class': 'gv-metric-value', 'style': 'color: #2da44e;' }, [ String(importedCount) ])
					]),
					E('div', { 'class': 'gv-metric' }, [
						E('div', { 'class': 'gv-metric-label' }, [ _('Skipped (Duplicates)') ]),
						E('div', { 'class': 'gv-metric-value', 'style': 'color: #d29922;' }, [ String(skippedCount) ])
					]),
					E('div', { 'class': 'gv-metric' }, [
						E('div', { 'class': 'gv-metric-label' }, [ _('Errors') ]),
						E('div', { 'class': 'gv-metric-value', 'style': 'color: ' + (errCount > 0 ? '#f85149' : 'inherit') + ';' }, [ String(errCount) ])
					])
				]),
				(errorMessages && errorMessages.length > 0) ? E('div', {
					'class': 'gv-banner-warn',
					'style': 'margin-bottom: 14px; font-size: 0.85rem;'
				}, [
					E('strong', {}, [ _('Issues encountered during import:') ]),
					E('ul', { 'style': 'margin: 6px 0 0 16px; padding: 0;' }, errorMessages.slice(0, 5).map(function(m) {
						return E('li', {}, [ m ]);
					}))
				]) : E('span'),
				E('div', { 'style': 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px;' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function() {
							ui.hideModal();
							queue = [];
							renderPreviewTable();
						}
					}, [ _('Import More') ]),
					E('a', {
						'class': 'cbi-button cbi-button-action',
						'href': L.url('admin/vpn/geovpn/profiles')
					}, [ _('View Profiles') ]),
					E('a', {
						'class': 'cbi-button cbi-button-positive',
						'href': L.url('admin/vpn/geovpn/testpanel')
					}, [ _('Test in Test Panel') ])
				])
			]);

			ui.showModal(_('Import Completed'), [ reportContent ]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('GeoVPN — Profile & Batch Importer') ]),
			limitationBanner,
			configCard,
			dropZone,
			previewCard
		]);
	}
});
