'use strict';
'require baseclass';
'require ui';
'require dom';
'require geovpn.api as api';
'require geovpn.widgets as widgets';

function showPicker(kind, onSelect) {
	var currentQuery = '';
	var currentOffset = 0;
	var limit = 20;

	var tableBody = E('tbody');
	var searchInput = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'placeholder': _('Search category (e.g. ir, apple)...'),
		'style': 'width: 100%; margin-bottom: 12px;'
	});

	var paginationInfo = E('span', { 'style': 'margin-inline-end: 10px;' });
	var prevBtn = E('button', { 'class': 'cbi-button', 'disabled': 'true' }, [ _('Previous') ]);
	var nextBtn = E('button', { 'class': 'cbi-button', 'disabled': 'true' }, [ _('Next') ]);

	function loadData() {
		dom.content(tableBody, [
			E('tr', {}, [ E('td', { 'colspan': '4', 'style': 'text-align: center;' }, [ _('Loading...') ]) ])
		]);

		api.getCatalog(kind, currentQuery, currentOffset, limit).then(function(res) {
			var items = (res && res.items) ? res.items : [];
			var total = (res && res.total) ? res.total : 0;

			dom.content(tableBody, []);
			if (items.length === 0) {
				dom.content(tableBody, [
					E('tr', {}, [ E('td', { 'colspan': '4', 'style': 'text-align: center;' }, [ _('No categories found') ]) ])
				]);
			} else {
				items.forEach(function(item) {
					var selectBtn = E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							ui.hideModal();
							if (typeof onSelect === 'function') {
								onSelect(item.name);
							}
						}
					}, [ _('Add') ]);

					var countDisplay = (kind === 'geoip')
						? (item.count + ' v4 / ' + (item.count_v6 || 0) + ' v6')
						: (item.count + ' domains');

					dom.append(tableBody, E('tr', {}, [
						E('td', { 'style': 'font-weight: 600;' }, [ widgets.renderLtr(item.name) ]),
						E('td', {}, [ countDisplay ]),
						E('td', {}, [ item.est_ram || '-' ]),
						E('td', { 'style': 'text-align: right;' }, [ selectBtn ])
					]));
				});
			}

			paginationInfo.textContent = (currentOffset + 1) + ' - ' + Math.min(currentOffset + limit, total) + ' of ' + total;
			prevBtn.disabled = (currentOffset <= 0);
			nextBtn.disabled = (currentOffset + limit >= total);
		}).catch(function(err) {
			dom.content(tableBody, [
				E('tr', {}, [ E('td', { 'colspan': '4', 'style': 'color: red;' }, [ _('Error loading catalog: ') + err ]) ])
			]);
		});
	}

	var searchTimeout = null;
	searchInput.addEventListener('input', function(e) {
		clearTimeout(searchTimeout);
		searchTimeout = setTimeout(function() {
			currentQuery = searchInput.value.trim();
			currentOffset = 0;
			loadData();
		}, 250);
	});

	prevBtn.addEventListener('click', function() {
		if (currentOffset >= limit) {
			currentOffset -= limit;
			loadData();
		}
	});

	nextBtn.addEventListener('click', function() {
		currentOffset += limit;
		loadData();
	});

	var modalContent = E('div', {}, [
		E('h4', {}, [ kind === 'geoip' ? _('Select GeoIP Country') : _('Select GeoSite Category') ]),
		searchInput,
		E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', {}, [ _('Name') ]),
					E('th', {}, [ _('Entries') ]),
					E('th', {}, [ _('Est. RAM') ]),
					E('th', { 'style': 'text-align: right;' }, [ _('Action') ])
				])
			]),
			tableBody
		]),
		E('div', { 'style': 'display: flex; justify-content: flex-end; align-items: center; margin-top: 10px;' }, [
			paginationInfo,
			prevBtn,
			E('span', { 'style': 'width: 8px;' }),
			nextBtn,
			E('span', { 'style': 'width: 16px;' }),
			E('button', {
				'class': 'cbi-button',
				'click': ui.hideModal
			}, [ _('Cancel') ])
		])
	]);

	ui.showModal(_('Category Picker'), [ modalContent ]);
	loadData();
}

return baseclass.extend({
	showPicker: showPicker
});
