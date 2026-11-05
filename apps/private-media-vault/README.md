# Private Media Vault

An original SwiftUI iPhone app and a portable Swift package for keeping personal
photos and videos encrypted on the device. It lives in this directory of a REA
checkout and is not part of REA. It does not change REA's CLI, MCP tools,
packages, or providers.

The feature list was taken from the public App Store description of Private
Photo Vault - Pic Safe
(<https://apps.apple.com/au/app/private-photo-vault-pic-safe/id417571834>):
albums, import and export of photos and videos, a gallery, and video playback.
This app does not copy that product's name, icon, copy, or code. It does not
implement a decoy calculator, a decoy password, a break-in report, ads, a
subscription, or a private browser.

This is not a security audit and it is not production-ready. The portable tests
below ran on Linux. They do not exercise Apple's frameworks.

## Where the code is

| Path                                                       | What it is                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------ |
| `apps/private-media-vault/Package.swift`                   | Swift package for `VaultCore`                                      |
| `apps/private-media-vault/Sources/VaultCore/`              | Encryption, catalog, import, backup, lock policy, assistant policy |
| `apps/private-media-vault/Tests/VaultCoreTests/`           | XCTest suite for that package                                      |
| `apps/private-media-vault/ios/PrivateMediaVault.xcodeproj` | iPhone app project. One app target. No share extension             |
| `apps/private-media-vault/ios/PrivateMediaVault/`          | SwiftUI app                                                        |
| `apps/private-media-vault/ios/ShareExtension/`             | Unused extension source. Not signed                                |
| `apps/private-media-vault/Package.resolved`                | Pins swift-crypto 5.1.1 and swift-asn1 1.7.4                       |

## What a 2016 Mac and a Windows PC can and cannot do

Checked against Apple's pages on 5 November 2026:

- Xcode 26 requires macOS Sequoia 15.6 or later and includes the iOS 26 SDK
  (<https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes>).
- The Xcode system-requirements table also lists Xcode 27 as requiring macOS
  Tahoe 26.6 or later
  (<https://developer.apple.com/xcode/system-requirements/>).
- iPhone 17, 17 Pro, and 17 Pro Max are iOS 26 devices
  (<https://support.apple.com/en-us/123705>). If the phone has since been
  updated, the installed iOS version decides which Xcode you need.
- A 2016 Intel Mac's last official system is macOS Monterey 12.7.x. Monterey
  cannot run Xcode 26 or 27. The last Xcode that runs on Monterey is Xcode
  14.2, whose SDK is iOS 16.2. That SDK cannot deploy to an iPhone 17.
- Windows 11 has no official Xcode. This cloud run did not copy files onto the
  Ally, did not sign anything, and did not install anything on the phone.
- No Apple ID was created or changed. No paid Developer Program enrollment is
  required by this project, and none was purchased. Unsupported OS patchers are
  not a supported path.

Supported install, once you have a Mac that Apple lists for a current Xcode:

1. Read the phone's version in Settings, General, About.
2. Install the Xcode release whose device-support row includes that iOS
   version. Use only a Mac whose macOS is in that Xcode's supported range.
3. Copy this `apps/private-media-vault` directory to that Mac. The first build
   needs network access so Xcode can fetch the pinned Swift packages, unless
   you copy a populated SourcePackages cache yourself.
4. Open `apps/private-media-vault/ios/PrivateMediaVault.xcodeproj`.
5. Select the `PrivateMediaVault` scheme and your iPhone as the run
   destination. Do not add the share-extension folder as a target.
6. Signing and Capabilities: Team = your Personal Team (the free team Xcode
   creates when you sign in with an Apple ID). Leave the bundle id as
   `app.local.privatemediavault`, or change it if Apple says it is taken.
   Change the same string in `VaultIdentity.swift` if you change the bundle id.
   Do not add App Groups, iCloud, push, or associated domains.
7. Trust the developer certificate on the phone the first time iOS asks.
8. Press Run. Xcode installs a development build. That is the install.

Personal Team limits, from
<https://developer.apple.com/help/account/basics/about-your-developer-account/>:

- Up to 10 App IDs, expiring after 7 days.
- Up to 3 devices, expiring after 7 days.
- Up to 3 apps installed this way per device.
- The provisioning profile expires 7 days after it is issued. The app then
  refuses to open until you plug the phone back into that Mac and press Run
  again.

When the profile expires, the encrypted files stay in the app container only as
long as iOS keeps the app installed. Re-signing from Xcode does not require
deleting the app. Deleting the app deletes the vault. Make a portable backup
before the 7 days are up, and again before you delete the app. The recovery
key is shown once, on the backup screen. This repository never prints it.

There is no signed iPhone build in this change. Nobody can produce one here.

## Threat model

You chose Face ID with device-passcode fallback and no separate vault password.
That choice is the security boundary:

- The vault master key is a random 256-bit key stored in the Keychain with
  `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and user presence
  (biometry or device passcode). The phone must have a passcode.
- Anyone who can unlock the phone can unlock the vault. Face ID is a shortcut
  to the same secret, not a second one.
- A person who does not know the passcode and cannot pass Face ID does not get
  the master key from the Keychain. Stolen ciphertext without that key, or
  without the recovery key from a portable backup, does not decrypt.
- The Keychain item is device-only. An iCloud or Finder backup of the phone
  does not restore it onto a new phone. The app also marks the vault directory
  excluded from backup so the ciphertext is not quietly copied as if that were
  a working restore path.
- Recovery is the portable backup. Its file is encrypted with a fresh key, and
  that key is wrapped by a separate 256-bit recovery secret. The secret is
  shown as grouped Crockford base32. It is not stored in the backup, the
  catalog, or the log. Losing both the phone and the recovery secret leaves
  the media unrecoverable on purpose.
- Removing the device passcode makes the Keychain item unusable. The portable
  backup is then the only way back in.
- File protection is `NSFileProtectionComplete` on vault files. That is extra
  protection while the device is locked. It is not a substitute for the
  encryption, and it opens when the device unlocks.
- Memory wiping is best-effort (`explicit_bzero` / `memset_s`). It does not
  defeat a compromised kernel, a jailbreak, or forensic SSD recovery.
- The app switcher is covered with a neutral lock screen when the scene becomes
  inactive. That is not screenshot blocking. A person can still photograph the
  screen while the vault is open. There is no calculator disguise.

## Cryptography

Implemented with Apple's swift-crypto 5.1.1 (module `Crypto`). On Apple
platforms that package uses the system implementation of the same API. On Linux
the tests use swift-crypto's own implementation. Linux success does not prove
the iOS CryptoKit, Keychain, or Face ID path.

- Master key: 256-bit random.
- Each original, thumbnail, and paired motion clip gets its own 256-bit data
  key, wrapped with AES-256-GCM under the master key. The file id is additional
  authenticated data, so a wrapped key cannot be moved onto another file id.
- Plaintext is split into 1 MiB chunks (tests use smaller chunks). Each chunk
  is AES-256-GCM. The nonce is the chunk index. The data key is never reused,
  so the nonce is unique for that key. Additional data binds the file id, the
  chunk index, and that chunk's length.
- A sealed header, also AES-256-GCM under the data key, commits to the chunk
  size, the total plaintext length, the chunk count, the file id, and the
  SHA-256 of the chunk index. The file size must match the header and the
  index. Truncation, reordering, and a flipped ciphertext byte fail
  authentication. This is chunked AES-GCM, not a single tag over the whole
  file and not a formal proof.
- Playback asks only for the byte range AVFoundation requested and decrypts
  those chunks. It does not write a second plaintext copy of the video into
  the vault. AVFoundation can still buffer decoded frames. That residual is
  not wiped.
- The catalog and the import journal are AES-256-GCM under keys derived with
  HKDF-SHA256 from the master key. Search decrypts the catalog after unlock
  and compares strings in memory. It is not searchable encryption. The on-disk
  catalog does not contain the caption, which the tests check.
- SHA-256 of the original is stored in the encrypted catalog and checked on
  export. Imports that stop early roll back. A crash after the journal is
  durable is completed or discarded on the next open. A journal or catalog
  that fails authentication is left in place; the app does not delete media
  because a file looked corrupt.
- The portable backup streams the already-encrypted blobs plus the master key
  through a second chunked container. Restore checks the authentication tag
  before it replaces the vault, and it keeps the previous directory until you
  delete it.

## Behaviour that is implemented

- Import from the Photos picker, the Files picker, the camera, an https link,
  and files opened in the app. The source file is not deleted. Photos picked
  from the library are copies. A camera temp file is removed only after the
  encrypted import succeeds, because that temp file was created by this app.
- Imports are transactional. Disk-full and crash checkpoints roll back or
  recover without publishing a partial item. Empty input is rejected.
- Albums, favourites, literal metadata search, bulk favourite / album / trash,
  playlists, continuous play, swipe between items, and resume positions.
- Trash restores until you delete it or the 30-day retention passes. Retention
  can be changed. Undo of a trash action is Restore in Trash.
- Portable backup, clean-install restore, replace-in-place with the previous
  copy kept, and export of originals. A live-photo pair also exports the
  motion clip beside the still. Export checks the stored SHA-256 and removes
  a partial plaintext file if the check fails.
- Manual lock and autolock (immediate, 1 minute, 5 minutes, or manual). The
  neutral cover is shown when the scene is inactive.
- Assistant session, off by default. Shortcuts intents for status, album names,
  and metadata search. Optional TCP listener bound only to 127.0.0.1. Revocation
  drops the token hash. There is no intent or route for unlock, delete, export,
  or media bytes. This does not talk to Grok.

## Media support

| Input                                                        | What this app does                                                                              |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| JPEG, PNG, GIF, HEIC, WebP stills                            | Stored encrypted and shown after unlock                                                         |
| MP4 and QuickTime video                                      | Stored encrypted. Playback decrypts byte ranges                                                 |
| Live Photo, when the picker returns both a still and a movie | Both parts are stored. The viewer plays the movie. This is not the Photos long-press Live Photo |
| Live Photo system playback, Apple RAW, DRM, PDF              | Rejected or not represented                                                                     |
| https link to a direct image or video                        | Downloaded with an empty ephemeral session, then sniffed                                        |
| HTML, http, URLs with embedded passwords, localhost          | Rejected                                                                                        |

Link import does not read Brave's tabs, cookies, or private windows. It does
not solve paywalls, DRM, or bot checks. If the server returns a web page or an
unrecognized file, the download is deleted and nothing is stored.

The share extension under `ios/ShareExtension/` is not in the Xcode project.
See that folder's README. Open In, Files, Photos, camera, and pasted https
links are the paths that do not need an extension.

## Tests that ran

Command, from a machine with Swift 6.4.2:

```sh
cd apps/private-media-vault
swift test
```

On 5 November 2026 that command was run on Ubuntu 24.04 x86_64 with Swift
6.4.2 and swift-crypto 5.1.1. Result: `VaultCoreTests`, 12 tests, 0 failures.
The cases cover wrong keys, truncated and flipped containers, export byte
equality, source files left untouched, a quota failure during import, crash
checkpoints before the journal, after the journal, and after the catalog
commit, corrupt journal and catalog files left undeleted, backup and restore,
a wrong recovery key, a tampered backup, schema 1 migration and rejection of
schema 99, live-motion export, trash retention, the lock state machine, and
assistant routes that must not reach the vault.

Those tests do not call UIKit, LocalAuthentication, Security, Photos,
AVFoundation, Network, or App Intents. A green Linux run is not an iPhone run.

## Release checklist

| Check                                                      | State                                                 |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| VaultCore tests on Swift 6.4.2 / Linux                     | Ran, 12 passed                                        |
| Xcode build of the iOS target                              | Not run. No compatible Mac in this environment        |
| Install on iPhone 17 Pro Max with a Personal Team          | Not run                                               |
| Face ID, passcode fallback, Keychain prompt                | Not run                                               |
| Photos, Files, camera, Open In, link download on device    | Not run                                               |
| AVFoundation playback of a large video                     | Not run. Range planning and chunk decrypt were tested |
| 7-day profile expiry with data still present after re-sign | Not run                                               |
| Share extension signing                                    | Not attempted. Target is omitted                      |
| Grok or any remote assistant                               | Not connected                                         |
| Security review by another person                          | Not done                                              |

## Remaining prerequisites

- A Mac whose macOS is new enough for the Xcode that supports the phone's
  installed iOS. The 2016 Mac on Monterey is not that Mac.
- Your existing free Apple ID, signed in inside Xcode as a Personal Team.
- A cable install from that Mac. Re-run before the profile expires.
- A written copy of each backup's recovery key, stored outside the phone.
- Decide the bundle id before the first install. Changing it later is a
  different app and an empty vault.

Do not treat this directory as an REA feature. Do not ship it as a reviewed
vault.
