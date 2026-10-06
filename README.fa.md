<div dir="rtl">

# GeoVPN — کلاینت OpenVPN با تونل‌زنی تفکیکی جغرافیایی برای OpenWrt

[English](README.md) · [فارسی](README.fa.md)

GeoVPN روتر OpenWrt شما را به یک **کلاینت OpenVPN** تبدیل می‌کند که **فقط ترافیکِ انتخاب‌شده را از VPN عبور می‌دهد**.
در LuCI کشورها (GeoIP) و دسته‌های دامنه (GeoSite) را انتخاب می‌کنید: ترافیکِ منطبق **مستقیم** و از اینترنت عادی شما می‌رود و
بقیه **از طریق VPN** — یا برعکس. همه‌چیز از رابط وب مدیریت می‌شود، روی روترهای کم‌توان اجرا می‌شود و با یک دستور نصب می‌گردد.

> وضعیت: نسخهٔ ۱٫۰ · نیازمند **OpenWrt 25.12 یا جدیدتر** (مبتنی بر apk) · دستگاه اصلی آزمون: **Google WiFi (AC-1304)**

## امکانات
- چند پروفایل OpenVPN؛ **درون‌ریزی فایل `.ovpn`** (آپلود یا چسباندن) با مدیریت امن گواهی‌ها، کلیدها، `tls-crypt` و نام‌کاربری/گذرواژه.
- شروع/توقف/راه‌اندازی مجدد، وضعیت زنده (IP، مدت اتصال، ترافیک)، گزارش‌ها (لاگ)، اتصال مجدد خودکار، اجرا هنگام بوت.
- **تونل‌زنی تفکیکی جغرافیایی**: GeoIP و GeoSite، قوانین سفارشی IP/CIDR و دامنه، سیاست برای هر دستگاه (با IP یا MAC)، و عبور همیشه‌مستقیم برای آدرس سرور VPN (بدون حلقهٔ مسیریابی).
- دو حالت: **عبور مستقیمِ فهرست‌شده‌ها** (فهرست → مستقیم، بقیه → VPN) یا **فقط فهرست‌شده‌ها از VPN**.
- **DNS هم‌مسیر با ترافیک** (بدون نشت DNS برای دامنه‌های عبوری از VPN)، تغییر مسیر اجباری DNS و مسدودسازی DoT (اختیاری).
- پشتیبانی از IPv4 و IPv6 همراه با جلوگیری از نشت IPv6 وقتی VPN آن را ندارد.
- **کلید قطع (Kill Switch)** اختیاری: تا زمانی که تونل قطع است ترافیکِ مخصوص VPN مسدود می‌شود (ترافیک مستقیم دست‌نخورده می‌ماند).
- به‌روزرسانی انتخابی، امضاشده و اتمیک دادهٔ جغرافیایی با بازگشت خودکار در صورت خطا؛ حجم بسیار کم.
- رابط فارسی و انگلیسی با پشتیبانی راست‌به‌چپ.

## دستگاه‌ها و نسخه‌های پشتیبانی‌شده
- **OpenWrt 25.12.x** (با apk و nftables/fw4). نسخه‌های ۲۴٫۱۰ و قدیمی‌تر (opkg) پشتیبانی نمی‌شوند.
- دستگاه اصلی: **Google WiFi AC-1304** (زیرهدف `ipq40xx/chromium`، ۵۱۲ مگابایت RAM، ۴ گیگابایت eMMC).
- سایر دستگاه‌ها: بسته‌ها مستقل از معماری‌اند و روی دستگاه‌های ۲۵٫۱۲ با دست‌کم ۱۲۸ مگابایت RAM انتظار می‌رود کار کنند (بدون تضمین).

## چگونه کار می‌کند
```
                 ┌────────────── LAN clients ───────────────┐
                 │ DNS query                    traffic       │
                 ▼                                 ▼          │
          dnsmasq-full (router)              nftables "geovpn" table
   • geo domain list → which DNS to ask   • decides per connection: DIRECT or VPN
   • fills nft sets with the answers      • GeoIP lists + DNS-filled sets + your rules
                 │                                 │
        direct DNS ◄── listed domains    VPN-marked ─► routing table 4200 ─► tun (OpenVPN) ─► Internet
        VPN DNS    ◄── all others (bypass mode)      DIRECT ─────────────► WAN (normal route) ─► Internet
```
۱. حالت و فهرست‌ها را انتخاب می‌کنید (مثلاً GeoIP برابر `ir` و GeoSite برابر `category-ir`).
۲. dnsmasq برای دستگاه‌های شما دامنه‌ها را حل می‌کند و برای دامنه‌های فهرست‌شده **IPهای حاصل را به مجموعه‌های nftables اضافه می‌کند**.
۳. هر اتصال جدید یک بار طبقه‌بندی می‌شود (ترتیب: سرور VPN ← سیاست دستگاه ← قوانین شما ← شبکه‌های خصوصی ← GeoSite ← GeoIP ← پیش‌فرض).
۴. ترافیکِ علامت‌خورده برای VPN با مسیریابی سیاستی وارد تونل OpenVPN می‌شود؛ بقیه از مسیر عادی WAN می‌رود.
۵. پرس‌وجوهای DNS همان مسیرِ ترافیکِ خود را می‌پیمایند.

محدودیت‌ها: تطبیق دامنه بر پایهٔ پسوند است (dnsmasq)؛ قوانین `keyword` و `regexp` در GeoSite پشتیبانی نمی‌شوند.
دستگاه‌هایی که از DNS-over-HTTPS مستقل استفاده می‌کنند از DNS روتر عبور نمی‌کنند (بخش «نکات امنیتی»).

## پیش‌نیازها
- OpenWrt **25.12** با اینترنت فعال و دسترسی SSH.
- فضا: حدود ۱ مگابایت فلش و دست‌کم ۶۴ مگابایت RAM آزاد (فهرست‌های بزرگ کشورها بیشتر نیاز دارند؛ رابط تخمین را نشان می‌دهد).
- بستهٔ **`dnsmasq-full`** (نسخهٔ پیش‌فرض `dnsmasq` از `nftset` پشتیبانی نمی‌کند). برای جایگزینیِ امن، **ابتدا دانلود، سپس حذف**:

</div>

```sh
cd /tmp
apk update
apk fetch dnsmasq-full
apk del dnsmasq
apk add --allow-untrusted ./dnsmasq-full-*.apk
/etc/init.d/dnsmasq restart
dnsmasq --version | head -3      # باید nftset را نشان دهد
```

<div dir="rtl">

## نصب
### روش الف) از مخزن بسته‌ها (پیشنهادی، با SSH)

</div>

```sh
wget -O /etc/apk/keys/geovpn.pem https://geovpn.github.io/geovpn/keys/geovpn.pem
echo /etc/apk/keys/geovpn.pem >> /etc/sysupgrade.conf
echo 'https://geovpn.github.io/geovpn/25.12/packages.adb' > /etc/apk/repositories.d/geovpn.list
apk update
apk add geovpn
```

<div dir="rtl">

### روش ب) از LuCI
مسیر *System → Software* ← **Update lists** ← جست‌وجوی `geovpn` ← نصب. (افزودن مخزن و کلید فقط یک بار و از طریق SSH انجام می‌شود.)

### روش ج) از فایل آمادهٔ انتشار
فایل‌های `.apk` و `SHA256SUMS` را از صفحهٔ Release دریافت کنید، سپس:

</div>

```sh
cd /tmp
sha256sum -c SHA256SUMS
apk add --allow-untrusted ./geovpn-core-*.apk ./luci-app-geovpn-*.apk ./luci-i18n-geovpn-fa-*.apk ./geovpn-*.apk
```

<div dir="rtl">

گزینهٔ `--allow-untrusted` بررسی امضا را کنار می‌گذارد؛ فقط برای فایل‌هایی استفاده کنید که جمع‌کنترلشان را تأیید کرده‌اید.

**بررسی نصب:** `geovpn version && geovpn diag` — سپس در LuCI به مسیر **VPN ← GeoVPN** بروید.

## راه‌اندازی نخست
۱. تب **Connections** ← **Import** ← فایل `.ovpn` را انتخاب یا الصاق کنید. گزارش درون‌ریزی را بخوانید؛ در صورت نیاز **Credentials** را وارد کنید و **Make active** را بزنید.
۲. تب **Split Tunneling** ← **Enable** را فعال کنید، حالت را انتخاب کنید و با **Add…** مقادیر GeoIP (مثلاً `ir` و `private`) و GeoSite (مثلاً `category-ir`) را اضافه کنید.
۳. **Update now** را بزنید (دانلود نخست؛ چند صد کیلوبایت) و تا نشانهٔ سبز صبر کنید.
۴. **Save & Apply** و سپس در تب Connections دکمهٔ **Start**. وضعیت باید **Connected** شود.
۵. آزمون از یک دستگاه شبکهٔ محلی:

</div>

```sh
curl -s https://ifconfig.me ; echo      # در حالت عبور مستقیم: IP سرور VPN برای سایت‌های خارج از فهرست
```

<div dir="rtl">

و روی روتر: `geovpn test example.com` (باید VPN باشد) و `geovpn test <دامنهٔ-فهرست‌شده>` (باید DIRECT باشد). همین آزمون در LuCI با کادر «Test a domain or IP» هم موجود است.

## تنظیمات (`/etc/config/geovpn`)
گزینه‌های مهم بخش `main`: `enabled`، `active_profile`، `mode` (‏`bypass` یا `include`)، `split_enabled`، `private_direct`، `ipv6` (‏`auto|block|vpn|direct`)،
`kill_switch`، `router_traffic`، `lan_ifs`، `dns_direct_servers`، `dns_vpn_servers`، `dns_hijack`، `block_dot`، `block_doh`، `dyn_timeout`، `max_cidrs`، `max_domains`.
فهرست کامل با مقادیر پیش‌فرض در نسخهٔ انگلیسی README (بخش Configuration reference) آمده است. پس از تغییر: `/etc/init.d/geovpn reload`.

## نمونه‌های کاربرد
- **IP و دامنه‌های ایرانی مستقیم، بقیه از VPN:** حالت «Bypass listed»؛ GeoIP: ‏`ir` و `private`؛ GeoSite: ‏`category-ir`.
- **فقط سرویس‌های پخش ویدیو از VPN:** حالت «Only listed via VPN»؛ دسته‌های GeoSite مرتبط را از فهرست انتخاب کنید.
- **یک دستگاه خارج از VPN:** *Client policies* ← افزودن MAC دستگاه ← **Direct only**.
- **حداکثر حریم خصوصی:** کلید قطع را روشن نگه دارید، «DNS hijack» و «Block DoT» روشن، و IPv6 روی *Auto*.

## به‌روزرسانی، ارتقا و حذف
- **داده:** *Update now* یا `geovpn update`؛ به‌روزرسانی خودکار روزانه فعال است. هر به‌روزرسانی با امضا و هش بررسی و به‌صورت اتمیک نصب می‌شود؛ در صورت خطا به نسخهٔ قبل بازمی‌گردد.
- **ارتقای بسته:** `apk update && apk upgrade geovpn geovpn-core luci-app-geovpn`.
- **Sysupgrade:** فایل `/etc/config/geovpn` و پوشهٔ `/etc/geovpn/profiles` (شامل کلیدهای VPN شما) با گزینهٔ «حفظ تنظیمات» نگه داشته می‌شوند. دادهٔ جغرافیایی دوباره دانلود می‌شود. کلید مخزن را در `/etc/sysupgrade.conf` بیفزایید.
- **حذف:** `apk del geovpn luci-app-geovpn geovpn-core`؛ برای پاک‌سازی کامل تنظیمات: `geovpn purge`.

## رفع اشکال
- **منو در LuCI نیست:** ‏`/etc/init.d/rpcd restart` و خروج/ورود دوباره.
- **GeoSite کار نمی‌کند:** ‏`dnsmasq-full` نصب نیست؛ بخش پیش‌نیازها.
- **پس از Start اینترنت قطع شد:** ‏`geovpn panic` همهٔ قوانین را برمی‌دارد؛ سپس `geovpn diag`. با کلید قطعِ روشن و تونلِ قطع، ترافیک مخصوص VPN عمداً مسدود است.
- **همه‌چیز مستقیم می‌رود:** ‏`ip rule show` و `ip route show table 4200` را ببینید؛ حالت (bypass/include) را بررسی کنید.
- **همه‌چیز از VPN می‌رود:** داده دانلود نشده (Update now) یا دستگاه از DNS خودش/DoH استفاده می‌کند.
- **نشت DNS:** «DNS hijack» را روشن نگه دارید و «Secure DNS» مرورگر را خاموش کنید.
- **مشکل TUN:** ‏`apk add kmod-tun` و `ls /dev/net/tun`.

## نکات امنیتی
- فایل `.ovpn` با **فهرست مجاز** تحلیل می‌شود؛ دستورهای اجرای اسکریپت/افزونه/مدیریت/لاگ حذف می‌شوند. کلیدها و گذرواژه‌ها فقط در `/etc/geovpn/profiles` (فقط root، دسترسی ۰۶۰۰) ذخیره می‌شوند و در رابط یا لاگ دیده نمی‌شوند.
- پشتیبان‌گیری سیستم شامل کلیدهای VPN شماست؛ آن را امن نگه دارید.
- DoH به میزبان‌های دلخواه را نمی‌توان کاملاً مسدود کرد.

## عملکرد (AC-1304)
OpenVPN در فضای کاربر و روی پردازندهٔ ۷۱۶ مگاهرتزی اجرا می‌شود؛ سرعت عبور از تونل در حد **چند ده مگابیت بر ثانیه** است. ترافیک مستقیم تحت‌تأثیر نیست.

## پرسش‌های متداول
- **آیا WireGuard پشتیبانی می‌شود؟** در نسخهٔ ۱ خیر. **دو VPN هم‌زمان؟** خیر (یک تونل فعال).
- **آیا تبلیغ‌ها را مسدود می‌کند؟** خیر؛ دسته‌های تبلیغاتی فقط «مسیریابی» می‌شوند.

## مشارکت و مجوز
مشارکت با Issue و Pull Request خوش‌آمد است؛ ابتدا `PLAN.md` و `DECISIONS.md` را بخوانید. ترجمه‌ها در `po/fa/geovpn.po`. مجوز کد: Apache-2.0؛ مجوز دادهٔ جغرافیایی در پوشهٔ `LICENSES/` بستهٔ داده.

</div>
