'use strict';
'require dom';

function renderBadge(stateName) {
	var cls = 'gv-badge-disabled';
	var label = stateName || 'unknown';

	if (stateName === 'connected') {
		cls = 'gv-badge-connected';
	} else if (stateName === 'connecting' || stateName === 'applying') {
		cls = 'gv-badge-connecting';
	} else if (stateName === 'error') {
		cls = 'gv-badge-error';
	}

	return E('span', { 'class': 'gv-badge ' + cls }, [ label ]);
}

function renderLtr(text) {
	return E('bdi', { 'class': 'gv-ltr' }, [ text != null ? String(text) : '' ]);
}

function formatBytes(bytes) {
	var b = Number(bytes) || 0;
	if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB';
	if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB';
	if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
	return b + ' B';
}

function formatUptime(seconds) {
	var s = Number(seconds) || 0;
	if (s <= 0) return '-';
	var days = Math.floor(s / 86400);
	var hours = Math.floor((s % 86400) / 3600);
	var mins = Math.floor((s % 3600) / 60);
	var secs = s % 60;

	var parts = [];
	if (days > 0) parts.push(days + 'd');
	if (hours > 0) parts.push(hours + 'h');
	if (mins > 0) parts.push(mins + 'm');
	parts.push(secs + 's');
	return parts.join(' ');
}

return {
	renderBadge: renderBadge,
	renderLtr: renderLtr,
	formatBytes: formatBytes,
	formatUptime: formatUptime
};
