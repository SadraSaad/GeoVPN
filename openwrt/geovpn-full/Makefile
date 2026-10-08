#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn-full
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn-full
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=GeoVPN full meta-package (core + openvpn + wireguard + ikev2 + LuCI + seed)
  PKGARCH:=all
  DEPENDS:=+geovpn +geovpn-wireguard +geovpn-ikev2
endef

define Package/geovpn-full/description
  Full meta-package installing the complete GeoVPN suite:
  all supported VPN protocols (OpenVPN, WireGuard, IKEv2/strongSwan),
  core policy routing, LuCI web management interface, Persian language pack,
  and starter offline data.
endef

define Build/Compile
endef

define Package/geovpn-full/install
	true
endef

$(eval $(call BuildPackage,geovpn-full))
