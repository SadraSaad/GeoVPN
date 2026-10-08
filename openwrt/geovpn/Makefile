#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=GeoVPN meta-package (core + OpenVPN + LuCI + seed)
  PKGARCH:=all
  DEPENDS:=+geovpn-core +openvpn-openssl +luci-app-geovpn +luci-i18n-geovpn-fa +geovpn-data-seed
endef

define Package/geovpn/description
  Meta-package installing the standard GeoVPN suite:
  OpenVPN core service, policy routing, LuCI web management interface,
  Persian language pack, and starter offline data.
endef

define Build/Compile
endef

define Package/geovpn/install
	true
endef

$(eval $(call BuildPackage,geovpn))
