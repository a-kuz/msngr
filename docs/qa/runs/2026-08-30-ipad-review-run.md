# The iPad layout, screen by screen — live review

2026-08-30, simulator `fable-ipad` (iPad Pro 11", 27D0AF17), the `alfa` and
`demo` homes in turn, both pulled back after.

## What was walked and how it held

- The chat list (alfa: requests section, groups, folders tab bar, unread
  badges) and the chat feed (Standup with an album, Nova's showcase with a
  full-screen shader background, shader stickers, holographic and embers
  text effects) lay out correctly at 834 pt.
- Settings, Backup, the chat info card (group avatar with its halo, member
  rows, invite links), Вложения with its four tabs, the sticker sheet, the
  attach menu, the PHPicker and the full-screen media viewer all hold — a
  photo picked from the library sent and opened in the viewer with its
  close/share corners in place.
- The welcome and restore screens were walked earlier the same day in the
  backup run, full screen and correct.

## The defect of the first iPad run, closed

Charlie's shader avatar drew as a rainbow square over the neighbouring rows:
the list's avatar deliberately let a shader document render past its circle,
and a document that fills its whole canvas broke that trust. The list now
clips the canvas to the avatar's circle, the same as the feed does; verified
on the same alfa list (a clean circle with the presence dot), and the
showcase avatars kept their character — orbit's moons live inside the
circle. The halo idea stays on the screens where an avatar stands alone
(chat info, settings).

## Left open

- Rc's image avatar draws as a small square inside its circle in member and
  chat lists — the picture itself is tiny pixel art with transparent
  margins, so this is the image, not the layout; noted, not acted on.
- The feed spans the full 834 pt with bubbles hugging the left edge — held
  as designed for now; a bubble-column cap is a design call for the owner.
