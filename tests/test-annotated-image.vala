using Peek.Annotations;

const int RED = 0xff0000;
const int GRAY = 0x808080;

Gdk.Pixbuf create_gray () {
  var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 200, 100);
  pixbuf.fill ((uint32) 0x808080ff);
  return pixbuf;
}

// Vertical stripes, 2 px black, 2 px white
Gdk.Pixbuf create_stripes () {
  var pixbuf = create_gray ();
  unowned uint8[] pixels = pixbuf.get_pixels_with_length ();
  for (int y = 0; y < pixbuf.height; y++) {
    for (int x = 0; x < pixbuf.width * 3; x++) {
      pixels[y * pixbuf.rowstride + x] = x / 6 % 2 == 0 ? 0 : 255;
    }
  }

  return pixbuf;
}

Annotation create (Tool tool, double x1, double y1, double x2, double y2, int width = 4) {
  return new Annotation () {
    tool = tool, x1 = x1, y1 = y1, x2 = x2, y2 = y2,
    color = { 1, 0, 0, 1 }, width = width
  };
}

AnnotatedImage create_image (Annotation? annotation = null) {
  var image = new AnnotatedImage (create_gray (), 1);
  if (annotation != null) {
    image.add (annotation);
  }

  return image;
}

int get_pixel (Gdk.Pixbuf pixbuf, int x, int y) {
  unowned uint8[] pixels = pixbuf.get_pixels_with_length ();
  var offset = y * pixbuf.rowstride + x * pixbuf.n_channels;
  return pixels[offset] << 16 | pixels[offset + 1] << 8 | pixels[offset + 2];
}

void assert_blurred (Gdk.Pixbuf pixbuf, int left, int top, int right, int bottom) {
  for (int y = top; y <= bottom; y++) {
    for (int x = left; x <= right; x++) {
      var red = get_pixel (pixbuf, x, y) >> 16;
      assert (red >= 96 && red <= 160);
    }
  }
}

void test_undo_redo () {
  var image = create_image ();
  int changes = 0;
  image.changed.connect (() => { changes++; });

  image.undo ();
  image.redo ();
  assert (changes == 0);
  assert (!image.can_undo);
  assert (!image.can_redo);

  image.add (create (Tool.RECTANGLE, 20, 20, 80, 60));
  image.add (create (Tool.RECTANGLE, 120, 20, 180, 60));
  assert (image.can_undo);
  assert (!image.can_redo);
  assert (changes == 2);

  image.undo ();
  assert (image.can_redo);
  assert (changes == 3);
  assert (get_pixel (image.render (), 20, 40) == RED);
  assert (get_pixel (image.render (), 120, 40) == GRAY);

  image.redo ();
  assert (!image.can_redo);
  assert (changes == 4);
  assert (get_pixel (image.render (), 120, 40) == RED);

  image.undo ();
  image.add (create (Tool.LINE, 0, 90, 10, 90));
  assert (!image.can_redo);

  image.undo ();
  image.undo ();
  assert (!image.can_undo);
  assert (get_pixel (image.render (), 20, 40) == GRAY);
}

void test_unsaved () {
  var image = create_image ();
  assert (!image.has_unsaved_changes);
  image.add (create (Tool.LINE, 0, 0, 10, 10));
  assert (image.has_unsaved_changes);
  image.mark_copied ();
  assert (!image.has_unsaved_changes);
  image.add (create (Tool.LINE, 0, 0, 20, 20));
  assert (image.has_unsaved_changes);
  image.undo ();
  assert (!image.has_unsaved_changes);
  image.undo ();
  assert (!image.has_unsaved_changes);

  // Same number of items as the copied state, but another drawing
  image.add (create (Tool.LINE, 0, 0, 30, 30));
  assert (image.has_unsaved_changes);
}

void check_constrain (Tool tool, double x1, double y1, double x2, double y2,
                      bool shift, double expected_x, double expected_y) {
  var annotation = create (tool, x1, y1, x2, y2);
  create_image ().constrain (annotation, shift);
  assert (Math.fabs (annotation.x2 - expected_x) < 0.001);
  assert (Math.fabs (annotation.y2 - expected_y) < 0.001);
}

void test_constrain () {
  check_constrain (Tool.RECTANGLE, 10, 10, 50, 30, true, 50, 50);
  check_constrain (Tool.CIRCLE, 50, 50, 20, 40, true, 20, 20);
  check_constrain (Tool.RECTANGLE, 10, 90, 150, 95, true, 20, 100);
  check_constrain (Tool.RECTANGLE, 10, 10, 500, -5, true, 20, 0);

  check_constrain (Tool.LINE, 0, 0, 50, 4, true, 50, 0);
  check_constrain (Tool.ARROW, 0, 0, 40, 37, true, 38.5, 38.5);
  check_constrain (Tool.LINE, 0, 0, 180, 170, true, 100, 100);
  // Along the image's edges
  check_constrain (Tool.LINE, 200, 10, 203, 50, true, 200, 50);
  check_constrain (Tool.LINE, 50, 0, 10, -3, true, 10, 0);

  check_constrain (Tool.RECTANGLE, 10, 10, 500, -5, false, 200, 0);
  check_constrain (Tool.BLUR, 10, 10, 50, 30, true, 50, 30);
  check_constrain (Tool.BLUR, 10, 10, 500, -5, true, 200, 0);

  var annotation = create (Tool.LINE, -5, 120, 10, 10);
  create_image ().constrain (annotation, false);
  assert (annotation.x1 == 0);
  assert (annotation.y1 == 100);
}

void test_rectangle () {
  var result = create_image (create (Tool.RECTANGLE, 20, 20, 80, 60)).render ();
  assert (result.width == 200);
  assert (result.height == 100);
  assert (result.n_channels == 3);
  assert (get_pixel (result, 20, 40) == RED);
  assert (get_pixel (result, 50, 40) == GRAY);
  assert (get_pixel (result, 150, 80) == GRAY);

  // Drawn in the opposite direction
  result = create_image (create (Tool.RECTANGLE, 80, 60, 20, 20)).render ();
  assert (get_pixel (result, 20, 40) == RED);
}

void test_circle () {
  var result = create_image (create (Tool.CIRCLE, 20, 20, 80, 60)).render ();
  assert (get_pixel (result, 20, 40) == RED);
  assert (get_pixel (result, 50, 40) == GRAY);
  assert (get_pixel (result, 21, 21) == GRAY);

  // A flat circle must not break what is drawn after it
  var image = create_image (create (Tool.CIRCLE, 20, 20, 80, 20));
  image.add (create (Tool.RECTANGLE, 100, 20, 180, 60));
  assert (get_pixel (image.render (), 50, 20) == RED);
  assert (get_pixel (image.render (), 100, 40) == RED);
}

bool has_off_axis_pixel (Gdk.Pixbuf pixbuf) {
  for (int y = 38; y <= 62; y++) {
    for (int x = 138; x <= 162; x++) {
      if ((y - 50).abs () > 4 && get_pixel (pixbuf, x, y) == RED) {
        return true;
      }
    }
  }

  return false;
}

void test_line_arrow () {
  var line = create_image (create (Tool.LINE, 20, 50, 150, 50)).render ();
  assert (get_pixel (line, 80, 50) == RED);
  assert (!has_off_axis_pixel (line));

  var arrow = create_image (create (Tool.ARROW, 20, 50, 150, 50)).render ();
  assert (get_pixel (arrow, 80, 50) == RED);
  assert (has_off_axis_pixel (arrow));
}

void test_text () {
  var annotation = create (Tool.TEXT, 20, 20, 20, 20);
  annotation.text = "Hello";
  var result = create_image (annotation).render ();

  bool painted = false;
  for (int y = 20; y < 60; y++) {
    for (int x = 20; x < 120; x++) {
      painted |= get_pixel (result, x, y) != GRAY;
    }
  }

  assert (painted);

  for (int y = 80; y < 100; y++) {
    for (int x = 160; x < 200; x++) {
      assert (get_pixel (result, x, y) == GRAY);
    }
  }
}

void test_blur () {
  var source = create_stripes ();
  var image = new AnnotatedImage (source, 1);
  image.add (create (Tool.BLUR, 40, 20, 120, 80));
  var result = image.render ();
  assert_blurred (result, 48, 28, 112, 72);
  assert (get_pixel (result, 10, 10) == get_pixel (source, 10, 10));
}

void test_blur_order () {
  var image = create_image (create (Tool.RECTANGLE, 20, 20, 80, 60));
  image.add (create (Tool.BLUR, 0, 0, 100, 100));
  assert (get_pixel (image.render (), 20, 40) == RED);

  image = new AnnotatedImage (create_stripes (), 1);
  image.add (create (Tool.BLUR, 10, 10, 110, 90));
  image.add (create (Tool.BLUR, 60, 10, 180, 90));
  assert_blurred (image.render (), 68, 18, 102, 82);
}

void test_preview () {
  var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, 200, 100);
  var cr = new Cairo.Context (surface);

  var image = new AnnotatedImage (create_stripes (), 1);
  image.add (create (Tool.RECTANGLE, 20, 20, 80, 60));
  image.draw (cr, create (Tool.BLUR, 0, 0, 100, 100));
  var result = Gdk.pixbuf_get_from_surface (surface, 0, 0, 200, 100);
  assert (get_pixel (result, 20, 40) == RED);
  assert_blurred (result, 30, 30, 70, 50);

  image.draw (cr, create (Tool.LINE, 20, 80, 80, 80));
  result = Gdk.pixbuf_get_from_surface (surface, 0, 0, 200, 100);
  assert (get_pixel (result, 50, 80) == RED);

  // The preview is not part of the drawing
  assert (get_pixel (image.render (), 50, 80) != RED);
}

void test_blur_small () {
  var image = new AnnotatedImage (create_stripes (), 1);
  image.add (create (Tool.BLUR, 10, 10, 11, 11));
  image.add (create (Tool.BLUR, 20, 10, 23, 12));
  image.add (create (Tool.BLUR, 30, 10, 30, 10));
  image.add (create (Tool.BLUR, 200, 100, 200, 100));
  image.add (create (Tool.BLUR, 199, 99, 200, 100));
  image.add (create (Tool.BLUR, 195, 95, 210, 110));
  assert (image.render ().width == 200);

  var tiny = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 2, 2);
  tiny.fill ((uint32) 0x808080ff);
  image = new AnnotatedImage (tiny, 1);
  image.add (create (Tool.BLUR, 0, 0, 1, 1));
  image.add (create (Tool.BLUR, 0, 0, 2, 2));
  image.add (create (Tool.BLUR, 2, 2, 2, 2));
  assert (image.render ().width == 2);
  assert (get_pixel (image.render (), 1, 1) == GRAY);
}

// Blurs must cover the capture even if it is not opaque
void test_blur_alpha () {
  var source = create_stripes ().add_alpha (false, 0, 0, 0);
  unowned uint8[] pixels = source.get_pixels_with_length ();
  for (int y = 0; y < source.height; y++) {
    for (int x = 0; x < source.width; x++) {
      pixels[y * source.rowstride + x * 4 + 3] = 128;
    }
  }

  var image = new AnnotatedImage (source, 1);
  image.add (create (Tool.BLUR, 40, 20, 120, 80));
  var result = image.render ();
  for (int x = 48; x < 112; x++) {
    var difference = (get_pixel (result, x, 50) >> 16) - (get_pixel (result, x + 1, 50) >> 16);
    assert (difference.abs () < 8);
  }
}

void test_scaled () {
  var image = new AnnotatedImage (create_gray (), 2);
  image.add (create (Tool.LINE, 20, 50, 150, 50, 2));
  var result = image.render ();
  assert (get_pixel (result, 80, 47) == GRAY);
  for (int y = 48; y < 52; y++) {
    assert (get_pixel (result, 80, y) == RED);
  }

  assert (get_pixel (result, 80, 52) == GRAY);
}

void test_fit_scale () {
  assert (fit_scale (1000, 500, 500, 500, 1) == 0.5);
  assert (fit_scale (500, 1000, 500, 500, 1) == 0.5);
  assert (fit_scale (100, 100, 500, 500, 1) == 1.0);
  assert (fit_scale (100, 100, 500, 500, 2) == 0.5);
}

void main (string[] args) {
  Test.init (ref args);

  Test.add_func ("/annotated-image/undo_redo", test_undo_redo);
  Test.add_func ("/annotated-image/unsaved", test_unsaved);
  Test.add_func ("/annotated-image/constrain", test_constrain);
  Test.add_func ("/annotated-image/rectangle", test_rectangle);
  Test.add_func ("/annotated-image/circle", test_circle);
  Test.add_func ("/annotated-image/line_arrow", test_line_arrow);
  Test.add_func ("/annotated-image/text", test_text);
  Test.add_func ("/annotated-image/blur", test_blur);
  Test.add_func ("/annotated-image/blur_order", test_blur_order);
  Test.add_func ("/annotated-image/blur_small", test_blur_small);
  Test.add_func ("/annotated-image/blur_alpha", test_blur_alpha);
  Test.add_func ("/annotated-image/preview", test_preview);
  Test.add_func ("/annotated-image/scaled", test_scaled);
  Test.add_func ("/annotated-image/fit_scale", test_fit_scale);

  Test.run ();
}
