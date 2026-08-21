# Previewing a file in the app, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`; the file is the owner's 98.9 MB «HISTORY.pdf» in the direct chat.

- `02-pdf-open.png` — the tap on the file bubble opens the PDF in the
  QuickLook previewer, all 642 pages of it; types QuickLook cannot read go
  to the system share sheet instead.
- The owner's «пдф не просматривается»: reproduced on the cold path while
  the host was under a parallel gate build — the tap was followed by about
  sixty seconds of complete silence (the download and the decrypt of 98.9 MB
  with no indicator), after which the previewer did open. On a quiet host the
  same cold open takes about two seconds (`01-cold-open-sequence.png`,
  frames a second apart: the chat, the chat, the open previewer).
- The fix: the tap now shows a small blurred spinner plate in the middle of
  the screen for as long as the fetch runs — it does not block touches — and
  a second tap on the same file joins the running fetch instead of starting
  another. On the fast path the plate lives shorter than a frame and is
  invisible, which is the point; the slow path could not be re-shot to show
  it — the stand has no way to slow its own network down.
