#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn-data-seed
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=CC0-1.0
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn-data-seed
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Starter offline GeoIP data for GeoVPN
  PKGARCH:=all
  DEPENDS:=+geovpn-core
endef

define Package/geovpn-data-seed/description
  Provides offline starter seed data (RFC1918 / Private and starter Iran CIDRs)
  so that GeoVPN can run on first install without needing immediate internet access.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/geovpn-data-seed/install
	$(INSTALL_DIR) $(1)/etc/geovpn/data/ip $(1)/etc/geovpn/data/catalog
	$(CP) ./files/* $(1)/etc/geovpn/data/ 2>/dev/null || true
endef

$(eval $(call BuildPackage,geovpn-data-seed))
