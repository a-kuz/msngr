# A mention survives a rename

Date: 2026-08-28. Own local stand (`wrangler dev --port 8803`, isolated from the
shared one), own simulator `msngr-7b-mention`, scratch accounts registered
through `msngrfixture` against that local stand — none of `alfa`/`bravo`/`charlie`
touched.

## What was checked

The mention token was already `[@Name](user:<userId>)` end to end (see
`qa/runs/2026-08-28-mention-token-run.md`): `Markdown.mentionToken` stores the
id, `MessagesViewController.open(url:)` resolves the tap by
`String(url.absoluteString.dropFirst("user:".count))` and calls
`DirectChat.open(userId:)`, and `MessageMarkdown.mentionsUser` (the mute-piercing,
the chat-row mark, the unread counter, the bubble wash) matches by id too. No
code carries a username anywhere in this path. This item was only unverified
live, so no code changed — the run below is the evidence.

## The run

1. Seeded a local trio (`alfa5`/`bravo5`/`charlie5`) and knocked in two more
   accounts against the same local stand: `mentiontarget` (display "Old
   Handle") and `mentionviewer`.
2. Created a group `MentionTest` with `alfa`, `mentiontarget` and
   `mentionviewer`, and had `alfa` send into it:
   `Ping [@Old Handle](user:01M151SC6THFRBZBGRW0WJH9ZV) about the demo`.
3. Renamed `mentiontarget`'s username via `POST /api/username`:
   `old handle` → `newhandle99`, same `userId`. Confirmed server-side:
   `GET /api/users/<id>` now answers
   `{"username":"newhandle99","display_name":"Old Handle",...}`.
4. Installed `mentionviewer`'s real client (registered with genuine E2EE keys
   through `msngrfixture knock`) onto the simulator and opened the group. The
   bubble reads "Ping @Old Handle about the demo" — the visible name is the one
   baked in at send time, as designed; the token itself is invisible.
5. Tapped the `@Old Handle` link. The app navigated to a new direct chat titled
   "Old Handle" (the send-time display name, same as the chat-list preview
   convention) — not an error, not the wrong person.
6. Confirmed server-side which chat actually opened:
   `GET /api/chats` for `mentionviewer` lists
   `direct:01M151SC6THFRBZBGRW0WJH9ZV:01M151SJKSDX31QZ6S4BHNRNA5` —
   `01M151SC6THFRBZBGRW0WJH9ZV` is `mentiontarget`'s id, the same one renamed
   in step 3.

The tap resolved and opened the correct person purely by id, after their
username had already changed on the server. No defect found.

## Verdict

ROADMAP: "a mention survives a rename: it carries the userId, not the handle"
→ ✅, evidenced by this run; the code itself needed no change.
