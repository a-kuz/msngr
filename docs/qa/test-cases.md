# Regression test cases (v1, 2026-08-12)

Written by an independent QA agent. Environment: two iOS simulators for two
users, `wrangler dev` on :8787, "offline" meaning the server is killed. Run
statuses live in `docs/qa/runs/`.

1. **Sending text online, the base path.** A opens the chat with B and sends
   "hello" while B keeps the chat open. Expected: it appears for A at once,
   status going clock then tick, and for B without re-entering the chat, in the
   right order and with the right time.
2. **A message arriving with the chat closed.** B is on the chat list; A sends.
   Expected: the chat moves to the top, the badge grows, the preview updates.
3. **Arrival with the app killed (push).** B kills the app; A sends. Expected:
   an APNs push, and a tap opens the right chat.
4. **Sending while offline.** Kill the server; A sends two or three texts, all
   showing the clock. Bring it back. Expected: they go out in the original
   order with no duplicates.
5. **Killed mid-send.** Kill the server, send so the message is pending, then
   kill the app. Bring the server up and launch. Expected: the message is not
   lost and not duplicated.
6. **Connection lost while sending video.** A 20 to 50 MB video, server killed
   halfway through the upload. Expected: a clear error or retry, no crash, and
   the retry finishes the job once the server is back.
7. **Voice message offline.** Kill the server; record 5 to 10 seconds.
   Expected: it appears locally in the chat with its waveform, pending and
   playable, and goes out once the server is back.
8. **E2EE: first contact, ciphertext on the server.** A writes to B for the
   first time. Check D1 and the logs. Expected: ciphertext only.
9. **Message request: an incoming request.** A new account writes to B.
   Expected: a request with accept and block, not an ordinary chat.
10. **Message request: privacy before accept.** B reads and types without
    accepting. Expected: A gets no receipts, typing or presence before accept.
11. **Message request: block.** B blocks. Expected: A's messages stop arriving,
    and A sees no explicit signal.
12. **Both writing at once.** Each sends ten messages, interleaved. Expected:
    the same order on both sides, nothing lost or duplicated.
13. **Simultaneous reactions on one message.** A and B put different emoji on it
    at the same time. Expected: both visible and grouped correctly, and tapping
    again removes only your own.
14. **Editing a message.** A edits while B watches. Expected: the text is
    replaced, the «изм.» mark appears, the position does not change.
15. **Delete for everyone.** A deletes their own message for everyone. Expected:
    it disappears for both, and previews and counters do not break.
16. **Reply.** B replies; A taps the quote. Expected: a scroll to the original
    and a highlight; a reply to media quotes it with a thumbnail.
17. **Forward.** Text and a photo into another chat. Expected: the forwarded
    strip, with identical content.
18. **Pinning a message.** A pins it. Expected: the strip shows for both, a tap
    leads to the message, unpinning removes it.
19. **A 200-line message.** Scroll through it, long press, copy, paste.
    Expected: no truncation and no lag, the menu positions itself, and every
    line is copied.
20. **Emoji, RTL and links.** "😀😀😀" and composed emoji; Arabic; https and a
    bare domain. Expected: emoji-only renders large, RTL does not break the
    time, links are tappable.
21. **Photo: sending and preview.** Expected: an instant blurhash with progress
    for the sender; blurhash resolving into the sharp image for B; a tap opens
    fullscreen with zoom.
22. **Album (mosaic).** Four to six photos. Expected: a mosaic with only the
    outer corners rounded and a single time, and the viewer pages within the
    album.
23. **A file (PDF or zip).** Expected: name, size and icon; progress for B, then
    opening and sharing; a second opening comes from the cache.
24. **Voice message online.** Fifteen seconds; B plays, pauses, seeks along the
    waveform, and plays again. Expected: the waveform matches, and pause and
    resume keep the position.
25. **Cancelling a voice recording.** Use the cancel gesture. Expected: nothing
    is sent and the next recording starts clean.
26. **Drafts: offline and restart.** Kill the server, type, leave, kill the app,
    launch. Expected: the draft is in the list and in the field, and sync does
    not overwrite it.
27. **A draft clears after sending.** Expected: gone from the list and the
    field, and it has not appeared in another chat.
28. **Group: creation and conversation.** Expected: everyone sees it, the author
    is shown, and the server holds ciphertext.
29. **Group: reactions, reply, delete.** Expected: visible to all, replies carry
    the author, deletion works for everyone.
30. **A message arriving while another chat is open.** Expected: an in-app
    notification that does not throw you out, and the system push does not
    duplicate it.
31. **A long offline period, then catching up.** 30 to 50 messages of every kind
    while B is dead. Expected: a full catch-up in order, with edits and deletes
    applied and no duplicates.
32. **Read receipts and counters.** Three messages give a badge of 3; opening
    the chat marks them read for A and clears the badge.
33. **The typing indicator.** Type something and delete it. Expected:
    «печатает…» appears and then disappears properly.
34. **Muting a chat.** Expected: no pushes, and unmuting brings them back.
35. **Archiving a chat.** Expected: it moves to the archive section; record what
    happens on a new message.
36. **Pinning a chat.** Expected: it sits on top, and unpinning restores the
    sort order.
37. **User search.** Exact, partial, and a name that does not exist. Expected:
    the right profile, and an empty state rather than an endless spinner.
38. **Contact sync.** B's phone number is in A's contacts. Expected: B shows as
    being on msngr, and only hashes reach the server.
39. **Safety numbers and a key change (TOFU).** Reinstall B and write to A.
    Expected: a warning for A; going through silently is not acceptable.
40. **The socket across background and foreground.** Background it for about a
    minute, A sends two messages, come back through the icon. Expected: a
    reconnect and both messages without a pull to refresh, no duplicates.
41. **The server dying with the chat open.** Thirty seconds of downtime.
    Expected: a «подключение…» indication, delivery after the reconnect, and a
    feed that does not jump.
42. **Twenty messages in a row.** Expected: all twenty in order, no UI freeze,
    and the scroll stays at the bottom.
43. **Delete for me.** Someone else's message, deleted for yourself. Expected:
    gone for A and out of the preview, still there for B, and it does not come
    back after a restart.
44. **A push while the sender's chat is open.** Expected: the banner is
    suppressed and the message simply lands in the feed.
45. **Video and the cache.** Watch it, kill the app and the server, open it
    again. Expected: it plays from the cache.
