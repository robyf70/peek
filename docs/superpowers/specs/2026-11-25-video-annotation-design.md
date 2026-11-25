# Annotating recordings

**Intent.** After recording an animation, move back and forth on its timeline and draw
on it as on a snapshot, each item being visible for a chosen time. Roberto asked for a
potential but also easy way. Builds on `2026-11-25-snapshot-annotation-design.md`
(the "snapshot design"), and lifts its "no animations" non-goal.

Items marked **(call)** are Claude's, not discussed with Roberto.

**Goals**
- Reach any frame of the recording, and draw on it with the six existing tools.
- Choose the first and last frame on which each item is visible.
- Only when asked: a preference, off by default (Roberto).
- Works for GIF, APNG, WebM and MP4, and with both recorders.

**Non-goals.** Playback, trimming, items that follow moving content, fades, keyframes,
moving or reshaping drawn items, copying a recording to the clipboard, opening existing
files, Wayland.

**Anti-goals.** Losing a recording because annotating it failed. Losing drawings without
asking. A frame in which a blurred region shows the original during the blur's range.
Changing recordings when the preference is off.

**Constraints.** GTK 3.20, X11. No new dependency: ffmpeg is already required, and
ffprobe is in the same Fedora package. Where ffmpeg or ffprobe is missing the preference
is insensitive, and recordings are handled as if it were off **(call)**.

## Approaches
- **A. Scrub, draw, burn in with ffmpeg (chosen by Roberto).** ffmpeg fetches single
  frames for the window and overlays the items on save. No playback.
- B. A plus GStreamer playback. Smoother, but a new dependency, codec problems, and a
  preview that can differ from the saved file.
- C. Pause and draw while recording. No timeline, but no going back, which Roberto asked
  for.

## Measured
Synthetic 720p, 15 fps clips on this machine. One frame fetched: 0.10–0.16 s in lossless
VP9, VP9 and H.264. Burn-in of 30 s: WebM 4.4 s with Peek's settings, MP4 0.7 s. Frame
times from ffprobe: 0.08 s. A lossless VP9 intermediate is too slow (13.6 s for 30 s).
FFV1 in Matroska is quick and, with overlay in RGB, leaves frames outside the items' range identical;
overlay's default 4:2:0 changes them. Variable frame times are kept.

## Design

**Flow, preference on.** Stop → the recorder finishes its file, but conversion does not
start → annotation window → save → burn in → GIF/APNG conversion if needed → save dialog
→ copy. Today's flow, where the save dialog appears during conversion, is unchanged with
the preference off. The preference is "Annotate recordings" in Preferences; it is read
when the recording starts **(call)**.

**Layout.** The snapshot annotation window with the title "Annotate recording", no Copy
button, "Save as GIF…" (the selected format), and a timeline between the image and the
status bar:
- previous and next frame buttons, time, total time, frame number;
- a slider over all frames, with the playhead;
- one row per item in drawing order: tool icon, name (text items show their text), and a
  bar for its range. Rows scroll when there are more than four **(call)**.

**Moving.** Drag the slider, the step buttons, Left/Right for one frame, Shift+Left/Right
for one second, Home/End **(call)**; not while typing. Frames are fetched by ffmpeg on
demand, at recording size; while one is being fetched the previous frame stays, and only
the latest request is fetched next. Items are always drawn for the playhead's frame, not
for the frame still shown. Drawing is insensitive until the frame shown matches the
playhead **(call)**. Frames are counted by their real timestamps, as GNOME Shell records
at a variable rate.

**Items.** Drawn, styled and undone as on snapshots. A new item starts at the playhead and
lasts 3 s, clipped to the end; a new blur covers the whole recording **(call)**. Items stay
in place. One item can be selected, by its row or by having just been drawn; its bounds
are marked on the image when visible. Ranges are changed by dragging either end of the
bar, or by "Start here" and "End here" at the playhead. Dragging an end moves the playhead
with it, to show that frame **(call)**. A range is first to last frame, both included,
and at least one frame; an end that would pass the other stops at it. Delete removes the selected item. Range changes
and deletions are undo steps **(call)**; one drag is one step.

**Preview and output match.** Shapes and text use the existing renderer for both. Blur
has the snapshot's strength and stacking: from captured pixels only, opaque, under all
shapes. The preview may differ from ffmpeg's blur in interpolation only.

**Burn-in.** Each non-blur item is rendered to a transparent PNG at recording size;
ffmpeg overlays them in drawing order for their range, above all blurs. Range limits
are placed between frame times, so rounding can neither lose nor add a frame.
Recording frame times are kept, sound is copied. GIF and APNG: lossless intermediate in
RGB, then the existing conversion (including gifski). WebM and MP4: encoded with the
encoding settings used for recording, including codec and VAAPI. **No items at save: no
re-encode, the recording is used as it is.** A second lossy encode is accepted for WebM
and MP4 with items.

**Encoders (call).** With the ffmpeg recorder, its own arguments. Those of the GNOME Shell
recorder are GStreamer's, so there WebM is encoded with Peek's VP9 settings and MP4 with
its software H.264 settings, ignoring the codec and VAAPI settings as that recorder does.
The settings in effect when the recording started are used. There is no encoder probe or
fallback: if the encoder is missing, saving shows ffmpeg's error and returns to the
drawing, and removing all items still saves the original.

**Exact frames (call).** Guaranteed for the burned-in video, so for the final WebM and MP4.
GIF and APNG conversion resamples to a fixed rate as today, so with GNOME Shell's variable
rate a very short item can shift or vanish there.

**Sizes.** The image size is that of the recorded frames, after downsampling. Widths, text
and blur are scaled by the capture's scale factor divided by the downsample factor, at
least 1 **(call)**.

**Finishing.** As on snapshots, with these differences:
- Save runs burn-in and conversion with the window insensitive except Cancel, which stops
  ffmpeg and returns to the drawing. Cancelling the save dialog, or any failure, also
  returns to the drawing. The original recording is kept until the save succeeds or the
  user discards it.
- Cancel and close always ask, as the recording itself would be lost: "Discard recording?"
  with Keep and Discard **(call)**.
- All temporary files are deleted on every path.

**Failures before the window (call).** If the frame times or the first frame cannot be
read, an error is shown and the recording continues as with the preference off. If a
later frame cannot be fetched, the status bar says so, and the previous frame stays.

**Outside events (call).** As in the snapshot design, with burn-in and conversion taking
the place of encoding: `--stop` and Peek's Stop button act as Cancel, `--toggle`, `--start`
and the shortcut raise the window, quit and close ask.

## Version
Peek 1.6.0 has both snapshot and recording annotation (Roberto). It replaces the
unpublished 1.5.1-22. Last step of the work: `meson.build`, `rpm/peek.spec` (1.6.0-1, the
-22 changelog entry becomes its entry), `README.md`, `CHANGES.md`, appdata release. The
flatpak file pins upstream's 1.5.1 and is left alone. `CHANGES.md` says MP4 recording was
removed, which is wrong for this fork: replace that line with the MP4 options **(call)**.
Commit, push, tag `v1.6.0-1` and release only when Roberto says so.

## Verification
- Unit tests without a display: range editing and its limits, undo of ranges and
  deletions, items visible at a frame, the ffmpeg arguments built for each format, no
  burn-in without items.
- Tests with ffmpeg on generated clips, skipped where it is missing: an item is on exactly
  its frames (first, last, the ones before and after; also variable rate), blurred pixels
  differ on every frame of the range, sound and frame times are kept, frames outside all
  ranges are identical on the GIF path.
- On X11: each format, gifski on and off, downsample 2, `GDK_SCALE=2`, sound, a one-second
  and a five-minute recording, save dialog cancel then save again, failed burn-in, each
  Cancel path, preference off.
- Snapshot annotation and existing tests stay green.

## Left to the builder
File layout, whether the window is shared or derived, timeline widget, ffmpeg graph,
how frame data is passed, key names and wording, README/man/changelog. Italian strings
are included.
