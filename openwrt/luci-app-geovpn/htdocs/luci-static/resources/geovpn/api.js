'use strict';
'require baseclass';
'require rpc';

var callStatus = rpc.declare({
	object: 'luci.geovpn',
	method: 'status',
	expect: { '': {} }
});

var callLogs = rpc.declare({
	object: 'luci.geovpn',
	method: 'logs',
	params: [ 'lines', 'source' ],
	expect: { '': {} }
});

var callImportOvpn = rpc.declare({
	object: 'luci.geovpn',
	method: 'import_ovpn',
	params: [ 'name', 'content' ],
	expect: { '': {} }
});

var callImportProfile = rpc.declare({
	object: 'luci.geovpn',
	method: 'import_profile',
	params: [ 'name', 'filename', 'content', 'proto', 'cred', 'dry_run', 'dedupe', 'provider' ],
	expect: { '': {} }
});

var callImportBatch = rpc.declare({
	object: 'luci.geovpn',
	method: 'import_batch',
	params: [ 'items', 'cred', 'dedupe', 'atomic', 'proto', 'provider' ],
	expect: { '': {} }
});

var callSetCredentials = rpc.declare({
	object: 'luci.geovpn',
	method: 'profile_set_credentials',
	params: [ 'id', 'username', 'password' ],
	expect: { '': {} }
});

var callPutMaterial = rpc.declare({
	object: 'luci.geovpn',
	method: 'profile_put_material',
	params: [ 'id', 'role', 'content' ],
	expect: { '': {} }
});

var callDeleteProfile = rpc.declare({
	object: 'luci.geovpn',
	method: 'profile_delete',
	params: [ 'id' ],
	expect: { '': {} }
});

var callService = rpc.declare({
	object: 'luci.geovpn',
	method: 'service',
	params: [ 'action', 'profile', 'persist' ],
	expect: { '': {} }
});

var callPanic = rpc.declare({
	object: 'luci.geovpn',
	method: 'panic',
	expect: { '': {} }
});

var callCatalog = rpc.declare({
	object: 'luci.geovpn',
	method: 'geo_catalog',
	params: [ 'kind', 'q', 'offset', 'limit' ],
	expect: { '': {} }
});

var callUpdate = rpc.declare({
	object: 'luci.geovpn',
	method: 'geo_update',
	params: [ 'force' ],
	expect: { '': {} }
});

var callUpdateStatus = rpc.declare({
	object: 'luci.geovpn',
	method: 'geo_update_status',
	expect: { '': {} }
});

var callTestTarget = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_target',
	params: [ 'target', 'client' ],
	expect: { '': {} }
});

var callDiag = rpc.declare({
	object: 'luci.geovpn',
	method: 'diag',
	expect: { '': {} }
});

var callProfileGet = rpc.declare({
	object: 'luci.geovpn',
	method: 'profile_get',
	params: [ 'id' ],
	expect: { '': {} }
});

var callProfileSaveRawRpc = rpc.declare({
	object: 'luci.geovpn',
	method: 'profile_save_raw',
	expect: { '': {} }
});

var callProfileSaveRaw = function(id, name, ovpn, auth, extra) {
	var payload = Object.assign({}, extra || {});
	if (typeof id === 'object' && id !== null) {
		payload = Object.assign(payload, id);
	} else {
		payload.id = id;
		if (name != null) payload.name = name;
		if (ovpn != null) payload.ovpn = ovpn;
		if (auth != null) payload.auth = auth;
	}
	return callProfileSaveRawRpc(payload);
};

var callTestStart = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_start',
	params: [ 'ids', 'all', 'probe_url' ],
	expect: { '': {} }
});

var callTestStatus = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_status',
	params: [ 'job_id' ],
	expect: { '': {} }
});

var callTestCancel = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_cancel',
	params: [ 'job_id' ],
	expect: { '': {} }
});

var callTestCleanup = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_cleanup',
	params: [ 'verify' ],
	expect: { '': {} }
});

var callTestResults = rpc.declare({
	object: 'luci.geovpn',
	method: 'test_results',
	params: [ 'ids' ],
	expect: { '': {} }
});

var callListCredentials = rpc.declare({
	object: 'luci.geovpn',
	method: 'list_credentials',
	expect: { '': {} }
});

var callSaveCredential = rpc.declare({
	object: 'luci.geovpn',
	method: 'save_credential',
	params: [ 'id', 'username', 'password', 'wg_key', 'wg_psk' ],
	expect: { '': {} }
});

var callDeleteCredential = rpc.declare({
	object: 'luci.geovpn',
	method: 'delete_credential',
	params: [ 'id' ],
	expect: { '': {} }
});

var callAutoconnectStatus = rpc.declare({
	object: 'luci.geovpn',
	method: 'autoconnect_status',
	expect: { '': {} }
});

var callHealthTick = rpc.declare({
	object: 'luci.geovpn',
	method: 'health_tick',
	params: [ 'force' ],
	expect: { '': {} }
});

return baseclass.extend({
	getStatus: callStatus,
	getLogs: callLogs,
	importOvpn: callImportOvpn,
	importProfile: callImportProfile,
	import_profile: callImportProfile,
	importBatch: callImportBatch,
	import_batch: callImportBatch,
	getProfile: callProfileGet,
	saveProfileRaw: callProfileSaveRaw,
	setCredentials: callSetCredentials,
	putMaterial: callPutMaterial,
	deleteProfile: callDeleteProfile,
	callService: callService,
	callPanic: callPanic,
	getCatalog: callCatalog,
	startUpdate: callUpdate,
	getUpdateStatus: callUpdateStatus,
	testTarget: callTestTarget,
	getDiag: callDiag,
	testStart: callTestStart,
	test_start: callTestStart,
	testStatus: callTestStatus,
	test_status: callTestStatus,
	testCancel: callTestCancel,
	test_cancel: callTestCancel,
	testCleanup: callTestCleanup,
	test_cleanup: callTestCleanup,
	testResults: callTestResults,
	test_results: callTestResults,
	listCredentials: callListCredentials,
	list_credentials: callListCredentials,
	saveCredential: callSaveCredential,
	save_credential: callSaveCredential,
	deleteCredential: callDeleteCredential,
	delete_credential: callDeleteCredential,
	getAutoconnectStatus: callAutoconnectStatus,
	autoconnect_status: callAutoconnectStatus,
	runHealthTick: callHealthTick,
	health_tick: callHealthTick,
	switchProfile: function(profileId, persist) {
		return callService('switch', profileId, persist ? 1 : 0);
	}
});
