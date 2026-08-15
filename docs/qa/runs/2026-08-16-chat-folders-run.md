# Live run: chat folders

Date: 2026-08-16. Simulator `folders-agent` (iPhone 17, 3552BF91-0F2B-472C-BFB4-14A6B40179C3),
own stand `wrangler dev --port 8805 --persist-to <scratchpad>/wrangler-state`.
User `folderdemo`; peers opened the chats from their side (four direct chats,
three groups), three of the requests were accepted from the list.

Screenshots: `docs/qa/runs/2026-08-16-chat-folders/`.

## What was walked through

| Step | Evidence |
| --- | --- |
| No folders yet: the strip is "Все" plus the button that creates the first folder | `01-no-folders-yet.png` |
| A rule fills the folder while it is being made: "Люди" checks every one-to-one chat | `02-folder-rule-people.png`, `03-rule-fills-chats.png` |
| A chat added by hand on top of the rule: the group "Дизайн-ревью" in a folder of people | `04-hand-added-chat.png` |
| Folder list: order, what each folder holds, and that folders are device-local | `05-folders-list.png` |
| Tabs above the list; archive and requests stay on "Все" | `06-tabs-all.png` |
| Switching by swipe: "Все" → "Люди" → "Группы" → "Непрочитанные" | `07-swipe-to-people.png`, `08-swipe-to-groups.png` |
| Empty folder, with the button that changes it | `09-empty-folder.png` |
| Row actions inside a folder page, "Из папки" among them | `10-row-actions-in-folder.png` |

## The swipe, and why the threshold is where it is

A paged `TabView` takes every horizontal drag for itself: with the list inside
one, the row's own swipe never opened. Control experiment on the same
simulator and the same synthetic drag (idb, 90 pt over 0.6 s): in a plain
`List` (the folder list in the sheet) the drag revealed Delete; in a page of
the `TabView` no row action appeared, the page bounced back instead.

So the tab is switched by a drag of 120 pt or more, and shorter drags stay with
the row. Measured after the change on a chat row: 90 pt opens Удалить / Без
звука / Архив / Из папки, 160 pt moves to the next tab. Full-swipe archiving is
gone with it — a drag that long now changes the tab, and an action fired by
crossing the same distance would be an accident.

## Not covered here

The unread badge on a tab is counted from `unreadCount`, and nothing on this
stand could raise it: the seeded peers hold fake keys, so they cannot send a
message this device would read. The empty "Непрочитанные" folder is the same
rule seen from the other side.
