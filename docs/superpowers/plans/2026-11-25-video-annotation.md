# Recording Annotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optionally annotate a recording on a timeline before it is saved, and release it as Peek 1.6.0.

**Architecture:** A display-free `AnnotatedRecording` extends the existing `AnnotatedImage` with frame ranges. `RecordingReader` gets frame times and single frames from ffprobe/ffmpeg; `RecordingExporter` burns the items in and then runs the existing conversion. The recorder can hand over its raw file instead of converting it, and `ApplicationWindow` drives the existing annotation flow with it.

**Tech Stack:** Vala, GTK 3.20+, Cairo, GLib.Test, Meson, ffmpeg and ffprobe executables.

**Spec:** `docs/superpowers/specs/2026-11-25-video-annotation-design.md`

## Global Constraints

- GTK 3.20, X11. No new dependency. Needs both `ffmpeg` and `ffprobe` at run time, otherwise the preference is insensitive and treated as off.
- Preference off by default; with it off, recordings behave exactly as before.
- Every number in an ffmpeg argument or parsed from its output is locale independent: `double.format (buf, "%.6f")` and `double.parse`, never `printf ("%f")`.
- New ffmpeg calls use `-nostdin -v error`: `CliPostProcessor` does not read its pipe while waiting, so chatty output would block ffmpeg.
- A range is first to last frame, both included, at least one frame.
- Blur: from captured pixels only, opaque, blocks of 16 × scale px, below all other items.
- The captured file is kept until the save succeeds or the user discards it. All temporary files are deleted on every path.
- Existing tests stay green. No attribution lines in commits. Subjects like `feat(core): …`.
- GUI checks isolate HOME, all XDG_* dirs, XDG_RUNTIME_DIR, TMPDIR and D-Bus, set GIO_USE_VFS=local, use a private Xvfb, and kill only by pid.
- Build and test: `meson setup build-dir -Dbuild-tests=true` outside the repo, then `meson test -C build-dir`.

## Review Focus

- **Comma decimal locale (Italian):** overlay times and seeks must use dots. Pinned in Tasks 2 and 3.
- **Video whose first timestamp is not 0 (sound starts first):** items stay on their frames; times are relative to the container's start. Pinned in Tasks 2 and 3.
- **Blur at odd coordinates in 4:2:0 video:** no row or column at the edge shows the original. Pinned in Task 3.
- **Cancelled save dialog with no items (WebM/MP4):** the returned file *is* the captured file and must not be deleted. Pinned in Task 6.
- **Closing Peek between Stop and the window opening:** asks, never drops the recording or leaks it. Checked in Task 6.

## File Structure

| File | Responsibility |
|---|---|
| `src/annotation/annotated-image.vala` (modify) | Snapshot history, replaceable source, visibility hook, single item rendering |
| `src/annotation/annotated-recording.vala` | Frame times, playhead, ranges |
| `src/recording/recording-reader.vala` | Frame times and frames of a file |
| `src/post-processing/burn-in-post-processor.vala` | ffmpeg graph and run |
| `src/recording/recording-exporter.vala` | Burn-in + conversion, cancel, temp files |
| `src/recording/*.vala`, `src/post-processing/*.vala` (modify) | Handover of the captured file, config copy, pipeline fixes |
| `src/ui/recording-timeline.vala` | Slider, step buttons, item rows |
| `src/ui/annotation-window.vala` (modify) | Recording mode |
| `src/ui/application-window.vala`, preferences, gschema (modify) | Flow and preference |

---

### Task 1: Timed annotation model

**Files:**
- Modify: `src/annotation/annotated-image.vala`, `src/meson.build`, `tests/meson.build`
- Create: `src/annotation/annotated-recording.vala`
- Test: `tests/test-annotated-recording.vala`, `tests/test-annotated-image.vala` (unchanged, must pass)

**Interfaces — Produces:**
- `Annotation`: new `int id` (set by `add`, unique per image, starting at 1), `int first_frame`, `int last_frame`; `Annotation copy ()`.
- `AnnotatedImage`: `protected GenericArray<Annotation> items`; history holds whole item arrays; `protected virtual bool is_visible (Annotation a)` (default true); `public virtual void add (Annotation a)`; `public Gdk.Pixbuf render_item (Annotation a)` (transparent, image size, with alpha); `public Gdk.Rectangle? get_blur_region (Annotation a)` (the integer region `create_blur` uses today, null if empty); `public Gdk.Rectangle get_bounds (Annotation a)` (includes line width, arrow head, Pango extents of text); `public void set_source (Gdk.Pixbuf source)` (same size, emits `changed`; cached blurs of another source are not reused); `public int scale { get; }`.
- `AnnotatedRecording : AnnotatedImage`: `AnnotatedRecording (Gdk.Pixbuf first_frame, int scale, double[] times)`; `int n_frames`; `int current_frame { get; set; }` (clamped, emits `changed`); `double get_time (int frame)`; `double duration`; `int frame_at (double time)` (last frame whose time is ≤ `time`); `Annotation[] get_items ()`; `Annotation? find (int id)`; `void remove (int id)`; `void begin_range_change ()`; `void change_range (int id, bool start, int frame)`; `void end_range_change ()`; `void cancel_range_change ()`; `bool has_items`.
- `duration` is the last time plus the last frame interval (0 for one frame).

- [ ] **Step 1: Write failing tests**, with 10 frames at 0, 0.5 … 4.5 s unless stated:
  - `/annotated-recording/default-range`: at frame 1 a rectangle gets 1–6 (the last frame with time < start + 3 s); at frame 8 it gets 8–9; a blur at frame 8 gets 0–9.
  - `/annotated-recording/variable-rate`: times 0, 0.1, 2.9, 3.0, 9.0; item at 0 gets 0–2. `frame_at (2.95) == 2`, `frame_at (-1) == 0`, `frame_at (99) == 4`.
  - `/annotated-recording/range-limits`: `change_range (id, true, 8)` on 1–6 gives 6–6; `(id, false, 0)` then gives 6–6; frames clamp to 0…9.
  - `/annotated-recording/range-undo`: begin, three changes, end → one undo restores 1–6; redo reapplies; begin/end without change adds no undo step; cancel restores.
  - `/annotated-recording/remove-undo`: remove, undo → item is back with the same `id` and stacking position.
  - `/annotated-recording/visible`: pixel inside a range 2–4 item is drawn at frames 2 and 4, not at 1 and 5; blur likewise; a `preview` is always drawn.
  - `/annotated-recording/blur-source`: after `set_source` with another image the blur shows the new image's colors.
  - `/annotated-recording/render-item`: alpha 0 outside the shape, red and opaque on it, size equals the image.
  - `/annotated-recording/single-frame`: one time; item gets 0–0, duration 0.
- [ ] **Step 2:** Run `meson test`; expected: build fails, class missing.
- [ ] **Step 3: Implement.** Undo is two stacks of immutable item arrays; `begin_range_change` keeps the current array and `change_range` swaps in a new array with a copied item. `mark_copied`/`has_unsaved_changes` keep today's behavior.
- [ ] **Step 4:** `meson test`; expected: all pass, including the untouched image tests.
- [ ] **Step 5: Commit** `feat(core): Add annotations with frame ranges`

---

### Task 2: Read frame times and frames

**Files:**
- Create: `src/recording/recording-reader.vala`
- Modify: `src/meson.build`, `tests/meson.build`
- Test: `tests/test-recording-reader.vala`

**Interfaces — Produces:**
- `Peek.Recording.RecordingReader : Object`: `RecordingReader (File file)`; `static bool is_available ()` (both executables); `async double[] read_times () throws RecordingError`; `async Gdk.Pixbuf read_frame (int frame) throws RecordingError`; `void request_frame (int frame)`; signals `frame_ready (int frame, Gdk.Pixbuf pixbuf)`, `frame_failed (int frame, string message)`; `void close ()` (kills ffmpeg, no signals afterwards).
- `static double[] parse_times (string output)`; `static string get_seek_time (double[] times, int frame)`.

**Values**
- Times: `ffprobe -v error -select_streams v:0 -show_entries frame=best_effort_timestamp_time:format=start_time -of default=nw=1 FILE`. Frames, not packets, as hidden VP8 packets show nothing. Subtract `start_time` (`N/A` counts as 0), ignore `N/A` frames, sort, drop duplicates. No frames is an error.
- Frame: `ffmpeg -nostdin -v error -ss SEEK -i FILE -frames:v 1 -f image2pipe -c:v png -`, read with `Subprocess.communicate_async`, decoded with `Gdk.PixbufLoader`. `SEEK` is halfway between the previous frame and this one; no `-ss` for frame 0.
- `request_frame`: one ffmpeg at a time; while busy only the latest request is remembered.

- [ ] **Step 1: Write failing tests.** Without ffmpeg: `parse_times` (unsorted input, `start_time=0.5`, `N/A`, duplicates, empty → empty array) and `get_seek_time` (dot under `it_IT.UTF-8` when that locale exists). With ffmpeg, `Test.skip` otherwise, on generated lossless clips whose frame *n* has gray `n * 10`: `read_times` count and values for constant rate, for a variable-rate clip, and for an MP4 whose video starts 0.5 s after its sound (first time 0.5); `read_frame` gives the right gray for the first, a middle and the last frame of each; requesting 1, 2, 3, 4 at once yields `frame_ready` for 1 and 4 only; a missing file throws; no signal after `close`.
- [ ] **Step 2:** Run; expected: build fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run; expected: pass.
- [ ] **Step 5: Commit** `feat(core): Read frames of a recording`

---

### Task 3: Burn-in and export

**Files:**
- Create: `src/post-processing/burn-in-post-processor.vala`, `src/recording/recording-exporter.vala`
- Modify: `src/recording/ffmpeg.vala`, `src/recording/recording-config.vala`, `src/recording/base-screen-recorder.vala`, `src/post-processing/post-processing-pipeline.vala`, `src/post-processing/ffmpeg-post-processor.vala`, `src/meson.build`, `tests/meson.build`
- Test: `tests/test-recording-exporter.vala`

**Interfaces**
- Consumes: Task 1 model; in tests, Task 2 reader.
- Produces:
  - `RecordingConfig copy ()`.
  - `Ffmpeg.add_codec_parameters (Array<string> args, RecordingConfig config)`: everything `add_output_parameters` adds except `-r`; the latter calls it.
  - `PostProcessingPipeline.keep_input { get; set; default = false; }`: do not delete the files passed to `process_async`.
  - `PostProcessingPipeline.add_conversion (RecordingConfig config)`: the steps now in `build_post_processor_pipeline`, which calls it.
  - `BurnInPostProcessor (AnnotatedRecording recording, RecordingConfig config)`; `static string[] build_arguments (AnnotatedRecording recording, RecordingConfig config, string input, string[] png_files, string output)`.
  - `interface AnnotationEncoder : Object { abstract bool is_cancelled { get; } abstract void cancel (); }`, implemented by `Snapshot` and `RecordingExporter` (put it in `snapshot.vala`'s sibling `src/recording/annotation-encoder.vala`).
  - `RecordingExporter (File captured, RecordingConfig config)`; `async File export (AnnotatedRecording recording) throws RecordingError`. Returns `captured` itself when nothing has to be done. Never deletes `captured`.

**Values**
- Graph: `[0:v]format=gbrp` first and every overlay `format=gbrp`, for all formats, as 4:2:0 would round odd positions. Blurs first, each `crop` from the untouched frames (`split`) with the `get_blur_region` rectangle, scaled bilinearly to `max (1, size / (16 × scale))` and back, overlaid; then one overlay per PNG in drawing order.
- Enable: `enable='gte(t,A)*lt(t,B)'`, A and B halfway between neighboring frame times; A is `-1` for frame 0, B is `1000000000` for the last frame. Overlay `eof_action=repeat`.
- Output: `-map [v] -map 0:a? -c:a copy -fps_mode passthrough -enc_time_base -1`. GIF/APNG: `-c:v ffv1` to a temporary `mkv`. WebM/MP4: `add_codec_parameters`, and for VAAPI `add_vaapi_device` plus `format=nv12,hwupload` at the end of the graph. If a flag does not keep variable frame times, the tests decide: replace the flag, not the requirement.

- [ ] **Step 1: Write failing argument tests** (no ffmpeg): GIF, APNG, WebM, MP4 h264/hevc/av1, MP4 VAAPI; exact `enable` strings for ranges 0–0, 2–4 and to the last frame; blurs precede shapes whatever the drawing order; no `-r`; dots under `it_IT.UTF-8`; `add_output_parameters` output is unchanged for every format.
- [ ] **Step 2: Write failing ffmpeg tests** (skipped without it), checking decoded frames:
  - item 2–4 is on frames 2 and 4, not on 1 and 5, for constant rate, variable rate, and an MP4 whose video starts 0.5 s after its sound;
  - blur at odd x, y, width and height over 1 px stripes: in WebM and MP4 every pixel of the region on every frame of the range lies within 96…160, also with another blur overlapping it;
  - frames outside all ranges are identical in the `ffv1` intermediate;
  - frame times (±1 ms) and the sound packets' MD5 (`-map 0:a -c copy -f md5`) are unchanged;
  - no items: WebM returns the captured file, GIF is converted and the captured file still exists;
  - failure (missing input) and cancel during export throw or set `is_cancelled`, keep the captured file, and leave no other file in the temp dir; same for GIF cancelled during palette use.
- [ ] **Step 3:** Run; expected: build fails.
- [ ] **Step 4: Implement.** Also fix two leaks on the way: `FfmpegPostProcessor` leaves the palette when the second step fails, and the pipeline leaves the previous step's output when cancelled between steps.
- [ ] **Step 5:** Run; expected: all pass.
- [ ] **Step 6: Commit** `feat(core): Burn annotations into recordings`

---

### Task 4: Recorder hands over the captured file

**Files:**
- Modify: `src/recording/screen-recorder.vala`, `src/recording/base-screen-recorder.vala`, `src/recording/gnome-shell-dbus-recorder.vala`
- Test: `tests/screen-recorder/test-cli-screen-recorder.vala`

**Interfaces — Produces (on `ScreenRecorder`):**
- `bool defer_post_processing { get; set; }`, default false.
- `signal void recording_captured (File file)`: emitted instead of post processing when deferred; the receiver owns the file.
- `RecordingConfig encoding_config { get; }`: copy made in `record ()`, so later changes of settings do not matter. The GNOME Shell recorder's copy has `mp4_codec = "h264"` and `mp4_vaapi = false`.
- `void post_process (File file)`: runs the normal post processing on a captured file, emitting the usual signals.

- [ ] **Step 1: Write failing tests** with a mock recorder: deferred → `recording_captured` once, no `recording_postprocess_started`, no `recording_finished`; a later `cancel ()` neither deletes the file nor emits `recording_aborted`; `post_process` then emits started and finished; not deferred → signals as today; changing `config.mp4_codec` after `record` leaves `encoding_config` unchanged.
- [ ] **Step 2:** Run; expected: build fails.
- [ ] **Step 3: Implement** in `finalize_recording`; clear `temp_file` before emitting.
- [ ] **Step 4:** Run; expected: pass.
- [ ] **Step 5: Commit** `feat(core): Hand over recordings before conversion`

---

### Task 5: Timeline in the annotation window

**Files:**
- Create: `src/ui/recording-timeline.vala`
- Modify: `src/ui/annotation-window.vala`, `src/ui/application-window.vala` (constructor call only), `ui/annotation-window.ui`, `ui/css/peek.css`, `src/meson.build`, `po/POTFILES.in`

**Interfaces**
- Consumes: `AnnotatedRecording`, `RecordingReader`.
- Produces: `AnnotationWindow.for_recording (Gtk.Window parent, AnnotatedRecording recording, RecordingReader reader, string format_name)`; `AnnotatedRecording? recording { get; }`; `void confirm_pending ()` (commits text, for export). Signals as for snapshots. The existing constructor keeps its signature.
- `RecordingTimeline : Gtk.Box`: `RecordingTimeline (AnnotatedRecording recording)`; `int selected_id { get; set; }` (0 = none); signal `frame_changed (int frame)`; `void step (int frames)`; `void step_seconds (int seconds)`; `void set_range_end (bool start)` (at the playhead).

**Behavior**
- Title "Annotate recording"; Copy hidden and Ctrl+C inactive; timeline above the status bar, counted by `set_initial_size`.
- Times as `00:04.20`, "Frame 63" (one-based). Slider covers frames. Rows: tool icon, name (text items: their text, ellipsized), bar; scroll beyond four rows. "Start here" and "End here" are insensitive without a selection.
- Bar ends are draggable with a 6 px handle; a drag calls begin/change/end of Task 1 and moves the playhead; Esc during it cancels it.
- Keys when not typing: Left/Right one frame, Shift+Left/Right one second, Home/End, Delete removes the selected item. They work wherever the focus is except in the text entry.
- Moving first commits pending text at the old frame; moves are ignored during a canvas drag. Presses on the canvas are ignored until `frame_ready` for the playhead. Items are drawn for the playhead.
- A new item is selected. The selection's bounds are outlined (dashed, not in the output) when it is visible. Undo of the selected item clears the selection.
- `frame_failed`: status bar "This frame could not be read.", old frame stays.
- `request_cancel` always asks "Discard recording?" with "_Keep" (default) and "_Discard". Busy also disables the timeline.
- `reader.close ()` on destroy. Accessible names for slider, step buttons, rows.

- [ ] **Step 1: Implement timeline and window.**
- [ ] **Step 2: Build and run `meson test`;** expected: all pass, no new compiler warnings.
- [ ] **Step 3: GUI check** in the isolated Xvfb with a scratch harness (not committed) opening the window on a generated 60-frame clip: each behavior above; screenshots at 440 px and full HD width, dark theme, `GDK_SCALE=2`, six items. Snapshot window is unchanged.
- [ ] **Step 4: Commit** `feat(ui): Add a timeline to the annotation window`

---

### Task 6: Flow and preference

**Files:**
- Modify: `src/ui/application-window.vala`, `src/application.vala`, `src/ui/preferences-dialog.vala`, `ui/preferences.ui`, `data/com.uploadedlobster.peek.gschema.xml`

**Interfaces — Consumes:** everything above.

**Values**
- Key `annotation-recordings` (`b`, default `false`); check button "Annotate recordings" in Preferences, insensitive unless `RecordingReader.is_available ()`.
- `SnapshotState` becomes `AnnotationState` with a new `OPENING`, set when a deferred recording is stopped and left when the window opens. `active_snapshot` becomes `AnnotationEncoder? active_encoder`. New `File? captured_file`.
- Item scale: `int.max (1, scale factor / encoding_config.downsample)`.

**Behavior**
- `start_recording` sets `recorder.defer_post_processing` from the setting and availability, and `snapshot_format` when deferring.
- `recording_captured` → spinner → `read_times`, `read_frame (0)` → window, `ANNOTATING`. On failure: error dialog, `captured_file = null`, state `NONE`, `recorder.post_process (file)`.
- Save: `confirm_pending`, then `RecordingExporter`, then the existing dialog and copy. Errors say "The recording could not be created."
- `discard_temp_file` must not delete `in_file` when it equals `captured_file`; `captured_file` is deleted in `leave_recording_state` and on application shutdown.
- `OPENING`: close and quit set `close_requested`, and `--stop` a cancel, both acted on as Cancel (asks) once the window is open; toggle, start and shortcut do nothing. A refusal clears them. If opening fails, a requested close hides Peek until saved, as today while post processing.
- All other outside events as for snapshots.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: `meson test`;** expected: all pass.
- [ ] **Step 3: GUI check** in the isolated Xvfb, with the real ffmpeg recorder; after each case the temp dir holds no leftover files:
  - preference off: GIF and WebM as before, save dialog during conversion;
  - on, for GIF, GIF with gifski (if installed), APNG, WebM, MP4: one item and one blur, saved frames checked; the same without items (WebM file identical to the captured one);
  - **save dialog cancelled without items in WebM, then saved: works;** cancelled with items, then saved;
  - unwritable target, failing ffmpeg (stub first on PATH), Cancel during export, Cancel kept and discarded;
  - close, quit, `--stop`, `--toggle` in OPENING, ANNOTATING, ENCODING;
  - settings changed while annotating do not change the output; downsample 2; `GDK_SCALE=2`; sound; one-second and five-minute recordings;
  - ffprobe missing from PATH: preference insensitive, recording as if off; broken captured file: error, then normal saving is attempted;
  - snapshot annotation: save, copy, cancel.
- [ ] **Step 4: Commit** `feat(ui): Annotate recordings before saving`

---

### Task 7: Documentation and Italian

**Files:** `README.md`, `data/man/peek.1.txt`, `CHANGES.md`, `po/peek.pot`, `po/it.po`

- [ ] **Step 1:** Describe the preference, timeline, shortcuts, and limits (no playback, items do not move, second lossy encode for WebM/MP4, short items on GNOME Shell GIFs). `CHANGES.md` 1.6.0: `- feat: Annotate recordings on a timeline before saving`; replace the "Removed MP4 recording option…" line with `- feat: MP4 recording with H.264, HEVC or AV1, optionally using VAAPI`.
- [ ] **Step 2:** Regenerate the pot as in f8cceb0, merge `it.po` only, translate all new strings; `msgfmt --check -o /dev/null po/it.po` reports no fuzzy or untranslated new entry.
- [ ] **Step 3:** Commit `docs: Describe recording annotation` and `i18n: Add Italian translations for recording annotation`

---

### Task 8: Version 1.6.0

**Files:** `meson.build`, `rpm/peek.spec`, `README.md`, `CHANGES.md`, `data/com.uploadedlobster.peek.appdata.xml.in`

- [ ] **Step 1:** `meson.build` `1.6.0`; spec `Version: 1.6.0`, `Release: 1%{?dist}`, the uncommitted 1.5.1-22 entry becomes `1.6.0-1` with `- Annotate image snapshots and recordings`; README RPM link `v1.6.0-1/peek-1.6.0-1.fc44.x86_64.rpm` and source archive `peek-1.6.0`; `CHANGES.md` heading and appdata `<release version="1.6.0">` with the date of the commit. Leave the flatpak file.
- [ ] **Step 2:** `meson test` passes; `peek --version` in the build prints 1.6.0; `appstream-util validate-relax --nonet` on the built appdata passes; `rpmbuild -ba` in the scratchpad gives `peek-1.6.0-1.fc44.x86_64.rpm`.
- [ ] **Step 3:** Commit `build: Bump version to 1.6.0`. Do not push, tag, publish or install.
