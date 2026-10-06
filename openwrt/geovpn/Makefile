#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=GeoVPN meta-package (backend + LuCI + Persian)
  PKGARCH:=all
  DEPENDS:=+geovpn-core +luci-app-geovpn +luci-i18n-geovpn-fa
endef

define Package/geovpn/description
  Meta-package installing the complete GeoVPN suite:
  OpenVPN core service, policy routing, LuCI web management interface,
  and Persian language pack.
endef

define Build/Compile
endef

define Package/geovpn/install
	true
endef

$(eval $(call BuildPackage,geovpn))
