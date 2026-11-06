# Changelog

## 1.1.2

- Avoided stack exhaustion and large temporary allocations while cleaning deep or busy cache trees.
- Limited installer output kept in memory and validated IPA inputs before launching an installer.
- Present the IPA confirmation after the file picker has finished dismissing.
- Cleaner scans now respect cancellation while measuring directory contents.

## 1.1.1

- Fixed a crash after installing an IPA: the app list is now re-read in the background, and errors thrown by LaunchServices for apps that are still being installed are caught instead of closing Xixu.
- The confirmation for "Install IPA…" appears only after the file picker has closed.

## 1.1.0

- Tabs in the Files tab: open folders in new tabs, switch with a tap or a swipe on the tab bar, tabs are restored on launch.
- New Search tab: search the whole device, Mobile, the jailbreak or app containers; recent searches.
- The search bar in every folder is always visible.
- New Tools tab with a Cleaner (app caches, temporary files, Safari/WebKit, crash logs, logs, package downloads), Wi-Fi Transfer and IPA installation.
- Wi-Fi Transfer: browse, upload (drag and drop), download, create folders and delete in any browser, protected by a one-time code.
- Install .ipa files with TrollStore, TrollStore Lite or appinst.
- Apps: back up and restore app data (including app groups), export as IPA, change the Home Screen name.
- Saving Info.plist or InfoPlist.strings inside an app now refreshes the app so changes show up.
- New design: drawn file icons with type labels, colored icons in lists, real app icons.
- Apps tab no longer crashes when loading icons.

## 1.0.0

- First release: root file browser for rootless and roothide (iOS 15–26).
- Copy, cut, paste (also as symbolic link), duplicate, rename, compress, extract, share, import from Files and Photos.
- Trash with undo and Put Back; protected system folders can't be deleted or moved.
- Recursive search by name, wildcard or regular expression.
- Info sheet with folder sizes, owner/group, permission grid and checksums.
- Text editor, hex editor, property list editor, SQLite browser, Mach-O inspector with entitlements, archive and .deb viewer, Quick Look.
- Apps tab with bundle, data and group containers.
- English and German.
