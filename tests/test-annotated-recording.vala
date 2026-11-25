using Peek.Annotations;

const int RED = 0xff0000;
const int GRAY = 0x808080;

Gdk.Pixbuf create_frame (uint32 color = (uint32) 0x808080ff) {
  var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 200, 100);
  pixbuf.fill (color);
  return pixbuf;
}

// Left half black, right half white
Gdk.Pixbuf create_halves () {
  var pixbuf = create_frame ((uint32) 0x000000ff);
  new Gdk.Pixbuf.subpixbuf (pixbuf, 100, 0, 100, 100).fill ((uint32) 0xffffffff);
  return pixbuf;
}

AnnotatedRecording create_recording (Gdk.Pixbuf? frame = null) {
  return new AnnotatedRecording (
    frame ?? create_frame (), 1, { 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5 });
}

Annotation create (Tool tool, int width = 4) {
  return new Annotation () {
    tool = tool, x1 = 20, y1 = 20, x2 = 80, y2 = 60, color = { 1, 0, 0, 1 }, width = width
  };
}

Annotation add (AnnotatedRecording recording, int frame, Tool tool = Tool.RECTANGLE) {
  var annotation = create (tool);
  recording.current_frame = frame;
  recording.add (annotation);
  return annotation;
}

int get_pixel (Gdk.Pixbuf pixbuf, int x, int y) {
  unowned uint8[] pixels = pixbuf.get_pixels_with_length ();
  var offset = y * pixbuf.rowstride + x * pixbuf.n_channels;
  return pixels[offset] << 16 | pixels[offset + 1] << 8 | pixels[offset + 2];
}

int get_alpha (Gdk.Pixbuf pixbuf, int x, int y) {
  unowned uint8[] pixels = pixbuf.get_pixels_with_length ();
  return pixels[y * pixbuf.rowstride + x * 4 + 3];
}

void assert_range (AnnotatedRecording recording, int id, int first, int last) {
  var annotation = recording.find (id);
  assert (annotation != null);
  assert (annotation.first_frame == first);
  assert (annotation.last_frame == last);
}

void test_default_range () {
  var recording = create_recording ();
  assert (recording.n_frames == 10);
  assert (recording.duration == 5);
  assert (recording.get_time (3) == 1.5);
  assert (!recording.has_items);

  add (recording, 1);
  add (recording, 8);
  add (recording, 8, Tool.BLUR);
  assert (recording.has_items);
  assert (recording.get_items ().length == 3);
  assert_range (recording, 1, 1, 6);
  assert_range (recording, 2, 8, 9);
  assert_range (recording, 3, 0, 9);
  assert (recording.find (4) == null);
}

void test_current_frame () {
  var recording = create_recording ();
  int changes = 0;
  recording.changed.connect (() => { changes++; });
  recording.current_frame = 4;
  assert (changes == 1);
  recording.current_frame = 99;
  assert (recording.current_frame == 9);
  recording.current_frame = -1;
  assert (recording.current_frame == 0);
  assert (changes == 3);
}

// Items in the history must stay as they are
void test_add_again () {
  var recording = create_recording ();
  var annotation = add (recording, 1);
  recording.current_frame = 8;
  recording.add (annotation);
  assert_range (recording, 1, 1, 6);
  assert_range (recording, 2, 8, 9);
  assert (annotation.id == 1);
}

void test_variable_rate () {
  var recording = new AnnotatedRecording (create_frame (), 1, { 0, 0.1, 2.9, 3.0, 9.0 });
  add (recording, 0);
  assert_range (recording, 1, 0, 2);
  assert (recording.frame_at (2.95) == 2);
  assert (recording.frame_at (3.0) == 3);
  assert (recording.frame_at (-1) == 0);
  assert (recording.frame_at (99) == 4);
  assert (recording.duration == 15);
}

void test_range_limits () {
  var recording = create_recording ();
  add (recording, 1);
  recording.begin_range_change ();
  recording.change_range (1, true, 8);
  assert_range (recording, 1, 6, 6);
  recording.change_range (1, false, 0);
  assert_range (recording, 1, 6, 6);
  recording.change_range (1, true, -5);
  assert_range (recording, 1, 0, 6);
  recording.change_range (1, false, 99);
  assert_range (recording, 1, 0, 9);
  recording.change_range (42, false, 3);
  recording.end_range_change ();
}

void test_range_undo () {
  var recording = create_recording ();
  add (recording, 1);
  add (recording, 2);
  recording.mark_copied ();

  recording.begin_range_change ();
  recording.change_range (1, false, 7);
  recording.change_range (1, false, 8);
  recording.change_range (1, false, 9);
  recording.end_range_change ();
  assert_range (recording, 1, 1, 9);
  assert (recording.get_items ()[0].id == 1);
  assert (recording.has_unsaved_changes);

  recording.undo ();
  assert_range (recording, 1, 1, 6);
  assert (!recording.has_unsaved_changes);
  assert (recording.can_redo);

  // Nothing changed, so there is no step and redo is kept
  recording.begin_range_change ();
  recording.end_range_change ();
  recording.begin_range_change ();
  recording.change_range (1, false, 8);
  recording.change_range (1, false, 6);
  recording.end_range_change ();
  assert (recording.can_redo);

  recording.begin_range_change ();
  recording.change_range (1, true, 3);
  assert_range (recording, 1, 3, 6);
  recording.cancel_range_change ();
  assert_range (recording, 1, 1, 6);
  assert (!recording.has_unsaved_changes);

  recording.redo ();
  assert_range (recording, 1, 1, 9);
  recording.undo ();
  recording.undo ();
  recording.undo ();
  assert (!recording.can_undo);
  assert (!recording.has_items);
}

// Anything else that is done during a change ends it
void test_range_interrupted () {
  var recording = create_recording ();
  add (recording, 1);
  recording.begin_range_change ();
  recording.change_range (1, false, 9);
  recording.undo ();
  assert_range (recording, 1, 1, 6);
  recording.end_range_change ();
  recording.redo ();
  assert_range (recording, 1, 1, 9);

  recording.begin_range_change ();
  recording.change_range (1, false, 8);
  add (recording, 0);
  recording.cancel_range_change ();
  assert_range (recording, 1, 1, 8);
  assert (recording.get_items ().length == 2);
  recording.undo ();
  assert_range (recording, 1, 1, 8);
  recording.undo ();
  assert_range (recording, 1, 1, 9);

  // Without begin a change is a step on its own
  recording.change_range (1, false, 5);
  recording.undo ();
  assert_range (recording, 1, 1, 9);
}

void test_remove_undo () {
  var recording = create_recording ();
  add (recording, 1);
  add (recording, 2);
  add (recording, 3);
  recording.remove (2);
  assert (recording.find (2) == null);
  assert (recording.get_items ().length == 2);

  recording.undo ();
  var items = recording.get_items ();
  assert (items.length == 3);
  for (int i = 0; i < 3; i++) {
    assert (items[i].id == i + 1);
  }

  recording.redo ();
  assert (recording.find (2) == null);
  recording.undo ();

  // Removing nothing is not a step
  recording.remove (42);
  assert (recording.can_redo);
}

void test_visible () {
  var recording = create_recording (create_halves ());
  add (recording, 2);
  recording.change_range (1, false, 4);
  var blur = new Annotation () { tool = Tool.BLUR, x1 = 60, y1 = 20, x2 = 140, y2 = 80 };
  recording.add (blur);
  recording.change_range (2, true, 2);
  recording.change_range (2, false, 4);

  foreach (int frame in new int[] { 1, 2, 4, 5 }) {
    recording.current_frame = frame;
    var result = recording.render ();
    bool visible = frame == 2 || frame == 4;
    assert (get_pixel (result, 20, 40) == (visible ? RED : 0));
    assert ((get_pixel (result, 102, 70) != 0xffffff) == visible);
  }

  // Previews are drawn on every frame
  recording.current_frame = 9;
  var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, 200, 100);
  recording.draw (new Cairo.Context (surface), create (Tool.RECTANGLE));
  assert (get_pixel (Gdk.pixbuf_get_from_surface (surface, 0, 0, 200, 100), 20, 40) == RED);
}

void test_blur_source () {
  var recording = create_recording ();
  add (recording, 0, Tool.BLUR);
  assert (get_pixel (recording.render (), 50, 40) == GRAY);

  int changes = 0;
  recording.changed.connect (() => { changes++; });
  recording.set_source (create_frame ((uint32) 0x0000ffff));
  assert (changes == 1);
  assert (get_pixel (recording.render (), 50, 40) == 0x0000ff);

  // Also for items which are only in the history
  recording.remove (1);
  recording.set_source (create_frame ((uint32) 0x00ff00ff));
  recording.undo ();
  assert (get_pixel (recording.render (), 50, 40) == 0x00ff00);
}

void test_render_item () {
  var recording = create_recording ();
  var result = recording.render_item (add (recording, 0));
  assert (result.width == 200);
  assert (result.height == 100);
  assert (result.has_alpha);
  assert (get_alpha (result, 50, 40) == 0);
  assert (get_alpha (result, 150, 80) == 0);
  assert (get_alpha (result, 20, 40) == 255);
  assert (get_pixel (result, 20, 40) == RED);
}

// Everything which is drawn must be inside the bounds
void check_bounds (Annotation annotation, int scale) {
  var image = new AnnotatedImage (create_frame (), scale);
  assert (image.scale == scale);
  image.add (annotation);
  var bounds = image.get_bounds (annotation);
  var result = image.render_item (annotation);
  bool drawn = false;

  for (int y = 0; y < 100; y++) {
    for (int x = 0; x < 200; x++) {
      if (get_alpha (result, x, y) > 0) {
        drawn = true;
        assert (x >= bounds.x && x < bounds.x + bounds.width);
        assert (y >= bounds.y && y < bounds.y + bounds.height);
      }
    }
  }

  assert (drawn);
}

void test_bounds () {
  for (int scale = 1; scale <= 2; scale++) {
    foreach (Tool tool in new Tool[] {
      Tool.RECTANGLE, Tool.CIRCLE, Tool.LINE, Tool.ARROW, Tool.TEXT
    }) {
      var annotation = create (tool);
      annotation.text = "Hello\njolly";
      check_bounds (annotation, scale);
    }

    // Flat, so that the line width and the arrow head matter
    check_bounds (new Annotation () {
      tool = Tool.ARROW, x1 = 20, y1 = 50, x2 = 80, y2 = 50, color = { 1, 0, 0, 1 }
    }, scale);
  }

  var image = new AnnotatedImage (create_frame (), 1);
  var bounds = image.get_bounds (create (Tool.RECTANGLE));
  assert (bounds.x == 18 && bounds.y == 18 && bounds.width == 64 && bounds.height == 44);
}

void test_blur_region () {
  var image = new AnnotatedImage (create_frame (), 1);
  var blur = new Annotation () { tool = Tool.BLUR, x1 = 80.5, y1 = 60, x2 = 20.5, y2 = 120 };
  var region = image.get_blur_region (blur);
  assert (region.x == 20 && region.y == 60 && region.width == 61 && region.height == 40);
  assert (image.get_bounds (blur).width == 61);

  blur.x2 = 80.5;
  blur.x1 = 80.5;
  blur.y2 = 60;
  assert (image.get_blur_region (blur) == null);
}

void test_single_frame () {
  var recording = new AnnotatedRecording (create_frame (), 1, { 0 });
  add (recording, 0);
  assert_range (recording, 1, 0, 0);
  assert (recording.duration == 0);
}

void main (string[] args) {
  Test.init (ref args);

  Test.add_func ("/annotated-recording/default-range", test_default_range);
  Test.add_func ("/annotated-recording/current-frame", test_current_frame);
  Test.add_func ("/annotated-recording/add-again", test_add_again);
  Test.add_func ("/annotated-recording/variable-rate", test_variable_rate);
  Test.add_func ("/annotated-recording/range-limits", test_range_limits);
  Test.add_func ("/annotated-recording/range-undo", test_range_undo);
  Test.add_func ("/annotated-recording/range-interrupted", test_range_interrupted);
  Test.add_func ("/annotated-recording/remove-undo", test_remove_undo);
  Test.add_func ("/annotated-recording/visible", test_visible);
  Test.add_func ("/annotated-recording/blur-source", test_blur_source);
  Test.add_func ("/annotated-recording/render-item", test_render_item);
  Test.add_func ("/annotated-recording/bounds", test_bounds);
  Test.add_func ("/annotated-recording/blur-region", test_blur_region);
  Test.add_func ("/annotated-recording/single-frame", test_single_frame);

  Test.run ();
}
