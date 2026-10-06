'use strict';
'require baseclass';
'require dom';

function loadStylesheet() {
	if (typeof document !== 'undefined' && document.head && !document.getElementById('geovpn-style')) {
		var style = E('style', { 'id': 'geovpn-style' }, [
			'.gv-ltr { direction: ltr !important; unicode-bidi: isolate !important; display: inline-block; }\n' +
			'.gv-card { background: var(--cbi-section-background, rgba(127, 127, 127, 0.05)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.2)); border-radius: 8px; padding: 18px 22px; margin-bottom: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }\n' +
			'.gv-card-title { font-size: 1.25rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); padding-bottom: 12px; }\n' +
			'.gv-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-top: 14px; margin-bottom: 18px; }\n' +
			'.gv-metric { padding: 12px 14px; background: var(--cbi-input-background, rgba(127, 127, 127, 0.08)); border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.15)); border-radius: 6px; display: flex; flex-direction: column; justify-content: center; min-height: 70px; }\n' +
			'.gv-metric-label { font-size: 0.78rem; opacity: 0.75; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; }\n' +
			'.gv-metric-value { font-size: 1.15rem; font-weight: 700; margin-top: 6px; word-break: break-all; }\n' +
			'.gv-badge { display: inline-flex; align-items: center; justify-content: center; padding: 3px 10px; border-radius: 14px; font-size: 0.8rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; line-height: 1.4; }\n' +
			'.gv-badge-connected { background-color: rgba(46, 160, 67, 0.2) !important; color: #2da44e !important; border: 1px solid rgba(46, 160, 67, 0.6) !important; }\n' +
			'.gv-badge-connecting, .gv-badge-applying { background-color: rgba(210, 153, 34, 0.2) !important; color: #d29922 !important; border: 1px solid rgba(210, 153, 34, 0.6) !important; }\n' +
			'.gv-badge-disabled { background-color: rgba(127, 127, 127, 0.15) !important; color: #8b949e !important; border: 1px solid rgba(127, 127, 127, 0.4) !important; }\n' +
			'.gv-badge-error { background-color: rgba(248, 81, 73, 0.2) !important; color: #f85149 !important; border: 1px solid rgba(248, 81, 73, 0.6) !important; }\n' +
			'.gv-actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; align-items: center; }\n' +
			'.gv-log-box { background: #161b22; color: #c9d1d9; border: 1px solid rgba(127, 127, 127, 0.2); font-family: monospace; font-size: 0.85rem; line-height: 1.5; padding: 14px; border-radius: 6px; max-height: 450px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; direction: ltr; text-align: left; }\n' +
			'.gv-editor-textarea { width: 100%; font-family: monospace; font-size: 0.85rem; line-height: 1.45; padding: 10px; border-radius: 6px; border: 1px solid var(--cbi-border-color, rgba(127, 127, 127, 0.3)); background: var(--cbi-input-background, rgba(0, 0, 0, 0.1)); color: inherit; box-sizing: border-box; }\n' +
			'[dir="rtl"] .gv-actions { flex-direction: row-reverse; }\n'
		]);
		document.head.appendChild(style);
	}
}

function renderBadge(stateName) {
	var label = stateName || 'unknown';
	var bg = 'rgba(127, 127, 127, 0.15)';
	var color = '#8b949e';
	var border = 'rgba(127, 127, 127, 0.4)';
	var cls = 'gv-badge-disabled';

	if (stateName === 'connected') {
		cls = 'gv-badge-connected';
		bg = 'rgba(46, 160, 67, 0.2)';
		color = '#2da44e';
		border = 'rgba(46, 160, 67, 0.6)';
	} else if (stateName === 'connecting' || stateName === 'applying') {
		cls = 'gv-badge-connecting';
		bg = 'rgba(210, 153, 34, 0.2)';
		color = '#d29922';
		border = 'rgba(210, 153, 34, 0.6)';
	} else if (stateName === 'error') {
		cls = 'gv-badge-error';
		bg = 'rgba(248, 81, 73, 0.2)';
		color = '#f85149';
		border = 'rgba(248, 81, 73, 0.6)';
	}

	return E('span', {
		'class': 'gv-badge ' + cls,
		'style': 'display: inline-flex; align-items: center; justify-content: center; padding: 2px 10px; border-radius: 12px; font-size: 0.8rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; background-color: ' + bg + '; color: ' + color + '; border: 1px solid ' + border + ';'
	}, [ label ]);
}

function renderCheckBadge(level) {
	var lvl = (level || '').toLowerCase();
	var text = lvl.toUpperCase();
	var bg = 'rgba(127, 127, 127, 0.15)';
	var color = '#8b949e';
	var border = 'rgba(127, 127, 127, 0.4)';
	var cls = 'gv-badge-disabled';

	if (lvl === 'ok') {
		cls = 'gv-badge-connected';
		bg = 'rgba(46, 160, 67, 0.2)';
		color = '#2da44e';
		border = 'rgba(46, 160, 67, 0.6)';
	} else if (lvl === 'warn') {
		cls = 'gv-badge-connecting';
		bg = 'rgba(210, 153, 34, 0.2)';
		color = '#d29922';
		border = 'rgba(210, 153, 34, 0.6)';
	} else if (lvl === 'fail') {
		cls = 'gv-badge-error';
		bg = 'rgba(248, 81, 73, 0.2)';
		color = '#f85149';
		border = 'rgba(248, 81, 73, 0.6)';
	}

	return E('span', {
		'class': 'gv-badge ' + cls,
		'style': 'display: inline-flex; align-items: center; justify-content: center; min-width: 50px; padding: 2px 8px; border-radius: 12px; font-size: 0.8rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; background-color: ' + bg + '; color: ' + color + '; border: 1px solid ' + border + ';'
	}, [ text ]);
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

return baseclass.extend({
	loadStylesheet: loadStylesheet,
	renderBadge: renderBadge,
	renderCheckBadge: renderCheckBadge,
	renderLtr: renderLtr,
	formatBytes: formatBytes,
	formatUptime: formatUptime
});
