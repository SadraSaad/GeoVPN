#
# Copyright (C) 2026 GeoVPN Project
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=geovpn-core
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GeoVPN Developers <geovpn@example.org>

include $(INCLUDE_DIR)/package.mk

define Package/geovpn-core
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=OpenVPN client with geo-based split tunneling (backend)
  PKGARCH:=all
  DEPENDS:=+openvpn-openssl +kmod-tun +ip-full +firewall4 +nftables-json \
    +dnsmasq-full +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
    +ucode-mod-uloop +ucode-mod-resolv +uclient-fetch +libustream-mbedtls \
    +ca-bundle +usign
endef

define Package/geovpn-core/description
  Manages OpenVPN client profiles and routes LAN traffic by GeoIP/GeoSite
  using nftables sets, policy routing, and dnsmasq nftset integration.
endef

define Package/geovpn-core/conffiles
/etc/config/geovpn
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/geovpn-core/install
	$(CP) ./files/* $(1)/
	$(INSTALL_DIR) $(1)/etc/geovpn/profiles $(1)/etc/geovpn/data $(1)/etc/geovpn/keys $(1)/etc/geovpn/backup
	chmod 0700 $(1)/etc/geovpn/profiles $(1)/etc/geovpn/backup
	chmod 0755 $(1)/etc/init.d/geovpn $(1)/usr/bin/geovpn $(1)/usr/bin/geovpn-update \
	  $(1)/usr/libexec/geovpn/ovpn-hook $(1)/usr/libexec/geovpn/spawn \
	  $(1)/etc/uci-defaults/90-geovpn $(1)/etc/hotplug.d/iface/50-geovpn
	chmod 0600 $(1)/etc/config/geovpn
endef

define Package/geovpn-core/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -x /etc/uci-defaults/90-geovpn ] && /bin/sh /etc/uci-defaults/90-geovpn && rm -f /etc/uci-defaults/90-geovpn
	/etc/init.d/cron enable 2>/dev/null
	/etc/init.d/cron start 2>/dev/null
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

define Package/geovpn-core/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/usr/bin/geovpn panic 2>/dev/null || true
	/etc/init.d/geovpn stop 2>/dev/null || true
	/etc/init.d/geovpn disable 2>/dev/null || true
}
exit 0
endef

define Package/geovpn-core/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/dnsmasq.d/geovpn.conf /tmp/dnsmasq.*.d/geovpn.conf 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,geovpn-core))
