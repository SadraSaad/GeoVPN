#!/usr/bin/env python3
#
# Generate GeoVPN POT template and Persian PO translation
#
import os
import re
import glob
import json

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
POT_PATH = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/templates/geovpn.pot')
PO_PATH = os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/po/fa/geovpn.po')

# Mapping of English source string -> Persian translation
TRANSLATIONS = {
    ' — Only selected countries/domains use VPN; all other traffic uses direct WAN.': ' — فقط ترافیک کشورها/دامنه‌های انتخابی از VPN عبور کرده و باقی ترافیک مستقیماً (WAN) ارسال می‌شود.',
    ' — Pure embedded OpenVPN client with geo-based split tunneling, policy routing, and zero resident daemon footprint.': ' — کلاینت تمام‌عیار OpenVPN برای سیستم‌های تعبیه‌شده با تونل‌بندی انتخابی جغرافیایی، مسیریابی هوشمند و بدون فرآیند پس‌زمینه اضافی.',
    ' — Selected countries/domains bypass VPN to direct WAN; all other traffic uses VPN.': ' — ترافیک کشورها/دامنه‌های انتخابی به صورت مستقیم (WAN) عبور کرده و باقی ترافیک از VPN می‌گذرد.',
    '+ Add Category (GeoSite)…': '+ افزودن دسته‌بندی (GeoSite)…',
    '+ Add Client Policy': '+ افزودن خط‌مشی کلاینت',
    '+ Add Country (GeoIP)…': '+ افزودن کشور (GeoIP)…',
    '+ Add Custom Rule': '+ افزودن قانون سفارشی',
    '+ Import .ovpn Profile': '+ وارد کردن پروفایل .ovpn',
    '100 Lines': '۱۰۰ خط',
    '200 Lines': '۲۰۰ خط',
    '500 Lines': '۵۰۰ خط',
    'About GeoVPN': 'درباره GeoVPN',
    'Action': 'عملیات',
    'Actions': 'عملیات',
    'Active': 'فعال',
    'Active Profile': 'پروفایل فعال',
    'Active ✔': 'فعال ✔',
    'Add': 'افزودن',
    'Add Client Policy': 'افزودن خط‌مشی کلاینت',
    'Add Custom Rule': 'افزودن قانون سفارشی',
    'Address': 'آدرس',
    'Address cannot be empty.': 'آدرس نمی‌تواند خالی باشد.',
    'Advanced Routing & System Limits': 'مسیریابی پیشرفته و محدودیت‌های سیستم',
    'All GeoVPN Logs': 'کلیه گزارش‌های GeoVPN',
    'All Systems OK ✔': 'کلیه بخش‌ها سالم هستند ✔',
    'All logs are automatically scrubbed on the router to remove certificates, private keys, and passwords before display.': 'کلیه گزارش‌ها پیش از نمایش، به صورت خودکار پالایش شده تا کلیدهای خصوصی، گواهی‌ها و رمزهای عبور حذف شوند.',
    'Allow large data packs on devices with < 512MB RAM': 'اجازه بارگذاری بسته‌های داده حجیم در دستگاه‌های با رم کمتر از ۵۱۲ مگابایت',
    'Always Direct WAN DNS': 'همیشه DNS اتصال مستقیم WAN',
    'Always VPN DNS': 'همیشه DNS اتصال VPN',
    'Always direct WAN': 'همیشه مستقیم از WAN',
    'Assigned IP': 'آدرس IP تخصیص‌یافته',
    'Auth': 'احراز هویت',
    'Auto': 'خودکار',
    'Auto routes IPv6 if VPN provides an IPv6 endpoint; otherwise keeps direct or blocks.': 'در صورت ارائه IPv6 توسط سرور VPN ترافیک مسیریابی می‌شود؛ در غیر این صورت مستقیم مانده یا مسدود می‌گردد.',
    'Auto-Update': 'به‌روزرسانی خودکار',
    'Auto-refresh (3s)': 'تازه‌سازی خودکار (۳ ثانیه)',
    'Bit shift for packet and connmark (bits [shift..shift+3]). Shift 24 avoids mwan3 (bits 0..15).': 'میزان شیفت بیتی برای علامت‌گذاری بسته‌ها و اتصالات (بیت‌های [shift..shift+3]). مقدار ۲۴ از تداخل با mwan3 جلوگیری می‌کند.',
    'Block (prevent leaks)': 'مسدودسازی (جلوگیری از نشت)',
    'Block DNS-over-HTTPS (DoH)': 'مسدودسازی پروتکل DoH',
    'Block DNS-over-TLS (DoT)': 'مسدودسازی پروتکل DoT (پورت ۸۵۳)',
    'Block VPN traffic when tunnel is down': 'مسدودسازی ترافیک VPN هنگام قطع بودن تونل',
    'Bypass listed': 'عبور مستقیم موارد انتخابی (Bypass)',
    'Cancel': 'لغو',
    'Capacity Limits': 'محدودیت‌های ظرفیت',
    'Category Picker': 'انتخابگر دسته‌بندی',
    'Certificate': 'گواهی دیجیتال',
    'Client Device Policies': 'خط‌مشی دستگاه‌های کلاینت',
    'Client Policy': 'خط‌مشی کلاینت',
    'Component Check': 'بررسی مولفه',
    'Configured Profiles': 'پروفایل‌های پیکربندی‌شده',
    'Connections': 'اتصال‌ها',
    'Copy Logs': 'کپی کردن گزارش‌ها',
    'Credentials': 'اطلاعات ورود',
    'Credentials are stored securely with 0600 root-only permissions.': 'اطلاعات ورود با سطح دسترسی امن 0600 (فقط root) ذخیره می‌شوند.',
    'Credentials for ': 'اطلاعات ورود برای ',
    'Credentials updated.': 'اطلاعات ورود ذخیره شد.',
    'Cryptographic Verification': 'اعتبارسنجی با امضای دیجیتال',
    'Custom Rule': 'قانون سفارشی',
    'Custom Target Rules': 'قوانین سفارشی مقاصد',
    'DIRECT': 'مستقیم (DIRECT)',
    'DNS & Leak Protection': 'مدیریت DNS و حفاظت از نشت داده',
    'DNS Path: ': 'مسیر DNS: ',
    'DNS Steering Mode': 'حالت هدایت پرس‌وجوهای DNS',
    'DNS queries for domains in these categories are dynamically added to the policy routing set.': 'پرس‌وجوهای DNS برای دامنه‌های این دسته‌بندی‌ها به طور پویا به مجموعه مسیریابی nftables افزوده می‌شوند.',
    'Data Sources & Verification': 'منابع داده و اعتبارسنجی',
    'Data cache refreshed.': 'حافظه کش داده‌ها تازه‌سازی شد.',
    'Data pack build: ': 'نسخه ساخت بسته داده: ',
    'Debug': 'اشکال‌زدایی (Debug)',
    'Delete': 'حذف',
    'Delete profile "%s"?': 'آیا از حذف پروفایل "%s" اطمینان دارید؟',
    'Details & Recommendations': 'جزئیات و توصیه‌ها',
    'Device Name': 'نام دستگاه',
    'Direct': 'مستقیم',
    'Direct (WAN)': 'مستقیم (WAN)',
    'Direct DNS Servers': 'سرورهای DNS اتصال مستقیم',
    'Direct Only': 'فقط مستقیم',
    'Direct Only (Bypass VPN completely)': 'فقط مستقیم (عدم استفاده از VPN برای کلیه ترافیک)',
    'Direct traffic continues unimpeded. Router management and LAN access are always preserved.': 'ترافیک مستقیم بدون اختلال ادامه می‌یابد. دسترسی مدیریتی به روتر و شبکه محلی LAN همواره تضمین شده است.',
    'Directs domain queries to appropriate resolvers and populates nftables sets.': 'پرس‌وجوهای دامنه را به سمت سرورهای مناسب هدایت کرده و مجموعه‌های nftables را تکمیل می‌کند.',
    'Disabled (Do not touch dnsmasq)': 'غیرفعال (عدم تغییر در تنظیمات dnsmasq)',
    'DoH Canary Signal': 'سیگنال قناری برای غیرفعال‌سازی خودکار DoH',
    'Domain': 'دامنه',
    'Download Diagnostics (JSON)': 'دانلود گزارش عیب‌یابی (JSON)',
    'Dynamic Set Timeout': 'مدت اعتبار مجموعه‌های پویا',
    'Edit': 'ویرایش',
    'Edit Client Policy': 'ویرایش خط‌مشی کلاینت',
    'Edit Custom Rule': 'ویرایش قانون سفارشی',
    'Emergency Stop (Panic)': 'توقف اضطراری (Panic)',
    'Emergency stop: tear down all rules and disable GeoVPN?': 'توقف اضطراری: حذف کلیه قوانین مسیریابی و غیرفعال‌سازی GeoVPN؟',
    'Enable': 'فعال',
    'Enable Split Tunneling': 'فعال‌سازی تونل‌بندی انتخابی',
    'Enable automatic scheduled updates': 'فعال‌سازی به‌روزرسانی زمان‌بندی‌شده خودکار',
    'Enable policy-based routing and DNS steering': 'فعال‌سازی مسیریابی مبتنی بر خط‌مشی و هدایت هوشمند DNS',
    'Entries': 'تعداد مدخل‌ها',
    'Error': 'خطا',
    'Error exporting diagnostics: ': 'خطا در خروجی گزارش عیب‌یابی: ',
    'Error loading catalog: ': 'خطا در بارگذاری فهرست دسته‌بندی‌ها: ',
    'Error simulating route: ': 'خطا در شبیه‌سازی مسیر: ',
    'Est. RAM': 'RAM تقریبی',
    'Estimated RAM: ~%s MB': 'حافظه RAM تقریبی: ~%s مگابایت',
    'Export Diagnostics Bundle (JSON)': 'دریافت فایل گزارش عیب‌یابی (JSON)',
    'Export comprehensive diagnostic details with all credentials and private keys scrubbed for safe sharing, or purge data caches.': 'خروجی گزارش کامل عیب‌یابی با پالایش خودکار کلیدهای خصوصی و اطلاعات ورود جهت اشتراک‌گذاری امن، یا پاک‌سازی حافظه کش داده‌ها.',
    'Failed to apply configuration: ': 'خطا در اعمال پیکربندی: ',
    'Failed to copy to clipboard.': 'کپی در کلیپ‌بورد ناموفق بود.',
    'Firewall Mark Shift': 'شیفت نشانه‌گذاری فایروال (fwmark)',
    'Flush Conntrack': 'پاک‌سازی جدول ردیابی اتصالات (conntrack)',
    'Flush connection tracking table on tunnel state changes': 'تخلیه جدول ردیابی اتصالات در زمان تغییر وضعیت اتصال تونل',
    'Follow Route (Steer by category)': 'پیروی از مسیر (هدایت بر اساس دسته‌بندی)',
    'Geo-Data Pack': 'بسته داده‌های جغرافیایی',
    'GeoIP Countries': 'کشورهای GeoIP',
    'GeoSite Domain Categories': 'دسته‌بندی دامنه‌ها (GeoSite)',
    'GeoVPN': 'GeoVPN',
    'GeoVPN System Events': 'رویدادهای سیستمی GeoVPN',
    'GeoVPN for OpenWrt 25.12': 'GeoVPN برای OpenWrt 25.12',
    'GeoVPN — Logs & Diagnostics': 'GeoVPN — گزارش‌ها و عیب‌یابی',
    'GeoVPN — OpenVPN Connections': 'GeoVPN — اتصال‌های OpenVPN',
    'GeoVPN — Settings': 'GeoVPN — تنظیمات',
    'GeoVPN — Split Tunneling': 'GeoVPN — تونل‌بندی انتخابی',
    'HTTPS mirror hosting MANIFEST and catalog data.': 'آینه HTTPS میزبان فایل MANIFEST و کاتالوگ داده‌ها.',
    'Hijack DNS (Port 53)': 'رهگیری پورت ۵۳ (DNS Hijack)',
    'Hint: ': 'راهنما: ',
    'How long dynamically resolved IP addresses remain in the nftables routing sets (default: 6h).': 'مدت زمانی که آدرس‌های IP حل‌شده در مجموعه‌های nftables باقی می‌مانند (پیش‌فرض: 6h).',
    'How traffic originating directly from the router itself is handled.': 'نحوه مدیریت بسته‌های داده‌ای که مستقیماً از خود روتر منشا می‌گیرند.',
    'IP / CIDR': 'IP / CIDR',
    'IP / Subnet': 'IP / زیرشبکه',
    'IP Address / CIDR': 'آدرس IP / CIDR',
    'IP Rule Priority': 'اولویت قانون مسیریابی (Rule Priority)',
    'IPv6 Handling': 'مدیریت ترافیک IPv6',
    'Idle': 'آماده‌به‌کار',
    'Import': 'وارد کردن',
    'Import OpenVPN Profile': 'وارد کردن پروفایل OpenVPN',
    'Import Profile': 'وارد کردن پروفایل',
    'Import error: ': 'خطای وارد کردن: ',
    'Import failed: ': 'عملیات وارد کردن ناموفق بود: ',
    'Info': 'اطلاعات (Info)',
    'Intercept port 53 UDP/TCP and redirect to router dnsmasq': 'رهگیری بسته‌های UDP/TCP روی پورت ۵۳ و هدایت به dnsmasq روتر',
    'Kill Switch': 'قطع اضطراری اینترنت (Kill Switch)',
    'LAN Firewall Zones': 'زون‌های فایروال محلی (LAN)',
    'LAN Interfaces': 'اینترفیس‌های شبکه محلی (LAN)',
    'Leak Testing & Export': 'آزمایش نشت و خروجی عیب‌یابی',
    'License: Apache-2.0. Data packs: CC0-1.0 / MIT. No proprietary components.': 'مجوز: Apache-2.0. بسته‌های داده: CC0-1.0 / MIT. بدون هرگونه مولفه انحصاری.',
    'Lines:': 'تعداد خطوط:',
    'Linux policy routing table used for VPN traffic (default: 4200).': 'جدول مسیریابی هسته لینوکس برای ترافیک VPN (پیش‌فرض: 4200).',
    'Loading...': 'در حال بارگذاری...',
    'Logging Level': 'سطح ثبت وقایع',
    'Logs & Diagnostics': 'گزارش‌ها و عیب‌یابی',
    'Logs copied to clipboard.': 'گزارش‌ها در کلیپ‌بورد کپی شدند.',
    'MAC': 'آدرس MAC',
    'MAC / IP Address': 'آدرس MAC / IP',
    'MAC Address': 'آدرس MAC',
    'Maintenance & Diagnostics': 'نگهداری و عیب‌یابی',
    'Make Active': 'فعال‌سازی',
    'Match By': 'تطابق بر اساس',
    'Match Criterion': 'معیار تطابق',
    'Match Type': 'نوع تطابق',
    'Matched by: ': 'تطابق با: ',
    'Max CIDRs:': 'حداکثر رنج‌های CIDR:',
    'Max Domains:': 'حداکثر دامنه‌ها:',
    'Name': 'نام',
    'Network Settings': 'تنظیمات شبکه',
    'Next': 'بعدی',
    'No OpenVPN profiles configured. Import an .ovpn file to get started.': 'هیچ پروفایل OpenVPN پیکربندی نشده است. برای شروع یک فایل .ovpn وارد کنید.',
    'No categories found': 'دسته‌بندی یافت نشد',
    'No countries selected.': 'هیچ کشوری انتخاب نشده است.',
    'No custom rules configured.': 'هیچ قانون سفارشی ثبت نشده است.',
    'No diagnostic checks available.': 'هیچ موردی برای عیب‌یابی یافت نشد.',
    'No domain categories selected.': 'هیچ دسته‌بندی دامنه‌ای انتخاب نشده است.',
    'No log entries found.': 'هیچ موردی در گزارش ثبت نشده است.',
    'No per-client policies configured.': 'هیچ خط‌مشی برای کلاینت‌ها ثبت نشده است.',
    'None': 'هیچ‌کدام',
    'Only listed via VPN': 'فقط موارد انتخابی از طریق VPN',
    'Only marked DNS queries': 'فقط پرس‌وجوهای DNS نشانه‌گذاری‌شده',
    'OpenVPN Process': 'فرایند OpenVPN',
    'Or Paste Config': 'یا جای‌گذاری متن پیکربندی',
    'Pack Repository URL': 'آدرس مخزن بسته‌های داده',
    'Password': 'گذرواژه',
    'Paste .ovpn content here...': 'محتوای .ovpn را اینجا جای‌گذاری کنید...',
    'Please upload a file or paste config content.': 'لطفاً یک فایل بارگذاری کنید یا متن پیکربندی را وارد نمایید.',
    'Policy': 'خط‌مشی',
    'Preflight verification checks kernel modules, binaries, firewall rules, and coexistence with other packages.': 'بررسی‌های پیش‌پرواز ماژول‌های هسته، فایل‌های اجرایی، قوانین فایروال و عدم تداخل با بسته‌های دیگر را ارزیابی می‌کند.',
    'Previous': 'قبلی',
    'Priority for policy routing lookup rules (default: 700).': 'اولویت قوانین بررسی مسیر در هسته لینوکس (پیش‌فرض: 700).',
    'Private Networks': 'شبکه‌های خصوصی',
    'Profile Name': 'نام پروفایل',
    'Profile imported successfully: ': 'پروفایل با موفقیت وارد شد: ',
    'Public Key File': 'فایل کلید عمومی',
    'Purge Data Cache': 'پاک‌سازی حافظه کش داده‌ها',
    'Purge downloaded data cache? Categories will be re-downloaded on next update.': 'حافظه کش داده‌ها پاک شود؟ دسته‌بندی‌ها در به‌روزرسانی بعدی مجدداً بارگیری خواهند شد.',
    'Ready': 'آماده',
    'Refresh': 'تازه‌سازی',
    'Reject connections to known public DoH resolvers': 'مسدودسازی اتصال به سرورهای شناخته‌شده عمومی DoH',
    'Reject port 853 to prevent client bypass': 'رد درخواست‌های پورت ۸۵۳ برای جلوگیری از دور زدن قوانین توسط دستگاه‌ها',
    'Remove': 'حذف',
    'Require valid usign signature on pack MANIFEST': 'الزام وجود امضای دیجیتال معتبر usign برای فایل MANIFEST',
    'Resolved IPs: ': 'آدرس‌های IP حل‌شده: ',
    'Respond NXDOMAIN for use-application-dns.net (disables browser auto-DoH)': 'پاسخ NXDOMAIN به دامنه use-application-dns.net جهت غیرفعال‌سازی DoH خودکار در مرورگرها',
    'Restart': 'راه‌اندازی مجدد',
    'Retain previous data pack for instant rollback if update fails': 'نگهداری بسته قبلی جهت بازگشت سریع در صورت بروز خطا در به‌روزرسانی',
    'Rollback Backup': 'پشتیبان‌گیری برای بازگشت به نسخه قبل',
    'Route': 'مسیر',
    'Route Simulator & Live Sets': 'شبیه‌ساز مسیر و مجموعه‌های زنده',
    'Route through VPN': 'مسیریابی از طریق VPN',
    'Router Self-Generated Traffic': 'ترافیک ایجادشده توسط خود روتر',
    'Routing Decision:': 'تصمیم مسیریابی:',
    'Routing Mode': 'حالت مسیریابی',
    'Routing Policy': 'خط‌مشی مسیریابی',
    'Routing Table ID': 'شناسه جدول مسیریابی (Table ID)',
    'Rule Name': 'نام قانون',
    'Run Leak Self-Test': 'اجرای خودآزمایی نشت ترافیک',
    'Run simulated destination verification to test split-tunnel routing decisions, or export a safe, scrubbed diagnostics bundle for troubleshooting.': 'اجرای آزمایش شبیه‌سازی برای ارزیابی تصمیمات مسیریابی تونل، یا خروجی گرفتن از بسته عیب‌یابی پالایش‌شده جهت بررسی مشکلات.',
    'Save': 'ذخیره',
    'Save & Apply': 'ذخیره و اعمال',
    'Schedule (Cron):': 'زمان‌بندی (Cron):',
    'Search category (e.g. ir, apple)...': 'جستجوی دسته‌بندی (مانند ir یا apple)...',
    'Select GeoIP Country': 'انتخاب کشور (GeoIP)',
    'Select GeoSite Category': 'انتخاب دسته‌بندی دامنه (GeoSite)',
    'Server Endpoint': 'سرور مقصد',
    'Service Status': 'وضعیت سرویس',
    'Settings': 'تنظیمات',
    'Settings applied successfully.': 'تنظیمات با موفقیت اعمال گردید.',
    'Signature Verified ✔': 'امضای دیجیتال تایید شد ✔',
    'Simulate how incoming network and DNS requests for an IP or domain are routed.': 'شبیه‌سازی نحوه مسیریابی درخواست‌های شبکه و پرس‌وجوهای DNS برای یک IP یا دامنه خاص.',
    'Source:': 'منبع:',
    'Source: ': 'منبع: ',
    'Space-separated IP addresses or "auto" for WAN DHCP servers.': 'آدرس‌های IP که با فاصله جدا شده‌اند یا عبارت "auto" برای دریافت خودکار از DHCP اتصال WAN.',
    'Space-separated IP addresses or "pushed" to use server-pushed resolvers.': 'آدرس‌های IP که با فاصله جدا شده‌اند یا عبارت "pushed" برای استفاده از سرورهای اعلام‌شده توسط VPN.',
    'Space-separated list of firewall zones allowed forwarding into geovpn zone (default: lan).': 'لیست زون‌های فایروال مجاز برای ارسال ترافیک به زون geovpn (پیش‌فرض: lan).',
    'Space-separated list of inbound LAN interfaces subject to split-tunneling (default: br-lan).': 'لیست اینترفیس‌های ورودی LAN برای تونل‌بندی که با فاصله جدا شده‌اند (پیش‌فرض: br-lan).',
    'Specific CIDRs or domain names to override default split-tunnel decisions.': 'رنج‌های CIDR یا دامنه‌های خاص برای تغییر قوانین پیش‌فرض تونل‌بندی انتخابی.',
    'Specific LAN clients forced to always bypass or always use the VPN.': 'دستگاه‌های محلی خاص که ترافیک آنها همیشه مستقیم یا همیشه از طریق VPN هدایت می‌شود.',
    'Split Tunneling': 'تونل‌بندی انتخابی (Split Tunneling)',
    'Split Tunneling Configuration': 'پیکربندی تونل‌بندی انتخابی',
    'Split tunneling settings applied.': 'تنظیمات تونل‌بندی انتخابی اعمال گردید.',
    'Start': 'شروع',
    'Status': 'وضعیت',
    'Status: ': 'وضعیت: ',
    'Stop': 'توقف',
    'System & OpenVPN Logs': 'گزارش‌های سیستم و OpenVPN',
    'System Diagnostics Checklist': 'چک‌لیست عیب‌یابی سیستم',
    'Target / CIDR': 'مقصد / CIDR',
    'Target Route': 'مسیر خروجی',
    'Target Value': 'مقدار هدف',
    'Target value cannot be empty.': 'مقدار هدف نمی‌تواند خالی باشد.',
    'Test Route': 'آزمایش مسیر',
    'Test failed: ': 'آزمایش ناموفق بود: ',
    'Testing route simulator on sample targets…': 'در حال آزمایش شبیه‌ساز مسیر با مقاصد نمونه…',
    'Traffic (RX / TX)': 'ترافیک (دریافت / ارسال)',
    'Traffic destined for IP subnets belonging to these countries will match the policy.': 'ترافیک مقصدهای مربوط به زیرشبکه‌های IP این کشورها با این خط‌مشی مطابقت داده می‌شود.',
    'Treat RFC1918 / private networks as direct (recommended)': 'عبور مستقیم رنج‌های خصوصی و محلی RFC1918 (پیشنهادی)',
    'Tunnel Device': 'دستگاه تونل',
    'Type': 'نوع',
    'Update Now': 'به‌روزرسانی فوری',
    'Update Via:': 'به‌روزرسانی از طریق:',
    'Update started in background. Polling progress…': 'به‌روزرسانی در پس‌زمینه آغاز شد. دریافت وضعیت…',
    'Update successful ✔': 'به‌روزرسانی با موفقیت انجام شد ✔',
    'Updating: ': 'در حال به‌روزرسانی: ',
    'Upload File': 'بارگذاری فایل',
    'Uptime': 'مدت زمان اتصال',
    'User/Pass': 'نام‌کاربری/گذرواژه',
    'Username': 'نام کاربری',
    'VPN': 'VPN',
    'VPN Credentials': 'اطلاعات ورود VPN',
    'VPN DNS Servers': 'سرورهای DNS اتصال VPN',
    'VPN Only': 'فقط VPN',
    'VPN Only (Tunnel all traffic)': 'فقط VPN (ارسال کلیه ترافیک از طریق تونل)',
    'Warning': 'هشدار (Warning)',
    'Warnings Detected': 'هشدارهایی شناسایی شد',
    'e.g. Corp Wiki or NAS': 'مثلاً سامانه سازمانی یا NAS',
    'e.g. Living-room TV or Laptop': 'مثلاً تلویزیون هوشمند یا لپ‌تاپ',
    'e.g. aa:bb:cc:dd:ee:ff or 192.168.1.20': 'مثلاً aa:bb:cc:dd:ee:ff یا 192.168.1.20',
    'e.g. digikala.com or 1.1.1.1': 'مثلاً digikala.com یا 1.1.1.1',
    'e.g. wiki.corp.example or 203.0.113.0/24': 'مثلاً wiki.corp.example یا 203.0.113.0/24'
}

def escape_str(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def main():
    # 1. Collect all strings from codebase
    strings = set()
    for path in glob.glob(os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/htdocs/**/*.js'), recursive=True):
        content = open(path, encoding='utf-8').read()
        for m in re.findall(r'_\([\'\"](.*?)[\'\"]\)', content):
            strings.add(m)

    for path in glob.glob(os.path.join(REPO_ROOT, 'openwrt/luci-app-geovpn/root/**/*.json'), recursive=True):
        try:
            data = json.load(open(path, encoding='utf-8'))
            for k, v in data.items():
                if isinstance(v, dict) and 'title' in v:
                    strings.add(v['title'])
        except Exception:
            pass

    sorted_strings = sorted(strings)
    print(f'Total strings collected: {len(sorted_strings)}')

    # 2. Write geovpn.pot
    os.makedirs(os.path.dirname(POT_PATH), exist_ok=True)
    with open(POT_PATH, 'w', encoding='utf-8') as f:
        f.write('msgid ""\n')
        f.write('msgstr ""\n')
        f.write('"Content-Type: text/plain; charset=UTF-8\\n"\n')
        f.write('"Project-Id-Version: luci-app-geovpn 1.0\\n"\n')
        f.write('"Language-Team: GeoVPN Team\\n"\n')
        f.write('"Language: en\\n"\n')
        f.write('"MIME-Version: 1.0\\n"\n')
        f.write('"Content-Transfer-Encoding: 8bit\\n"\n\n')

        for s in sorted_strings:
            f.write(f'msgid "{escape_str(s)}"\n')
            f.write('msgstr ""\n\n')
    print(f'Wrote {POT_PATH}')

    # 3. Write geovpn.po (Persian)
    os.makedirs(os.path.dirname(PO_PATH), exist_ok=True)
    missing = []
    with open(PO_PATH, 'w', encoding='utf-8') as f:
        f.write('msgid ""\n')
        f.write('msgstr ""\n')
        f.write('"Content-Type: text/plain; charset=UTF-8\\n"\n')
        f.write('"Project-Id-Version: luci-app-geovpn 1.0\\n"\n')
        f.write('"Language-Team: Persian\\n"\n')
        f.write('"Language: fa\\n"\n')
        f.write('"MIME-Version: 1.0\\n"\n')
        f.write('"Content-Transfer-Encoding: 8bit\\n"\n')
        f.write('"Plural-Forms: nplurals=2; plural=(n > 1);\\n"\n\n')

        for s in sorted_strings:
            translation = TRANSLATIONS.get(s)
            if not translation:
                missing.append(s)
                translation = s  # fallback to untranslated if missing

            f.write(f'msgid "{escape_str(s)}"\n')
            f.write(f'msgstr "{escape_str(translation)}"\n\n')

    print(f'Wrote {PO_PATH}')
    if missing:
        print(f'WARNING: {len(missing)} missing translations: {missing[:5]}')
    else:
        print('SUCCESS: 100% translation coverage (0 missing strings)!')

if __name__ == '__main__':
    main()
