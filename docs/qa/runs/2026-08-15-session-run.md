# The session survives a restart on a clean install (#56)

## Stand

Simulator `msngr-ms-agent` (iPhone 17, iOS 26.5), own `wrangler dev` on :8802
with a separate `--persist-to`, the app launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8802`.

## Cause

`AppState.sessionFileURL` pointed straight into Application Support
(`FileManager.urls(for: .applicationSupportDirectory)`), and iOS does not create
that directory in a fresh container. The write went through `try?`, so the
failure was invisible: registration went through, the chat list opened, but
`session.json` never reached the disk.

Everything else was kept: the database and the master key live in the app group
container, whose directory `AppContainer.resolve()` creates. The session was the
only file going around `StorageLocation`.

Measured on a live container before the fix: `Library` held only `Caches`,
`HTTPStorages`, `Preferences`, `Saved Application State` and `SplashBoard`, with
no `Application Support` directory at all.

## Run before the fix (HEAD b415b19)

1. Clean install, the registration screen.
2. Registered `sessfix1`, the chat list opened.
3. `simctl terminate` plus `launch`, the registration screen again. In the group
   container: `.masterkey`, `msngr.sqlite`, `avatars`, `media-outgoing`;
   `session.json` is missing.

## Run after the fix

The container was wiped (`simctl uninstall`) and a build with the fix installed.

4. Registered `sessfix2`. `session.json` appeared in the group container, 155
   bytes.
5. `simctl terminate` plus `launch`, the user is still signed in and the chat
   list opens.
