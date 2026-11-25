# Annotating image snapshots

**Intent.** After taking an image snapshot, mark it up (rectangle, circle, line,
arrow, blur, text, in a chosen color), then save it or copy it to the clipboard.
Builds on `2026-11-24-snapshot-design.md`, and lifts its "no clipboard" non-goal.
Mockup (private): https://claude.ai/artifact/M8XNpseFpUS8wqMdte6YyL, artboard A.

Items marked **(call)** are Claude's, not discussed with Roberto.

**Goals**
- The annotation window opens after every image snapshot, however it was started.
- Save and Copy both give the annotated image at full capture resolution.

**Non-goals.** Moving or editing drawn items, filled shapes, cropping, numbered
markers, annotating animations or existing files, Wayland.

**Anti-goals.** Losing a drawing without asking. Saving a blur that leaves the
original pixels in the file. Changing animated recording.

**Constraints.** GTK 3.20, X11, Cairo and gdk-pixbuf. No new dependency.

## Approaches
- **A. Separate window (chosen by Roberto).** Works at any snapshot size, has room for
  every tool. One extra window.
- B. Tools inside the Peek frame. No new window, but the toolbar barely fits at
  440 px and needs overflow menus, and the frame is see-through and click-through.

## Design

**Flow.** Grab → annotation window → encode → save dialog. Encoding moves after
annotation, since it needs the final image. Peek stays busy, as now, until the
window closes. The start delay is unchanged.

**Layout.** Header: Cancel, Undo, Redo, title "Annotate snapshot", Copy, "Save as
PNG…" (the selected format). Toolbar: six tools, six colors plus a custom color
button, three widths. Then the image, then a status bar with a hint for the tool and
the image size in pixels. Icon buttons have tooltips and accessible names.

**Image view.** Scaled down to fit, never enlarged, following window resizes. On
HiDPI, 100% means one image pixel per device pixel **(call)**. Items are stored in
image pixels; line width and text size are multiplied by the capture's scale factor
**(call)**, so they look the same at any scale factor. Drags are clamped to the image
**(call)**.

**Tools.** Rectangle (default each time), circle (an ellipse in the dragged box),
line, arrow (tail to tip), blur, text. Shift gives a square, a circle, or 45° steps.
Drags under 4 screen pixels are ignored **(call)**. Keys R, C, L, A, B, T pick tools,
except while typing **(call)**.

**Style.** Red #e01b24 (first default), yellow #f6d32d, green #2ec27e, blue #1c71d8,
black, white, or custom. Widths 2, 4 (default), 7; text size is 12 + 3 × width, bold.
Color and width apply to new items only. Both are remembered in GSettings; tool is
not. They are insensitive while blur is selected.

**Text.** Click to place; one line **(call)**. Enter, or clicking elsewhere, confirms;
Esc discards. Empty text adds nothing. Save and Copy first confirm pending text.

**Blur.** A strong blur, computed from the captured pixels only and baked into the
output. All blurs sit under all shapes and text, whatever the drawing order. The
radius is fixed, scaled by the capture's scale factor, and must leave 13 px text
unreadable **(call)**. Regions that overlap do not expose the original.

**Undo/redo.** Unlimited, one step per item; a new item clears redo. Ctrl+Z,
Ctrl+Shift+Z.

**Finishing**
- **Save** (Enter, Ctrl+S): encode, then the existing save dialog. While encoding, the
  window is insensitive except Cancel, which stops the encode and returns to the
  drawing **(call)**. Cancelling the dialog, or an encode or save error (existing error
  dialog), also returns to the drawing. A successful save closes the window, then the
  existing notification and file manager handling run.
- **Copy** (Ctrl+C): sets the rendered image on the clipboard and asks GTK to store it
  with the clipboard manager. Window stays open, status bar confirms. Independent of
  the selected format.
- **Cancel** (Esc, window close): back to idle. If the drawing changed since the last
  Copy, ask "Discard annotations?" first. With nothing drawn, never ask.
- The temp file is deleted on every path, including a retry of Save.

**Outside events (call).** While annotating: closing Peek's window or quitting asks as
Cancel does; if refused, Peek stays open. `--stop` and Peek's Stop button act as
Cancel. `--toggle`, `--start` and the shortcut just raise the annotation window.
Interrupt signals still terminate at once. Several Peek windows can each annotate.

**Outside events while saving (call).** Closing Peek, quitting, closing the annotation
window or `--stop` during an encode stops it, returns to the drawing and then acts as
Cancel there (asks if needed). The Cancel button alone just returns to the drawing.
While the save dialog is open, `--stop`, `--toggle` and `--start` are ignored, and
close or quit is refused: the save dialog is already the question. While the
file is being copied, closing or quitting hides the windows and closes when the copy
ends, as now; if it fails, the windows return with the drawing and the error.

**Several windows (call).** Quit and `--stop` act per Peek window: each drawing asks its
own question, and refusing keeps only that window open.

**Responsiveness (call).** PNG, JPEG, BMP and GIF's intermediate PNG are written
synchronously as today; a short freeze is accepted, and Cancel is only effective during
GIF's ffmpeg step. Blur is cached per item, not recomputed on each redraw.

**Window (call).** Transient for the Peek window, not modal, so the Peek frame never
covers it. Opening size fits the image within 80% of the monitor's work area, with a
minimum that shows the whole toolbar.

## Verification
- Unit tests of the drawing model without a display: undo/redo, Shift constraint,
  clamping, and rendering onto a known image: shape pixels have the right color, pixels
  outside items are unchanged, blurred pixels differ and stay under shapes.
- Unit test: output dimensions equal the capture's.
- On X11: each tool, Save in all four formats, Copy then paste, save dialog cancel then
  save again, failed save, each Cancel path, `--stop`/`--toggle`, close while annotating.
- `GDK_SCALE=2`, a tiny capture, and a full-screen capture.
- Animated recording still works; existing tests stay green.

## Left to the builder
File layout, drawing code structure, blur algorithm, icons, dark theme styling,
GSettings key names, README/man/changelog wording. Italian strings are included.
