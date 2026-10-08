#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn-wireguard
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn-wireguard
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=WireGuard protocol driver for GeoVPN
  PKGARCH:=all
  DEPENDS:=+geovpn-core +kmod-wireguard +wireguard-tools
endef

define Package/geovpn-wireguard/description
  WireGuard protocol driver add-on for GeoVPN.
  Provides kernel WireGuard client connectivity integrated with
  GeoVPN policy routing and kill switch.
endef

define Build/Compile
endef

define Package/geovpn-wireguard/install
	true
endef

define Package/geovpn-wireguard/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ -d /sys/class/net/geovpn0 ]; then
		ip link del dev geovpn0 2>/dev/null || true
	fi
}
exit 0
endef

$(eval $(call BuildPackage,geovpn-wireguard))
