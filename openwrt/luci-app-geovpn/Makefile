#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for GeoVPN (multi-protocol geo split tunneling)
LUCI_DEPENDS:=+geovpn-core +luci-base +rpcd +rpcd-mod-ucode
LUCI_PKGARCH:=all
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
