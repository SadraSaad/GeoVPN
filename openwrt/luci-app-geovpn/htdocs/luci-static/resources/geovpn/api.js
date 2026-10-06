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
	params: [ 'action', 'profile' ],
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

return baseclass.extend({
	getStatus: callStatus,
	getLogs: callLogs,
	importOvpn: callImportOvpn,
	setCredentials: callSetCredentials,
	putMaterial: callPutMaterial,
	deleteProfile: callDeleteProfile,
	callService: callService,
	callPanic: callPanic,
	getCatalog: callCatalog,
	startUpdate: callUpdate,
	getUpdateStatus: callUpdateStatus,
	testTarget: callTestTarget,
	getDiag: callDiag
});
