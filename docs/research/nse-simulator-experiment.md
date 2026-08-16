# NSE on the simulator: an experiment

Date: 2026-08-14. Setup: macOS 25.5, Xcode 26.6 (17F113), simulator `nse-test`
(iPhone 17 Pro, iOS 26.5), created for this run and deleted afterwards.

## Verdict

`xcrun simctl push` does not launch the Notification Service Extension, in any
of the three app states (foreground, background, killed). The banner shows
exactly the content that sits in the payload.

This is a limit of the delivery channel, not of our code: a control extension
with no dependencies at all, in a separate app, behaves the same way.

A separate result, this one positive: Communication Notifications (sender
avatar and name) work on the simulator without a paid account, as long as the
app itself builds the content. Verified with local notifications.

## What was in the repository before the experiment

The `NotificationService` target was already described in `ios/project.yml`
(app-extension, `NSExtensionPointIdentifier: com.apple.usernotifications.service`,
embedded into Msngr via `embed: true`), and the code is
`ios/NotificationService/NotificationService.swift` from commit ee0538b. It
built before this run too; what was checked here is that the `.appex` lands in
`Msngr.app/PlugIns/` and is registered by the system:

```
$ xcrun simctl spawn <udid> pluginkit -mv | grep enface
ai.enface.Msngr.NotificationService(1.0)  2B42A7EB-…  …/Msngr.app/PlugIns/NotificationService.appex
```

Both entitlements files were an empty `<dict/>`: xcodegen regenerates them from
`project.yml`, so the app group went in there (`entitlements.properties`) and
not into a hand-edited .entitlements.

## What the NSE does today

`didReceive` logs `[NSE] didReceive run=<uuid>`, appends a line to
`nse-marker.log` in the app group container and, in DEBUG only, prefixes the
title with `NSE: `. `serviceExtensionTimeWillExpire` returns `bestAttempt`.
Three independent observation channels, banner, file and unified log, so that
"the extension did not run" cannot be mistaken for "it ran and we missed it".

`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set for the target; the branch
is live.

## How the experiment went

Payload per `docs/protocol.md` (`mutable-content: 1`, `thread-id`, `badge: 3`,
`chatId`, `msgId`), command `xcrun simctl push <udid> ai.enface.Msngr payload.json`.

| state | banner | marker file | NSLog from the NSE |
|---|---|---|---|
| foreground | «Msngr / Новое сообщение», no prefix | none | none |
| background | same | none | none |
| killed | same, badge 3 on the icon | none | none |


The badge from the payload is applied and `thread-id` arrives (visible in the
SpringBoard log as `threadIdentifier: chat-demo`), so the notification is
delivered in full and exactly one stage, mutation, is skipped.

## Why it does not launch

The full simulator debug log at the moment of the push shows the delivery path:

```
CoreSimulatorBridge [com.apple.UserNotifications:Connections] [ai.enface.Msngr] Creating a user notification center
CoreSimulatorBridge [ai.enface.Msngr] Adding notification request 9C6D-779F to destinations: Default
usernotificationsd  [com.apple.CoreSimulator.CoreSimulatorBridge] Entitlement check success: simulator
usernotificationsd  Forwarding addRequest: ai.enface.Msngr
SpringBoard          … trigger: <UNPushNotificationTrigger: …; contentAvailable: NO, mutableContent: YES>>
SpringBoard          [ai.enface.Msngr] Saving notification 9C6D-779F: YES [ … pipelineState: pending]
```

`simctl push` is a call to `addNotificationRequest:forBundleIdentifier:` made by
the CoreSimulatorBridge process, that is, a local notification with a push
trigger attached to it, not traffic through apsd. The
`com.apple.usernotifications.service` extension point is not requested once
during the whole run (0 occurrences in 18406 log lines), and pkd takes no part
in delivery. The system sees the `mutableContent: YES` flag and ignores it.

There are no crash reports for the extension, neither in
`~/Library/Logs/DiagnosticReports` nor in the simulator's `CrashReporter`. The
process does not die, it never starts.

### Control

A separate app, `NSEProbe`, with an extension that has no dependencies at all
(UserNotifications only, a file written into its own Documents, NSLog, title and
body replaced) gives the same result: original banner, no file, no log. So this
is not MsngrKit, not GRDB, not the app group and not the debug dylib.

apsd inside the simulator is alive and holds its connection to 5223, so the real
APNs path exists, but it needs a device token and an APNs key, which means a
paid account.

## What remains unverified

Nothing whose answer requires a live extension process can be settled on the
simulator:

- replacing `body`/`subtitle` from the NSE, and how that looks in the banner and
  on the lock screen;
- `serviceExtensionTimeWillExpire` and the 30-second budget;
- access to the app group container and to the Keychain from the extension
  process;
- the extension memory limit (24 MB) on real decryption.

Indirect evidence: the extension's entitlements are produced correctly on the
simulator. `NotificationService.appex-Simulated.xcent` contains
`application-identifier` and
`com.apple.security.application-groups: group.ai.enface.msngr`. That is an
argument that access will be there, not proof of it.

## App groups on the simulator

They work without a paid account. installd creates the container at install
time:

```
$ xcrun simctl get_app_container <udid> ai.enface.Msngr groups
group.ai.enface.msngr  …/data/Containers/Shared/AppGroup/A560C895-…
```

The container appears precisely because of the entitlement: for NSEProbe, where
the group is not declared, the command returns an empty answer.

A trap while diagnosing this: on simulator builds, `codesign -d --entitlements`
and the `*.app.xcent` file both show an empty dictionary. The real entitlements
sit next to them in `*-Simulated.xcent` (and `.der`), and those are what installd
reads.

The entitlement was introduced together with the move of the files
(`StorageLocation`, `StorageMigration` in MsngrCore): turning the group on
changes the storage root from Application Support to the group container, and
`msngr.sqlite` and `.masterkey` travel with it. Without that move, an already
installed build would see a clean install with new identity keys; the live
upgrade is verified in `docs/qa/runs/2026-08-14-appgroup-run.md`.

The master key that the NSE will use to decrypt previews is kept as a
`.masterkey` file in the app group container (`SharedFileMasterKey`,
`ios/MsngrKit/Sources/MsngrCore/KeyStore.swift`), not in the Keychain, so no
separate Keychain access group is needed for decryption in the extension.

## Avatars in notifications (Communication Notifications)

Tested on the NSEProbe app with local notifications: the rendering is done by
SpringBoard, and it makes no difference to SpringBoard who built the content,
the app or the extension. That is why the result carries over to the NSE once
the NSE works on a device.

What it takes for the avatar to be drawn (all three conditions are mandatory; if
any one of them is missing, `updating(from:)` silently returns the content
unchanged and throws no error):

1. the `com.apple.developer.usernotifications.communication` entitlement;
2. `NSUserActivityTypes` in Info.plist with the string `INSendMessageIntent`;
3. an `INPerson` with `isMe: true` among the intent's `recipients`.

Donating the intent (`INInteraction.donate`) is not needed: on a clean install
where nothing had ever been donated, the avatar is drawn. The donation is still
needed for other things (Siri suggestions, the share sheet), but not for the
banner.

A paid account is not required: a build with this entitlement passes "Sign to
Run Locally" signing, and the key lands in `NSEProbe.app-Simulated.xcent`.

One to one: a round avatar of the sender, the title replaced by their name, the
app icon moved into the corner badge:


Group (`speakableGroupName` plus two `recipients`): the title stays the sender's
name, the group name becomes the subtitle, the avatar is still the sender's, and
the image assigned to the `speakableGroupName` parameter is not used in the
banner:


Without the entitlement: an ordinary banner with the app icon, and no
diagnostics:


The avatar is passed as `INImage(imageData:)`, so the NSE has to obtain the
image bytes locally, without network. A convenient store is files in the app
group container, written by the app when the profile is updated. Size: 180×180
is enough, the banner shows the avatar small.

## What this means for planning

Almost all of the substantive work can be done before an account is bought, as
long as the NSE stays a thin adapter:

- all the preview logic (decryption, picking the text, "Name: text" for groups,
  placeholders for media, gap-fill over missing msgIds, badge counting) lives in
  MsngrCore and is covered by unit tests, where no simulator is involved at all;
- the visual side (avatars, groups, thread-id, long texts) can be polished
  today: the app builds the content with the same code and posts a local
  notification. That also gives an end-to-end check on the simulator against the
  dev backend;
- what is left in `didReceive` is the wiring: read userInfo, call the builder,
  hand the result to contentHandler.

What cannot be learned before a device with a paid account: whether the
extension comes up at all, whether it fits into 30 s and into the memory limit,
whether it sees the app group and the Keychain from its own process. That is a
risk to the schedule, not to the architecture; it has to be launched once, when
the account appears.

The dev backend with `apns-mock` remains useful for checking the server side
(that the push went out, with what payload, with what badge), but previews
cannot be checked with it. Worth adding a "show the preview locally" mode to the
mock or to the app, otherwise any NSE change will be unverifiable.

## Reproducing

```
cd ios && xcodegen
xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr -destination "id=<udid>" build
xcrun simctl install <udid> <…>/Msngr.app
xcrun simctl push <udid> ai.enface.Msngr payload.json
xcrun simctl spawn <udid> log stream --level debug --predicate 'eventMessage CONTAINS "[NSE]"'
xcrun simctl get_app_container <udid> ai.enface.Msngr group.ai.enface.msngr
```
