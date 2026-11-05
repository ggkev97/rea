# Share extension

This folder is source for a possible share extension. It is **not** a target in
`PrivateMediaVault.xcodeproj`, and the default scheme does not sign or embed it.

Apple's Personal Team can register a limited number of App IDs, and an extension
needs its own App ID. A share extension also needs a shared container, which
means the App Groups capability. On 5 November 2026 the capability table at
<https://developer.apple.com/help/account/reference/supported-capabilities-ios/>
lists App Groups, but the checkmarks in that table did not survive text
extraction, and third-party guides disagree about the free column. This project
therefore does not claim that a Personal Team can sign the extension.

Even if a later paid team embeds it, the extension must not unlock the vault,
decrypt media, delete items, or export originals. The only safe job is to copy
files the user explicitly shared into an app-group inbox. Those copies are
plaintext until the main app imports and deletes them. The main app's Open In,
Files, Photos, camera, and https link paths do not need this extension.

Do not add an App Groups entitlement to the main app unless a signing attempt
on the Mac you will actually use has succeeded. A failed entitlement can block
the only install path that works with a free Personal Team.
