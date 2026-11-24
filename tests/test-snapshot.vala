using Peek;
using Peek.Recording;

async void check_encode (OutputFormat format, string type_name) throws Error {
  var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 64, 48);
  pixbuf.fill ((uint32) 0xff0000ff);

  var file = yield Snapshot.encode (pixbuf, format);
  int width, height;
  var info = Gdk.Pixbuf.get_file_info (file.get_path (), out width, out height);
  assert_nonnull (info);
  assert (info.get_name () == type_name);

  var image = new Gdk.Pixbuf.from_file (file.get_path ());
  assert (image.width == 64);
  assert (image.height == 48);

  unowned uint8[] pixels = image.get_pixels_with_length ();
  var offset = 24 * image.rowstride + 32 * image.n_channels;
  assert (pixels[offset] >= 251);
  assert (pixels[offset + 1] <= 4);
  assert (pixels[offset + 2] <= 4);

  file.delete ();
}

void run_encode (OutputFormat format, string type_name) {
  var loop = new MainLoop ();
  check_encode.begin (format, type_name, (obj, res) => {
    try {
      check_encode.end (res);
    } catch (Error e) {
      error (e.message);
    }

    loop.quit ();
  });
  loop.run ();
}

void test_encode_png () {
  run_encode (OutputFormat.PNG, "png");
}

void test_encode_jpeg () {
  run_encode (OutputFormat.JPEG, "jpeg");
}

void test_encode_bmp () {
  run_encode (OutputFormat.BMP, "bmp");
}

void test_encode_gif () {
  if (!Utils.check_for_executable ("ffmpeg")) {
    Test.skip ("ffmpeg not found");
    return;
  }

  run_encode (OutputFormat.STILL_GIF, "gif");
}

void test_grab_empty () {
  try {
    Snapshot.grab (RecordingArea () { width = 0, height = 10 });
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (e is RecordingError.INITIALIZING_RECORDING_FAILED);
  }
}

void main (string[] args) {
  Test.init (ref args);

  Test.add_func ("/snapshot/encode_png", test_encode_png);
  Test.add_func ("/snapshot/encode_jpeg", test_encode_jpeg);
  Test.add_func ("/snapshot/encode_bmp", test_encode_bmp);
  Test.add_func ("/snapshot/encode_gif", test_encode_gif);
  Test.add_func ("/snapshot/grab_empty", test_grab_empty);

  Test.run ();
}
