<p align="center">
  <img src=".github/assets/icon.png" width="112" alt="Xixu icon">
</p>

<h1 align="center">Xixu</h1>

<p align="center">A fast, clean root file manager for rootless and roothide jailbreaks.<br>iOS 15 – 26 · about 440 KB · no background daemon</p>

---

Xixu is a native UIKit file manager that sees the whole file system as root. It is built to feel like a first-party app: system fonts and colors, real context menus, swipe actions, multi-select with two fingers, and nothing that runs when the app is closed.

## Features

**Browse**
- The whole file system as root, through a small helper that only lives while Xixu is open
- App names and icons instead of UUIDs in `Containers/Data/Application`, `Bundle/Application` and app group folders
- Title menu with every parent folder, **Go to Folder** with autocomplete, Favorites and Recent files
- Sort by name, date, size or kind, folders on top, hidden files on/off, thumbnails, optional permissions and owner in the list
- Quick Look for images, video, audio, PDF and documents, with swiping between files

**Organize**
- Copy, cut and paste from a floating shelf that stays while you move between folders; **paste as symbolic link**
- Duplicate, rename, new file / folder / symbolic link, import from Files and Photos, share
- Name conflicts: keep both, replace or skip
- **Trash** with Undo and Put Back (items on other volumes are deleted after asking)
- Protected system folders (`/`, `/System`, `/var/mobile`, the jailbreak root, …) can't be deleted, moved or renamed by accident; everything inside them stays editable

**Tabs**
- Several folder tabs in the Files tab with a sliding tab bar; swipe it to switch, long-press a tab to duplicate or close
- "Open in New Tab" for any folder; tabs come back after a relaunch

**Search**
- Search the current folder instantly or all subfolders, streamed as results arrive
- Plain text, wildcards (`*.dylib`) or regular expressions (`/^com\..*\.plist$/`)
- A Search tab for the whole device, Mobile, the jailbreak or app containers, with recent searches

**Tools**
- Cleaner for app caches, temporary files, Safari/WebKit caches, crash logs, logs and package downloads
- Wi-Fi Transfer: browse, upload with drag and drop, download, create folders and delete from any browser, protected by a one-time code
- Install `.ipa` / `.tipa` with TrollStore, TrollStore Lite or appinst

**Inspect and edit**
- Info sheet: folder size on demand, dates, owner and group, a permission grid with setuid / setgid / sticky, recursive apply, MD5 / SHA-1 / SHA-256
- Text editor with encoding detection, Find & Replace (iOS 16+), Go to Line, atomic saves that keep owner and permissions
- Hex viewer and byte editor for files of any size
- Property list editor: browse and edit the tree, change types, add, rename, duplicate, save as XML or binary
- SQLite browser on a private copy (the original database is never touched), with a query console
- Mach-O inspector: architectures, linked libraries, run paths, encryption, build version, code signature, Team ID and **entitlements**

**Archives and packages**
- Extract ZIP, TAR, GZ, BZ2, XZ, 7z, RAR, CPIO, ISO, AR and more; compress to ZIP
- `.deb` viewer with control fields and file list; install through APT with dependency resolution
- Respring and icon cache refresh

**Apps**
- All installed apps with bundle, data and app group containers, Info.plist, preferences and entitlements one tap away
- Back up and restore app data (app groups included), export apps as IPA, change an app's Home Screen name

## Install

Download the package for your jailbreak from [Releases](../../releases) and open it in Sileo, Zebra or Filza:

| Package | Jailbreak |
|---|---|
| `xixu_<version>_rootless_iphoneos-arm64.deb` | Dopamine, palera1n rootless, nathanlr |
| `xixu_<version>_roothide_iphoneos-arm64e.deb` | roothide Bootstrap |

## How it works

```
Xixu.app (mobile, unsandboxed)          xixuhelper (root)
  FS client  ── JSON lines over pipes ──►  Engine (listing, copy, trash, search, archives …)
```

The app spawns `xixuhelper` with the root persona (falling back to its setuid bit) and keeps it for the session. The helper only accepts the installed Xixu app as its parent and exits when the app closes its pipe. Without the helper, the same engine runs inside the app with the permissions of `mobile`.

## Building

Requires [Theos](https://theos.dev) with Swift support (roothide Theos for the roothide package).

```sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
python3 scripts/check_strings.py   # every string has a German translation
```

Every push to `main` builds both packages on GitHub Actions and publishes a release for the version in `control`.

## License

MIT
