# App Store privacy label notes

These notes are for a person filling App Store Connect later. They are not a
submission, and a free Personal Team cannot submit to the App Store. A paid
Apple Developer Program membership is required for that, and this project does
not enroll in one.

## Suggested answers

| Prompt                              | Answer to record                   | Why                                                                                      |
| ----------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------- |
| Data used to track you              | No                                 | `NSPrivacyTracking` is false. There is no advertising identifier and no tracking domain. |
| Data linked to you                  | No data collected by the developer | The app has no account and no first-party server. Media stays in the app container.      |
| Data not linked to you              | None collected by the developer    | Same reason.                                                                             |
| Photos or videos                    | Not collected                      | The user imports copies into the vault. They are not uploaded.                           |
| Audio                               | Not collected                      | Camera recordings stay in the vault.                                                     |
| User content                        | Not collected                      | Captions and filenames stay in the encrypted catalog.                                    |
| Identifiers, diagnostics, purchases | Not collected                      | There is no analytics SDK, crash uploader, or purchase.                                  |

## Contact the user chose

Importing an https link opens a connection to that URL with an empty ephemeral
session. That is a request to the site the user named, not to the developer.
Do not list it as data collected by this app. Do not describe it as private
browsing of Brave, and do not claim it can pass a login wall.

## Face ID

The app uses the system Face ID prompt. It does not receive face images or
templates. The privacy label does not get a biometric data type for that
system prompt. The usage string is `NSFaceIDUsageDescription`.

## Encryption export

The app uses AES-256-GCM for the user's own files, not only HTTPS. Do not set
`ITSAppUsesNonExemptEncryption` to false. App Store encryption questions need
a human export-compliance decision. That decision is not made here.

## Privacy manifest

`PrivacyInfo.xcprivacy` declares no tracking and no collected data types. The
only required-reason API declared is UserDefaults, reason `CA92.1`, because
the app stores the autolock choice and the continuous-play choice. No other
required-reason API is declared, because this code review did not find one in
use. Do not add reasons for APIs the app does not call.

Photo library permission is intentionally absent. The Photos picker returns
only the items the user selects and does not need broad library access.
