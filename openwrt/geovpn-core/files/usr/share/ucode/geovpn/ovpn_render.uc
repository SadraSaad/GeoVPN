//
// GeoVPN OpenVPN Configuration Renderer (Shim forwarding to drivers/openvpn)
//
'use strict';

import * as drv from './drivers/openvpn.uc';

function render_ovpn(profile, profile_dir, main_cfg, ctx) {
	return drv.render_ovpn(profile, profile_dir, main_cfg, ctx);
}

export {
	render_ovpn
};
