<div align="center">
  <img src=".github/assets/icon.png" width="112" alt="Xixu app icon">
  <h1>Xixu</h1>
  <p><strong>File management for the iPhone you actually own.</strong></p>
  <p>A native file manager for rootless and roothide jailbreaks. Browse, move, inspect, edit, and recover files without leaving the app.</p>
  <p>
    <a href="../../releases/latest"><img alt="Version 1.1.5" src="https://img.shields.io/badge/release-v1.1.5-5b5bd6?style=flat-square"></a>
    <img alt="iOS 15–26" src="https://img.shields.io/badge/iOS-15%E2%80%9326-111827?style=flat-square">
    <img alt="Rootless and roothide" src="https://img.shields.io/badge/jailbreak-rootless%20%7C%20roothide-5058a5?style=flat-square">
    <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-2e7d65?style=flat-square"></a>
  </p>
  <p><a href="../../releases/latest"><strong>Download Xixu</strong></a> · <a href="#what-you-can-do">Explore features</a> · <a href="#build-it-yourself">Build it yourself</a></p>
</div>

---

You know the moment: you need one preference file, one app container, or one log, and suddenly you're hopping between tools. Xixu keeps those jobs in one place. It uses familiar iOS controls, opens the whole filesystem through a short-lived root helper, and gets out of your way when you close it.

## Get started

1. Open the [latest release](../../releases/latest).
2. Pick the package for your jailbreak:

   | Your setup | Package |
   | --- | --- |
   | Dopamine, palera1n rootless, nathanlr | `xixu_<version>_rootless_iphoneos-arm64.deb` |
   | roothide Bootstrap | `xixu_<version>_roothide_iphoneos-arm64e.deb` |

3. Install the `.deb` with Sileo, Zebra, or another package manager, then open **Xixu**.

Xixu targets iOS 15–26. IPA installation needs TrollStore/TrollStore Lite or `appinst` with AppSync Unified. Xixu checks GitHub Releases for its own updates and can install the matching verified `.deb` from **Settings → Software Update**.

## What you can do

| | |
| --- | --- |
| **Find your way around** | Browse as root, jump to a path, keep favorites, use multiple folder tabs, and search by text, wildcard, or regular expression. Double tap **Files** to return to its home page. App containers show names and icons alongside their UUIDs. |
| **Move things confidently** | Copy, cut, paste, duplicate, rename, link, import, and share. Choose what happens when names collide. Trash supports Undo and Put Back. |
| **Open almost anything** | Preview media and documents; inspect archives, Debian packages, Mach-O binaries, SQLite databases, and property lists. Edit text and bytes in place. |
| **Handle the tedious jobs** | Clean caches and logs, transfer files over Wi-Fi with a one-time code, install IPA/TIPA files, back up app data, and export apps as IPA. |

The little details matter too: folders stay on top if you want them to, hidden files are a toggle, long operations show progress, and the helper runs only while Xixu is open. When a new version is available, a small in-app notice takes you straight to the updater.

### A few guardrails

Xixu blocks accidental removal or replacement of critical system folders, including `/`, `/System`, `/var/mobile`, and the jailbreak root. Files *inside* those folders remain editable. Items on another volume cannot go to Xixu's Trash; Xixu asks before deleting them permanently.

Root access is powerful. Double-check paths before changing permissions, restoring app data, or deleting files.

## How Xixu works

```text
Xixu.app (mobile)                  xixuhelper (root)
    UIKit + file browser  ── requests ──▶  filesystem engine
                         ◀─ results ────  copy · trash · search · archives
```

The app sends JSON messages through pipes to a small helper launched with root privileges. The helper accepts Xixu as its parent and exits with the app. If it is unavailable, Xixu still opens with the permissions of the `mobile` user and shows that access is limited. There is no persistent background daemon.

## Build it yourself

You'll need [Theos](https://theos.dev) with Swift support. Use roothide Theos for the roothide package.

```sh
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
python3 scripts/check_strings.py
```

The GitHub Actions workflow builds both packages and attaches them to a release when `main` receives a new version. Source lives in `app/`, `helper/`, and `Shared/`.

## Something went wrong?

If Xixu closes during an operation, please include **when** it happened (before, during, or after the progress indicator), your iOS version, jailbreak, installer used, and whether the target app appeared on the Home Screen. An Xixu `.ips` crash report from **Settings → Privacy & Security → Analytics & Improvements → Analytics Data** is especially useful. You can [open an issue](../../issues/new) or share the report privately with the maintainer.

## License

MIT. See [LICENSE](LICENSE).
