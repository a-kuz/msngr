# Who can add me to a group

Date: 2026-08-31. Simulator `fable-ginv` (created and deleted for the run),
the alfa fixture home, the shared stand (migration 0011 applied).

## The shape

`privacy_settings.group_invites` (everyone / contacts / nobody, "contacts"
against the same synced book as the other tiers). A group create and a member
add filter the protected out on the server and name them in the response
(`invited`); the adder's client then sends the group's invite link as an
ordinary message into the direct chat — sending the invitation is what the
adder meant, so it takes no extra tap. Joining by the link stays open: the
tier guards being put in, not choosing to enter.

## Scenario

charlie3 set `groupInvites: nobody` (REST). As alfa on the simulator: new
group «Пштм» with bravo3 and charlie3 picked. After «Создать»:

- the group exists with two members — alfa and bravo3; charlie3 is not in it;
- charlie3's direct chat with alfa holds «Приглашение в «Пштм»:
  msngr://join/pJhAJEjtmyUO» — sent by the client on its own.

charlie3's tier returned to everyone after the run.

## Checks

- smoke: the group-invites block (the protected left out of a create and
  named; a contact adds them straight in) — with the full suite ALL PASS.
- `tsc --noEmit` clean; `swift test` 531 tests, 0 failures.
- The live scenario above.

## In passing

The simulator's hardware keyboard stayed on the Russian layout through a
respring and a reboot, so `idb ui text` typed Cyrillic for Latin input; the
run went through `simctl pbcopy` + the field's «Вставить». A permanent lever
for scripted runs would be worth having in grid.py.
