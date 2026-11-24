# Snapshot of the selected area

**Intent.** Choosing an image format takes a single still image of the framed
area instead of recording it. (Roberto's request.)

**Goals**
- Formats: still GIF, PNG, JPEG, BMP ("raw bitmap"), next to the existing
  animated GIF, APNG, WebM and MP4, which keep working as they do now.
- The selected format decides what the main button does.

**Non-goals.** Clipboard, Wayland capture, mouse pointer, downsampling, a JPEG
quality preference, a separate shortcut or command line option.

**Anti-goal.** Peek's frame, size/shortcut labels or countdown in the image.

## Approaches
- **A. GTK grab (chosen by Roberto).** In-process, full size, no pointer,
  independent of the recording backend. X11 only.
- B. One ffmpeg x11grab frame. Follows the pointer and downsample settings, but
  adds still cases to a start/stop pipeline and special-cases the GNOME backend.
- Desktop portal. Covers Wayland, but no dependable prompt-free fixed-area capture.

## Design
- **Formats.** New `OutputFormat` values `STILL_GIF`, `PNG`, `JPEG`, `BMP`, stored
  in `recording-output-format` as `still-gif`, `png`, `jpeg`, `bmp`. Extensions:
  `gif`, `png`, `jpg`, `bmp`. `still-gif` saves as `.gif`, so the extension no
  longer equals the stored name.
- **UI.** The dropdown gains "Record animation" and "Take snapshot" headings. The
  button reads "Take snapshot as PNG" or "Record as GIF".
- **Trigger.** Button, shortcut, `--start` and `--toggle` follow the selected format.
  The start delay applies and can be cancelled; there is no Stop step.
- **Capture.** Hide all overlay labels, wait until the window has been redrawn and
  composited, then grab the root window with `Gdk.pixbuf_get_from_window`. The
  recording area is in device pixels and GDK wants logical ones, so divide by the
  scale factor; the saved image keeps full device resolution.
- **Order.** Capture first, then the save dialog, so the dialog is never captured.
- **Encoding.** gdk-pixbuf writes PNG, BMP and JPEG (quality 95) to a temp file.
  Still GIF: write a PNG, then convert with ffmpeg palettegen/paletteuse.
  Saving, overwrite confirmation, temp file cleanup, notification and file manager
  reuse the existing code, with "image" wording.
- **Disabled entries.** All image formats on a Wayland session (X11 grab would miss
  native windows); still GIF without ffmpeg. If a remembered format is
  disabled, fall back to animated GIF.
- **Errors.** Failed grab, encode or save shows the existing error dialog and
  returns the window to its idle state.

## Verification
- Unit test for format names and extensions; existing tests stay green.
- On X11: take one snapshot per format of a known pattern; check type, dimensions,
  pixels, one frame for GIF, and no overlay text, with and without a start delay.
- HiDPI (`GDK_SCALE=2`): the right area at full resolution.
- Cancel during the delay and in the save dialog; animated recording still works.

## Left to the builder
File layout, redraw wait mechanism, README/man page/changelog wording.
