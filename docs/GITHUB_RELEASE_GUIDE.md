# راهنمای جامع انتشار نسخه در گیت‌هاب و ساخت بسته‌ها
# GeoVPN GitHub Release & Automated Packaging Guide

این راهنما فرآیند کامل انتشار نسخه‌های جدید GeoVPN را به دو زبان فارسی و انگلیسی تشریح می‌کند. با دنبال کردن این گام‌ها، بسته‌های سیستم‌عامل OpenWrt (`.apk`) به صورت خودکار توسط GitHub Actions کامپایل شده و در بخش Releases گیت‌هاب منتشر می‌شوند تا کاربران روتر بتوانند تنها با یک کلیک از طریق رابط کاربری وب (LuCI) برنامه را به‌روزرسانی کنند.

This guide outlines the end-to-end release process for GeoVPN in Persian and English. Following these steps ensures OpenWrt `.apk` packages are automatically built by GitHub Actions and published as GitHub Releases, enabling one-click in-app updates for router users via the LuCI web interface.

---

## فهرست مطالب / Table of Contents
1. [نمای کلی چرخه انتشار / Release Pipeline Overview](#1-release-pipeline-overview)
2. [گام ۱: ارتقای شماره نسخه در فایل‌های Makefile / Step 1: Bump PKG_VERSION in Makefiles](#2-step-1-bump-pkg_version-in-makefiles)
3. [گام ۲: به‌روزرسانی گزارش تغییرات و ثبت در گیت / Step 2: Update Changelog & Commit](#3-step-2-update-changelog--commit)
4. [گام ۳: ایجاد و ارسال برچسب گیت / Step 3: Create & Push Git Tag](#4-step-3-create--push-git-tag)
5. [گام ۴: فرآیند خودکار ساخت در GitHub Actions / Step 4: GitHub Actions Automation](#5-step-4-github-actions-automation)
6. [گام ۵: تنظیم دسترسی‌های مخزن گیت‌هاب (بسیار مهم) / Step 5: Required GitHub Permissions](#6-step-5-required-github-permissions)
7. [گام ۶: بررسی و نصب آپدیت در روتر / Step 6: Verification & Router Update](#7-step-6-verification--router-update)
8. [عیب‌یابی مشکلات رایج / Troubleshooting](#8-troubleshooting)

---

## 1. Release Pipeline Overview / نمای کلی چرخه انتشار

```text
[توسعه و تغییرات / Code Changes]
          │
          ▼
[ارتقای PKG_VERSION در Makefileها / Bump PKG_VERSION]
          │
          ▼
[ثبت کامیت و برچسب نسخه / Git Commit & Tag: v1.1.x]
          │
          ▼
[ارسال به گیت‌هاب / Git Push to GitHub]
          │
          ▼
[اجرای GitHub Actions Release Workflow]
  ├── ۱. دریافت OpenWrt SDK رسمی 25.12
  ├── ۲. کامپایل بسته‌ها: geovpn-core, luci-app-geovpn, geovpn-ikev2, ...
  ├── ۳. امضا و تولید آرشیو بسته‌های APK
  └── ۴. ایجاد GitHub Release و آپلود فایل‌های .apk و SHA256SUMS
          │
          ▼
[تشخیص نسخه جدید در روتر / In-App Notification in LuCI]
          │
          ▼
[به‌روزرسانی با یک کلیک در پنل تنظیمات / One-Click Update Now]
```

---

## 2. Step 1: Bump PKG_VERSION in Makefiles / گام ۱: ارتقای شماره نسخه در Makefileها

### فارسی:
برای انتشار هر نسخه جدید (مثلاً ارتقا از `1.1.0` به `1.1.1`)، متغیر `PKG_VERSION` در فایل‌های `Makefile` تمام بسته‌های GeoVPN باید به‌روزرسانی شود. بسته‌های نسخه جدید عبارتند از:

### English:
For every new release (e.g. from `1.1.0` to `1.1.1`), update the `PKG_VERSION` variable in the `Makefile` of all GeoVPN packages. The package Makefiles are:

1. `openwrt/geovpn/Makefile`
2. `openwrt/geovpn-core/Makefile`
3. `openwrt/geovpn-wireguard/Makefile`
4. `openwrt/geovpn-ikev2/Makefile`
5. `openwrt/geovpn-full/Makefile`
6. `openwrt/luci-app-geovpn/Makefile`

*(نکته: بسته `geovpn-data-seed/Makefile` مربوط به داده‌های اولیه آفلاین بوده و نسخه آن معمولاً نیازی به تغییر ندارد مگر داده‌های آفلاین تغییر کرده باشند).*

### مثال تغییر / Example Diff:
```diff
-PKG_VERSION:=1.1.0
+PKG_VERSION:=1.1.1
-PKG_RELEASE:=1
+PKG_RELEASE:=1
```

می‌توانید با دستور سریع زیر نسخه را در تمام فایل‌ها تغییر دهید:
```bash
sed -i 's/PKG_VERSION:=1.1.0/PKG_VERSION:=1.1.1/g' openwrt/*/Makefile
```

همچنین در فایل `openwrt/geovpn-core/files/usr/share/ucode/geovpn/cli.uc` و افزونه `geovpn.uc`، شماره نسخه پیش‌فرض را در صورت نیاز به‌روزرسانی کنید.

---

## 3. Step 2: Update Changelog & Commit / گام ۲: به‌روزرسانی گزارش تغییرات و ثبت در گیت

### فارسی:
تغییرات و قابلیت‌های جدید نسخه جدید را در فایل `CHANGELOG.md` یادداشت کرده و تغییرات را در شاخه اصلی کامیت کنید:

### English:
Document the changes, fixes, and features in `CHANGELOG.md` and commit the bumped version files:

```bash
# بررسی وضعیت تغییرات / Check modified files
git status

# افزودن فایل‌های ویرایش‌شده / Stage modified files
git add openwrt/*/Makefile CHANGELOG.md

# ثبت کامیت با پیام استاندارد / Commit with a standard message
git commit -m "chore(release): bump version to 1.1.1"

# ارسال به گیت‌هاب / Push to GitHub repository
git push origin main
```

---

## 4. Step 3: Create & Push Git Tag / گام ۳: ایجاد و ارسال برچسب گیت

### فارسی:
فرآیند ساخت و انتشار خودکار GitHub Actions با ایجاد برچسبی (Git Tag) که با حرف `v` آغاز شود فعال می‌شود (مانند `v1.1.1`). برچسب را ایجاد و به سرور گیت‌هاب ارسال کنید:

### English:
The GitHub Actions release workflow is automatically triggered when a Git tag starting with `v` is pushed (such as `v1.1.1`). Create and push the release tag:

```bash
# ایجاد برچسب محلی همراه با یادداشت / Create annotated tag
git tag -a v1.1.1 -m "Release v1.1.1: IKEv2 manual entry, bilingual Persian/English UI, and GitHub updater"

# ارسال تگ به گیت‌هاب / Push tag to remote GitHub repository
git push origin v1.1.1
```

اگر نیاز به حذف یا اصلاح تگ داشتید:
```bash
# حذف تگ محلی و راه دور در صورت لزوم / Delete local and remote tag if needed
git tag -d v1.1.1
git push origin :refs/tags/v1.1.1
```

---

## 5. Step 4: GitHub Actions Automation / گام ۴: فرآیند خودکار ساخت در GitHub Actions

### فارسی:
به محض ارسال تگ، فایل ورک‌فلو `.github/workflows/release.yml` اجرا می‌شود. مراحل اجرای آن به شرح زیر است:
1. **دانلود رسمی OpenWrt SDK**: نسخه مناسب برای پردازنده و تارگت موردنظر (مثلاً OpenWrt 25.12) دریافت و بازگشایی می‌شود.
2. **کامپایل بسته‌ها**: اسکریپت `tools/build-sdk.sh` تمام بسته‌ها را با معماری `all` کامپایل کرده و فایل‌های خروجی `.apk` را در پوشه `out/` ذخیره می‌کند:
   - `geovpn-core_1.1.1-r1.apk`
   - `luci-app-geovpn_1.1.1-r1.apk`
   - `geovpn-ikev2_1.1.1-r1.apk`
   - `geovpn-wireguard_1.1.1-r1.apk`
   - `geovpn_1.1.1-r1.apk`
   - `geovpn-full_1.1.1-r1.apk`
3. **ساخت مخزن APK و فایل هش**: اسکریپت `tools/mk-feed.sh` مخزن بسته را همراه با `packages.adb` و چک‌سام‌های `SHA256SUMS` تولید می‌کند.
4. **انتشار در Releases**: اکشن `softprops/action-gh-release` ریلیز جدید را در صفحه گیت‌هاب ایجاد کرده و فایل‌های `.apk` و متادیتا را به عنوان Asset ضمیمه می‌کند.
5. **انتشار در GitHub Pages**: فید بسته‌ها به شاخه `gh-pages` برای نصب مستقیم کلاینت‌ها ارسال می‌شود.

---

## 6. Step 5: Required GitHub Permissions / گام ۵: تنظیم دسترسی‌های مخزن گیت‌هاب (بسیار مهم)

### فارسی:
**توجه بحرانی:** به طور پیش‌فرض، مخازن جدید گیت‌هاب دسترسی ابزار Actions را به صورت **فقط خواندنی (Read-only)** تنظیم می‌کنند. اگر این دسترسی باز نشود، هنگام تلاش برای ایجاد ریلیز و آپلود فایل‌های `.apk`، با خطای زیر مواجه خواهید شد:
```text
HTTP 403: Resource not accessible by integration
```

برای رفع این مشکل، حتماً یک‌بار مراحل زیر را در وب‌سایت گیت‌هاب انجام دهید:

1. به صفحه مخزن خود در گیت‌هاب بروید: `https://github.com/SadraSaad/GeoVPN`
2. بر روی زبانه **Settings** (تنظیمات مخزن) در بالای صفحه کلیک کنید.
3. در منوی سمت چپ، روی گزینه **Actions** و سپس زیرگزینه **General** کلیک کنید.
4. به پایین صفحه بخش **Workflow permissions** بروید.
5. گزینه **Read and write permissions** را انتخاب کنید.
6. تیک گزینه **Allow GitHub Actions to create and approve pull requests** را بزنید.
7. روی دکمه سبز رنگ **Save** کلیک کنید.

علاوه بر این، در فایل ورک‌فلو `.github/workflows/release.yml` نیز دسترسی‌ها به صراحت تعریف شده‌اند:
```yaml
permissions:
  contents: write
  pages: write
  id-token: write
```

### English:
**CRITICAL REQUIREMENT:** By default, newly created GitHub repositories grant GitHub Actions tokens **Read-only** permissions. Without write permissions, the release job will fail with:
```text
HTTP 403: Resource not accessible by integration
```

To enable release publishing permissions on GitHub:
1. Navigate to your repository: `https://github.com/SadraSaad/GeoVPN`
2. Click **Settings** (top navigation bar).
3. In the left sidebar, click **Actions** -> **General**.
4. Scroll down to the **Workflow permissions** section.
5. Select **Read and write permissions**.
6. Check **Allow GitHub Actions to create and approve pull requests**.
7. Click the green **Save** button.

---

## 7. Step 6: Verification & Router Update / گام ۶: بررسی و نصب آپدیت در روتر

### فارسی:
پس از اتمام موفقیت‌آمیز Actions در گیت‌هاب، روترهایی که نرم‌افزار GeoVPN روی آن‌ها نصب است به راحتی آپدیت می‌شوند:

1. وارد پنل وب روتر OpenWrt شوید: `LuCI -> VPN -> GeoVPN -> Settings (تنظیمات)`.
2. به بخش **«به‌روزرسانی و نسخه» (Updates & Version)** بروید.
3. روی دکمه **«بررسی بروزرسانی» (Check for Updates)** کلیک کنید.
4. سیستم به طور مستقیم آخرین نسخه را از API گیت‌هاب (`/releases/latest`) استعلام می‌کند.
5. در صورت وجود نسخه جدید:
   - شماره نسخه و یادداشت انتشار (Changelog) نمایش داده می‌شود.
   - دکمه سبز رنگ **«به‌روزرسانی خودکار» (Update Now)** فعال می‌شود.
6. با کلیک بر روی «به‌روزرسانی خودکار»:
   - روتر بسته‌های مربوطه (`geovpn-core`, `luci-app-geovpn` و درایورهای نصب‌شده) را دانلود می‌کند.
   - دستور `apk add --allow-untrusted` اجرا می‌شود.
   - سرویس‌های وب و مسیریابی (`rpcd`, `uhttpd`, `dnsmasq`) ری‌استارت می‌شوند.
   - صفحه پس از ۳ ثانیه مجدداً بارگذاری شده و نسخه جدید فعال می‌شود.

### دستور دستی از طریق ترمینال روتر (در صورت تمایل) / Manual CLI Upgrade:
```bash
# دانلود آخرین بسته و ارتقا / Download and upgrade manually
cd /tmp
wget https://github.com/SadraSaad/GeoVPN/releases/latest/download/geovpn-core_1.1.1-r1.apk
wget https://github.com/SadraSaad/GeoVPN/releases/latest/download/luci-app-geovpn_1.1.1-r1.apk
apk add --allow-untrusted ./geovpn-core_*.apk ./luci-app-geovpn_*.apk
/etc/init.d/rpcd restart && /etc/init.d/uhttpd restart
```

---

## 8. Troubleshooting / عیب‌یابی مشکلات رایج

| مشکل / Issue | دلیل / Cause | راه‌حل / Solution |
|---|---|---|
| **HTTP 403 در Actions** | دسترسی نوشتن برای توکن GITHUB_TOKEN فعال نیست. | در Settings -> Actions -> General گزینه Read and write permissions را انتخاب کنید. |
| **ورک‌فلو اجرا نمی‌شود** | تگ گیت فاقد پیشوند `v` است. | تگ باید حتماً با فرمت `v*` باشد (مانند `v1.1.1` نه `1.1.1`). |
| **خطای محدودیت گیت‌هاب در روتر (Rate Limit)** | ارسال بیش از ۶۰ درخواست در ساعت از یک آدرس IP به API گیت‌هاب بدون توکن. | چند دقیقه صبر کرده یا مستقیماً از صفحه Releases فایل‌ها را دانلود کنید. |
| **خطای عدم تطابق هش بسته APK** | دانلود ناقص فایل در اینترنت‌های ناپایدار. | روی دکمه بررسی بروزرسانی مجدداً کلیک کنید یا با ترمینال دستی امتحان نمایید. |
