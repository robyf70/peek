using Peek;

void test_make_even () {
  assert(Utils.make_even (3) == 2);
  assert(Utils.make_even (4) == 4);
  assert(Utils.make_even (0) == 0);
  assert(Utils.make_even (-7) == -6);
  assert(Utils.make_even (-12) == -12);
}

void test_get_available_system_memory () {
  int memory = Utils.get_available_system_memory ();
  assert(memory > 0);
}

void test_output_format () {
  assert (OutputFormat.STILL_GIF.to_string () == "still-gif");
  assert (OutputFormat.JPEG.to_string () == "jpeg");
  assert (Utils.get_file_extension_for_format (OutputFormat.STILL_GIF) == "gif");
  assert (Utils.get_file_extension_for_format (OutputFormat.JPEG) == "jpg");
  assert (Utils.get_file_extension_for_format (OutputFormat.PNG) == "png");
  assert (Utils.get_file_extension_for_format (OutputFormat.BMP) == "bmp");
  assert (Utils.get_file_extension_for_format (OutputFormat.WEBM) == "webm");
  assert (OutputFormat.PNG.is_image () && OutputFormat.STILL_GIF.is_image ());
  assert (OutputFormat.JPEG.is_image () && OutputFormat.BMP.is_image ());
  assert (!OutputFormat.GIF.is_image () && !OutputFormat.APNG.is_image ());
  assert (!OutputFormat.MP4.is_image () && !OutputFormat.WEBM.is_image ());

  // GSettings maps the enum property by nick, so it must match the schema
  var cls = (EnumClass) typeof (OutputFormat).class_ref ();
  assert (cls.get_value (OutputFormat.STILL_GIF).value_nick == "still-gif");
}

void main (string[] args) {
  Test.init (ref args);

  Test.add_func ("/utils/test_make_even", test_make_even);
  Test.add_func ("/utils/get_available_system_memory", test_get_available_system_memory);

  Test.add_func ("/utils/output_format", test_output_format);

  Test.run ();
}
