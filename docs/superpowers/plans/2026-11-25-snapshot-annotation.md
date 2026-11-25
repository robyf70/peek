# Snapshot Annotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After every image snapshot a window opens to draw on it, then save it or copy it.

**Architecture:** `AnnotatedImage` is a display-free model and Cairo renderer in image pixels. `AnnotationWindow` is the GTK UI over it and knows nothing about files. `ApplicationWindow` owns the flow (grab → annotate → encode → choose → copy) and an explicit state for it.

**Tech Stack:** Vala, GTK 3, Cairo, Pango, gdk-pixbuf, meson, GLib.Test.

**Spec:** `docs/superpowers/specs/2026-11-25-snapshot-annotation-design.md`

## Global Constraints

- No new dependency. GTK >= 3.20 (no 3.22-only API without a guard), X11 only.
- Colors: red #e01b24 (default), yellow #f6d32d, green #2ec27e, blue #1c71d8, black, white, custom. Widths 2, 4 (default), 7. Text 12 + 3 × width px, bold. All × capture scale factor.
- Blurs come from the captured pixels only and sit under all other items.
- Output has the capture's exact dimensions. Animated recording is unchanged.
- Strings through `_ ()` / `translatable="yes"`. No attribution lines in commits.
- `B` is a meson build dir outside the repo, set up with `-Dbuild-tests=true`. Build `ninja -C $B`, test `meson test -C $B`; record the baseline first.

## Review Focus

- Save or Copy while text is still being typed: the text is in the output (Task 2).
- Drag released outside the image or window: item ends at the image edge (Task 1, Task 2).
- Capture only a few pixels wide, and blurring a few pixels: no crash, toolbar usable (Task 1, Task 2).
- Save dialog cancelled, or save to an unwritable folder, then saved again: drawing kept, no temp files left (Task 3).
- Quit with one window annotating and another idle: the idle one closes, the first asks (Task 3).

---

### Task 1: Drawing model and renderer

**Files:** Create `src/annotation/annotated-image.vala`, `tests/test-annotated-image.vala`. Modify `src/meson.build`, `tests/meson.build` (source: only the new file; deps: gtk+-3.0).

**Interfaces — Produces** (namespace `Peek.Annotations`):
- `enum Tool { RECTANGLE, CIRCLE, LINE, ARROW, BLUR, TEXT }`
- `class Annotation : Object { Tool tool; double x1, y1, x2, y2; Gdk.RGBA color; int width; string text; }`, public properties, coordinates in image pixels, `width` unscaled
- `class AnnotatedImage : Object`: `AnnotatedImage (Gdk.Pixbuf source, int scale)`; `int width`, `int height`; `signal void changed ()`; `void add (Annotation a)`, `undo ()`, `redo ()`; `bool can_undo`, `can_redo`; `bool has_unsaved_changes`, `void mark_copied ()`; `void draw (Cairo.Context cr, Annotation? preview = null)`; `Gdk.Pixbuf render ()`; `void constrain (Annotation a, bool shift)`
- `double fit_scale (int image_w, int image_h, int view_w, int view_h, int device_scale)`: logical pixels per image pixel, `min (1.0 / device_scale, view_w / image_w, view_h / image_h)`

- [ ] **Step 1: Failing tests** in `/annotated-image/…`, on a 200×100 gray (#808080) pixbuf, scale 1:
  - `undo_redo`: add two → `can_undo`; undo → `can_redo`; add → `!can_redo`; undo on an empty image is a no-op.
  - `unsaved`: new is false; add → true; `mark_copied` → false; add → true; undo back to the copied state → false; undo everything after copy → false.
  - `constrain`: rectangle (10,10)→(50,30) with shift → (50,50); (50,50)→(20,40) → (20,20); line (0,0)→(50,4) shift → y2 ≈ 0; line (0,0)→(40,37) shift → x2 ≈ y2. Without shift, (10,10)→(500,-5) clamps to (200,0). Blur ignores shift. Shifted results stay inside the image and square: (10,90)→(150,95) gives (20,100).
  - `rectangle`: red, width 4, (20,20)→(80,60): pixel (20,40) is red, (50,40) and (150,80) still #808080, `render ()` is 200×100 with 3 channels.
  - `circle`: (20,20)→(80,60): (20,40) red, (50,40) and (21,21) unchanged.
  - `line_arrow`: (20,50)→(150,50): both paint (80,50); only the arrow paints within 12 px of the tip off-axis, at some pixel with |y-50| > 4.
  - `text`: "Hello" at (20,20) changes at least one pixel in (20,20)–(120,60) and none in the bottom right 40×20.
  - `blur`: source with 2 px black/white vertical stripes; blur (40,20)–(120,80): every pixel in (48..112, 28..72) within 96..160; pixel (10,10) unchanged.
  - `blur_order`: rectangle first, then a blur covering it: the rectangle's edge pixel is still red. Two overlapping blurs on the stripes: overlap within 96..160.
  - `blur_small`: 1×1, 3×2 and zero-size regions, and one at the image corner, don't crash; also on a 2×2 image.
  - `scaled`: scale 2, width 2: a horizontal line is 4 px thick.
  - `fit_scale`: (1000,500,500,500,1) → 0.5; (100,100,500,500,1) → 1.0; (100,100,500,500,2) → 0.5.
- [ ] **Step 2:** `ninja -C $B` fails on the missing class.
- [ ] **Step 3: Implement.** Blur: round the region outward and clip it to the source, scale that sub-pixbuf down to `max (1, size / (16 × scale))` per axis and back up, both `Gdk.InterpType.BILINEAR`; paint opaque. Cache the surface per added annotation; the preview is not cached. Arrow head: two strokes of `(8 + 3 × width) × scale` at ±2.6 rad from the direction. Strokes have round caps and joins. Text: Pango layout, `sans bold`, `set_absolute_size`, (x1,y1) is its top left. `render ()` uses an RGB24 `ImageSurface`. When shift would leave the image, shorten the square or the snapped line until it fits.
- [ ] **Step 4:** `meson test -C $B` passes.
- [ ] **Step 5:** Commit `feat(core): Add drawing model for image annotations`.

### Task 2: Annotation window

**Files:** Create `src/ui/annotation-window.vala`, `ui/annotation-window.ui`, `ui/icons/` symbolic SVGs (rectangle, circle, line, arrow, blur, text). Modify `ui/peek.gresource.xml`, `ui/css/peek.css`, `src/meson.build`, `data/com.uploadedlobster.peek.gschema.xml`, `po/POTFILES.in`.

**Interfaces**
- Consumes: Task 1.
- Produces: `class Peek.Ui.AnnotationWindow : Gtk.Window`: `AnnotationWindow (Gtk.Window parent, Gdk.Pixbuf pixbuf, int scale, string format_name)`; `signal void save_requested ()`, `cancelled ()`, `cancel_refused ()`, `encode_cancel_requested ()`; `Gdk.Pixbuf render ()` (confirms pending text first); `bool busy { get; set; }`; `void request_cancel ()` (emits `cancelled` or `cancel_refused`, possibly later).
- Settings: `annotation-color` (s, `'#e01b24'`), `annotation-line-width` (i, 2–7, default 4).

- [ ] **Step 1: Layout** per the spec and artboard A. Tools and widths are radio-style buttons, colors are buttons plus a `GtkColorButton` without alpha. Buttons have `focus-on-click` false, tooltips and accessible names; initial focus is the drawing area. An unparsable `annotation-color` falls back to red. Do not set `application` on this window; it has `destroy-with-parent`.
- [ ] **Step 2: Canvas.** `GtkDrawingArea` in a `GtkOverlay`, image centered at `fit_scale`. Pointer → image coordinates, then `constrain`. Presses outside the image start nothing. Ignore drags under 4 logical pixels. Draw only with the primary button.
- [ ] **Step 3: Text.** A `GtkEntry` in the overlay at the click, in the current style. Activate, a click elsewhere, or a tool change commits; Esc discards; blank adds nothing. It takes the color and width selected when committed.
- [ ] **Step 4: Keys.** Ctrl+S, Enter (unless a button or the entry has focus), Esc, Ctrl+Z, Ctrl+Shift+Z, R C L A B T. While the entry has focus only Ctrl+S is handled here, plus Ctrl+C when the entry has no selection.
- [ ] **Step 5: Copy.** `Gtk.Clipboard` `set_image (render ())`, `set_can_store (null)`, `store ()`, `mark_copied ()`; status bar reads "Image copied to the clipboard."
- [ ] **Step 6: Cancel and busy.** `request_cancel`: while typing, text counts as a change; if unsaved, a non-blocking modal `MessageDialog` "Discard annotations?" with Cancel and Discard; a second call while it is open presents it. Window close and Esc call it. While `busy`, everything but the Cancel button is insensitive and Cancel, Esc emit `encode_cancel_requested`; close emits that too, and the owner decides (Task 3).
- [ ] **Step 7: Size** per the spec, using `Gdk.Screen.get_monitor_workarea`.
- [ ] **Step 8:** Build is warning-free for the new files; schema compiles; tests pass. Interactive checks happen in Task 3, once the window is reachable.
- [ ] **Step 9:** Commit `feat(ui): Add annotation window`.

### Task 3: Snapshot flow

**Files:** Modify `src/ui/application-window.vala`, `src/application.vala`.

**Interfaces — Consumes:** Task 2. **Produces:** private `enum SnapshotState { NONE, ANNOTATING, ENCODING, CHOOSING, COPYING }`.

- [ ] **Step 1: Flow.** Replace `save_snapshot` with `annotate_snapshot ()` (grab, open window, ANNOTATING) and `async encode_annotated ()` (ENCODING, new `Snapshot` per attempt, then `show_file_chooser`). Add `discard_temp_file ()`, shared with `leave_recording_state`, which also destroys the annotation window and resets the state. For images the chooser's parent is the annotation window; chooser cancel, encode error, encode cancel and copy failure all call `discard_temp_file ()` and return to ANNOTATING. A grab error behaves as today. Only a successful copy or `cancelled` leaves the recording state. `ErrorDialog` gets the Peek window as parent.
- [ ] **Step 2: Outside events** by state:

| | Peek close / quit | `--stop`, Stop button | `--start`, `--toggle`, shortcut |
|---|---|---|---|
| ANNOTATING | `close_requested = true`, `request_cancel ()` | `request_cancel ()` | `present ()` the window |
| ENCODING | cancel encode, then as ANNOTATING | cancel encode, then as ANNOTATING | `present ()` |
| CHOOSING | refuse (`return true`) | ignore | ignore |
| COPYING | hide both windows, close when done | ignore | ignore |

  Closing the annotation window while ENCODING cancels the encode, then `request_cancel ()`; its Cancel button only cancels the encode. `cancel_refused` clears `close_requested`. A failed copy shows both windows again and clears it. If the encode finishes just as it is cancelled, the cancel wins. The Stop button stays sensitive in ANNOTATING and ENCODING.
- [ ] **Step 3: Quit.** `request_quit` iterates over a copy of the window list and closes only `ApplicationWindow`s.
- [ ] **Step 4: Verify on Xvfb** with a window manager and `GDK_BACKEND=x11`, isolated `XDG_CONFIG_HOME` and D-Bus session, driven by xdotool, keeping screenshots and raw output in the scratchpad. Missing tools: install the RPMs.
  - Each tool, Shift, undo/redo, custom color, remembered color and width across a restart.
  - Save in all four formats: type, dimensions, pixels, one GIF frame. No edits: PNG equals a plain grab.
  - Copy, paste with xclip as PNG: same pixels as a saved PNG. Pending text is in both.
  - Every row and column of the table; ENCODING with a fake slow ffmpeg as in `test_encode_cancel`.
  - Each Review Focus line. Temp dir is empty of Peek files afterwards.
  - `GDK_SCALE=2`, a tiny and a full-screen capture, start delay, dark and light theme.
  - Animated GIF recording, its cancel, and closing during its rendering, as before.
- [ ] **Step 5:** Commit `feat(ui): Annotate snapshots before saving`.

### Task 4: Documentation and translations

**Files:** Modify `README.md`, `data/man/peek.1.txt`, `CHANGES.md`, `po/peek.pot`, `po/it.po`.

- [ ] **Step 1:** Describe the tools, Save and Copy, and the shortcuts. Say that blurred text can sometimes be recovered, and that the clipboard needs a clipboard manager to outlive Peek. Do not bump the version or the RPM release.
- [ ] **Step 2:** Regenerate the pot, `msgmerge` only `it.po`, translate all new strings. `msgfmt --check po/it.po` reports no errors, no fuzzy or untranslated new entries.
- [ ] **Step 3:** Full build and tests pass. Commit `docs: Describe snapshot annotation` and `i18n: Add Italian translations for annotation`.
