#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn-ikev2
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn-ikev2
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=IKEv2 / strongSwan protocol driver for GeoVPN
  PKGARCH:=all
  DEPENDS:=+geovpn-core +kmod-xfrm-interface +strongswan-charon +strongswan-swanctl +strongswan-mod-kernel-netlink +strongswan-mod-socket-default +strongswan-mod-eap-mschapv2 +strongswan-mod-xauth-generic +strongswan-mod-openssl +strongswan-mod-vici
endef

define Package/geovpn-ikev2/description
  IKEv2 / strongSwan protocol driver add-on for GeoVPN.
  Provides route-based IPsec (XFRM interface) client connectivity with EAP-MSCHAPv2
  integrated with GeoVPN policy routing and kill switch.
endef

define Build/Compile
endef

define Package/geovpn-ikev2/install
	true
endef

define Package/geovpn-ikev2/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if command -v swanctl >/dev/null 2>&1; then
		swanctl --terminate --ike gv_active 2>/dev/null || true
		swanctl --unload-conn --name gv_active 2>/dev/null || true
	fi
	ip link del dev geovpn0 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,geovpn-ikev2))
