using Peek;
using Peek.Annotations;
using Peek.PostProcessing;
using Peek.Recording;

const int N_FRAMES = 10;
const int WIDTH = 160;
const int HEIGHT = 120;

// Odd on purpose, as 4:2:0 video stores colors for 2x2 pixels
const int BLUR_X = 31;
const int BLUR_Y = 21;
const int BLUR_WIDTH = 67;
const int BLUR_HEIGHT = 55;

string dir;
string temp_dir;
string bin_dir;
string old_path;

delegate void AsyncStart (owned AsyncReadyCallback callback);

AsyncResult await (AsyncStart start) {
  var loop = new MainLoop ();
  AsyncResult? result = null;
  var timeout = Timeout.add_seconds (60, () => {
    error ("Timeout");
  });
  start ((obj, res) => {
    result = res;
    loop.quit ();
  });
  loop.run ();
  Source.remove (timeout);
  return result;
}

string run_command (string[] argv) {
  string output = "", errors = "";
  int status = -1;
  try {
    Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null,
      out output, out errors, out status);
  } catch (SpawnError e) {
    error (e.message);
  }

  if (status != 0) {
    error ("%s\n%s", string.joinv (" ", argv), errors);
  }

  return output;
}

bool has_ffmpeg (string encoder = "ffv1") {
  if (!RecordingReader.is_available ()) {
    Test.skip ("ffmpeg not found");
    return false;
  }

  if (!(" " + encoder + " " in run_command ({ "ffmpeg", "-v", "error", "-encoders" }))) {
    Test.skip (encoder + " not found");
    return false;
  }

  return true;
}

string[] to_strings (Array<string> values) {
  string[] result = {};
  for (uint i = 0; i < values.length; i++) {
    result += values.index (i);
  }

  return result;
}

// Vertical stripes of 1 px, or the gray of frame n being n * 10
File create_clip (string name, bool stripes = false) {
  var path = Path.build_filename (temp_dir, name);
  var image = stripes ? "mod(X,2)*255" : "N*10";
  var rate = name == "ntsc.mkv" ? "30000/1001" : "10";
  var frames = "color=s=%dx%d:r=%s:d=2,format=gray,geq=lum='%s',trim=end_frame=%d".printf (
    WIDTH, HEIGHT, rate, image, N_FRAMES);
  if (name == "variable.mkv" || name == "variable.webm") {
    frames += ",setpts='(N*(N+1)/2*0.1)/TB'";
  } else if (name == "close.mkv") {
    // Two frames 2 ms apart at each limit of the range 2 to 4
    frames += ",settb=1/1000,setpts='N*100-if(eq(N,2),98,0)-if(eq(N,5),98,0)'";
  }

  var args = new Array<string> ();
  foreach (var arg in new string[] { "ffmpeg", "-nostdin", "-v", "error", "-y" }) {
    args.append_val (arg);
  }

  var has_sound = name.has_suffix (".mp4") || name == "opus.webm";
  string[] more = {};
  if (has_sound) {
    more = { "-f", "lavfi", "-i", "sine=d=2" };
    foreach (var arg in more) {
      args.append_val (arg);
    }

    if (name == "late-video.mp4") {
      args.append_val ("-itsoffset");
      args.append_val ("0.5");
    }
  }

  more = { "-f", "lavfi", "-i", frames };
  foreach (var arg in more) {
    args.append_val (arg);
  }

  if (name.has_suffix (".mp4")) {
    more = { "-map", "0:a", "-map", "1:v", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p",
      "-c:a", name == "mp3.mp4" ? "libmp3lame" : "aac" };
  } else if (name == "opus.webm") {
    more = { "-map", "0:a", "-map", "1:v", "-c:v", "libvpx-vp9",
      "-c:a", "libopus" };
  } else if (name.has_suffix (".webm")) {
    more = { "-c:v", "libvpx-vp9", "-lossless", "1" };
  } else if (name == "late-start.mkv") {
    more = { "-c:v", "ffv1", "-output_ts_offset", "0.5" };
  } else {
    more = { "-c:v", "ffv1" };
  }

  foreach (var arg in more) {
    args.append_val (arg);
  }

  more = { "-fps_mode", "passthrough", "-enc_time_base", "1:1000", path };
  foreach (var arg in more) {
    args.append_val (arg);
  }

  run_command (to_strings (args));
  return File.new_for_path (path);
}

double[] read_times (File file) {
  var reader = new RecordingReader (file);
  try {
    return reader.read_times.end (await ((callback) => {
      reader.read_times.begin ((owned) callback);
    }));
  } catch (RecordingError e) {
    error (e.message);
  }
}

Gdk.Pixbuf[] read_frames (File file, double[] times, double start = 0) {
  var reader = new RecordingReader (file);
  Gdk.Pixbuf[] result = {};
  try {
    var read = reader.read_times.end (await ((callback) => {
      reader.read_times.begin ((owned) callback);
    }));
    assert (read.length == times.length);
    for (int i = 0; i < times.length; i++) {
      assert (Math.fabs (read[i] + start - times[i]) < 0.00101);
      result += reader.read_frame.end (await ((callback) => {
        reader.read_frame.begin (i, (owned) callback);
      }));
    }
  } catch (RecordingError e) {
    error (e.message);
  }

  return result;
}

uint8 get_pixel (Gdk.Pixbuf pixbuf, int x, int y, int channel) {
  unowned uint8[] pixels = pixbuf.get_pixels_with_length ();
  return pixels[y * pixbuf.rowstride + x * pixbuf.n_channels + channel];
}

AnnotatedRecording create_recording (double[] times) {
  var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, WIDTH, HEIGHT);
  pixbuf.fill (0);
  return new AnnotatedRecording (pixbuf, 1, times);
}

AnnotatedRecording create_default_recording () {
  double[] times = {};
  for (int i = 0; i < N_FRAMES; i++) {
    times += i * 0.5;
  }

  return create_recording (times);
}

void add_item (AnnotatedRecording recording, Annotation item, int first, int last) {
  recording.current_frame = first;
  recording.add (item);
  recording.change_range (item.id, false, recording.n_frames - 1);
  recording.change_range (item.id, true, first);
  recording.change_range (item.id, false, last);
}

// A thick red line
Annotation create_line (int y) {
  return new Annotation () {
    tool = Tool.LINE, x1 = 10, y1 = y, x2 = 60, y2 = y, width = 12,
    color = Gdk.RGBA () { red = 1, green = 0, blue = 0, alpha = 1 }
  };
}

Annotation create_blur (int x = BLUR_X, int y = BLUR_Y) {
  return new Annotation () {
    tool = Tool.BLUR, x1 = x, y1 = y, x2 = x + BLUR_WIDTH, y2 = y + BLUR_HEIGHT
  };
}

bool is_red (Gdk.Pixbuf pixbuf, int x, int y) {
  return get_pixel (pixbuf, x, y, 0) > get_pixel (pixbuf, x, y, 1) + 60;
}

RecordingConfig create_config (OutputFormat format) {
  return new RecordingConfig () { output_format = format };
}

File burn_in (AnnotatedRecording recording, RecordingConfig config, File input) {
  var processor = new BurnInPostProcessor (recording, config);
  var files = new Array<File> ();
  files.append_val (input);
  try {
    var result = processor.process_async.end (await ((callback) => {
      processor.process_async.begin (files, (owned) callback);
    }));
    assert (result.length == 1);
    return result.index (0);
  } catch (RecordingError e) {
    error (e.message);
  }
}

File export (RecordingExporter exporter, AnnotatedRecording recording) throws RecordingError {
  return exporter.export.end (await ((callback) => {
    exporter.export.begin (recording, (owned) callback);
  }));
}

string[] list_temp_files () {
  string[] result = {};
  try {
    var entries = Dir.open (temp_dir);
    string? name;
    while ((name = entries.read_name ()) != null) {
      result += name;
    }
  } catch (FileError e) {
    error (e.message);
  }

  return result;
}

void assert_temp_files (string[] expected) {
  var files = list_temp_files ();
  if (files.length != expected.length) {
    error ("Unexpected files: %s", string.joinv (" ", files));
  }

  foreach (var name in expected) {
    assert (FileUtils.test (Path.build_filename (temp_dir, name), FileTest.EXISTS));
  }
}

void clear_temp_files () {
  foreach (var name in list_temp_files ()) {
    FileUtils.remove (Path.build_filename (temp_dir, name));
  }
}

// ---------------------------------------------------------------- Arguments

string[] build (OutputFormat format, AnnotatedRecording recording, string[] png_files,
  string codec = "h264", bool vaapi = false) {
  var config = create_config (format);
  config.mp4_codec = codec;
  config.mp4_vaapi = vaapi;
  return BurnInPostProcessor.build_arguments (recording, config, "/in", png_files, "/out");
}

const string ONE_LINE_GRAPH = "[0:v]format=gbrp[v0];"
  + "[v0][1:v]overlay=eof_action=repeat:format=gbrp:enable='gte(t,0.750000)*lt(t,2.250000)'[v1];"
  + "[v1]null";

void check_arguments (OutputFormat format, string codec, bool vaapi,
  string before, string graph_end, string codec_args) {
  var recording = create_default_recording ();
  add_item (recording, create_line (20), 2, 4);

  // No ffmpeg, which is asked for its H.264 bit depths otherwise
  Environment.set_variable ("PATH", "/nonexistent", true);
  var args = build (format, recording, { "/1.png" }, codec, vaapi);
  Environment.set_variable ("PATH", old_path, true);

  assert_cmpstr (string.joinv (" ", args), CompareOperator.EQ,
    "ffmpeg -nostdin -v error -y " + before + "-i /in -i /1.png -filter_complex "
    + ONE_LINE_GRAPH + graph_end + "[v] -map [v] -map 0:a? " + codec_args
    + " -c:a copy -fps_mode passthrough -enc_time_base -1 /out");
}

const string VP9 = "-codec:v libvpx-vp9 -qmin 10 -qmax 50 -crf 13 -b:v 1M -pix_fmt yuv420p";
const string VP9_LOSSLESS = "-codec:v libvpx-vp9 -lossless 1";
const string H264 = "-codec:v libx264 -preset:v fast -profile:v baseline -pix_fmt yuv420p";
const string HEVC = "-codec:v libx265 -preset:v fast -tag:v hvc1 -pix_fmt yuv420p";
const string AV1 = "-codec:v libsvtav1 -preset:v 8 -pix_fmt yuv420p";
const string HEVC_VAAPI = "-codec:v hevc_vaapi -tag:v hvc1";

void test_arguments () {
  check_arguments (OutputFormat.GIF, "h264", false, "", "", "-c:v ffv1");
  check_arguments (OutputFormat.APNG, "h264", false, "", "", "-c:v ffv1");
  check_arguments (OutputFormat.WEBM, "h264", false, "", "", VP9);
  check_arguments (OutputFormat.MP4, "h264", false, "", "", H264);
  check_arguments (OutputFormat.MP4, "hevc", false, "", "", HEVC);
  check_arguments (OutputFormat.MP4, "av1", false, "", "", AV1);

  var device = "-vaapi_device /dev/dri/renderD128 ";
  var upload = ", format=nv12, hwupload";
  check_arguments (OutputFormat.MP4, "h264", true, device, upload, "-codec:v h264_vaapi");
  check_arguments (OutputFormat.MP4, "hevc", true, device, upload, HEVC_VAAPI);
  check_arguments (OutputFormat.MP4, "av1", true, device, upload, "-codec:v av1_vaapi");

  // Only MP4 uses VAAPI
  check_arguments (OutputFormat.WEBM, "h264", true, "", "", VP9);
  check_arguments (OutputFormat.GIF, "h264", true, "", "", "-c:v ffv1");
}

void check_output_parameters (OutputFormat format, string codec, bool vaapi,
  string expected, string expected_extension) {
  var config = create_config (format);
  config.mp4_codec = codec;
  config.mp4_vaapi = vaapi;
  config.framerate = 17;

  Environment.set_variable ("PATH", "/nonexistent", true);
  string extension;
  var args = new Array<string> ();
  Ffmpeg.add_output_parameters (args, config, out extension);
  var codec_args = new Array<string> ();
  Ffmpeg.add_codec_parameters (codec_args, config);
  Environment.set_variable ("PATH", old_path, true);

  assert_cmpstr (string.joinv (" ", to_strings (args)), CompareOperator.EQ, expected + " -r 17");
  assert_cmpstr (string.joinv (" ", to_strings (codec_args)), CompareOperator.EQ, expected);
  assert_cmpstr (extension, CompareOperator.EQ, expected_extension);
}

void test_output_parameters () {
  check_output_parameters (OutputFormat.GIF, "h264", false, VP9_LOSSLESS, "webm");
  check_output_parameters (OutputFormat.APNG, "h264", true, VP9_LOSSLESS, "webm");
  check_output_parameters (OutputFormat.WEBM, "h264", false, VP9, "webm");
  check_output_parameters (OutputFormat.MP4, "h264", false, H264, "mp4");
  check_output_parameters (OutputFormat.MP4, "hevc", false, HEVC, "mp4");
  check_output_parameters (OutputFormat.MP4, "av1", false, AV1, "mp4");
  check_output_parameters (OutputFormat.MP4, "h264", true, "-codec:v h264_vaapi", "mp4");
  check_output_parameters (OutputFormat.MP4, "hevc", true, HEVC_VAAPI, "mp4");
  check_output_parameters (OutputFormat.MP4, "av1", true, "-codec:v av1_vaapi", "mp4");
}

string get_graph (string[] args) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == "-filter_complex") {
      return args[i + 1];
    }
  }

  assert_not_reached ();
}

void test_ranges () {
  var recording = create_default_recording ();
  add_item (recording, create_line (20), 0, 0);
  add_item (recording, create_line (20), 2, 4);
  add_item (recording, create_line (20), 7, 9);
  add_item (recording, create_line (20), 0, 9);
  add_item (recording, create_line (20), 9, 9);
  add_item (recording, create_blur (), 3, 3);
  var graph = get_graph (build (OutputFormat.WEBM, recording, { "a", "b", "c", "d", "e" }));

  string[] limits = {};
  foreach (var part in graph.split ("enable='")) {
    limits += part.split ("'")[0];
  }

  string[] expected = {
    "gte(t,1.250000)*lt(t,1.750000)",
    "gte(t,-1)*lt(t,0.250000)",
    "gte(t,0.750000)*lt(t,2.250000)",
    "gte(t,3.250000)*lt(t,1000000000)",
    "gte(t,-1)*lt(t,1000000000)",
    "gte(t,4.250000)*lt(t,1000000000)"
  };
  assert (limits.length == expected.length + 1);
  for (int i = 0; i < expected.length; i++) {
    assert_cmpstr (limits[i + 1], CompareOperator.EQ, expected[i]);
  }

  recording = create_recording ({ 0 });
  add_item (recording, create_line (20), 0, 0);
  graph = get_graph (build (OutputFormat.WEBM, recording, { "a" }));
  assert ("gte(t,-1)*lt(t,1000000000)" in graph);
}

void test_order () {
  var recording = create_default_recording ();
  add_item (recording, create_line (20), 2, 4);
  add_item (recording, create_blur (), 0, 9);
  add_item (recording, create_line (30), 0, 9);
  // Completely outside of the image, so there is nothing to hide
  add_item (recording, create_blur (WIDTH + 5), 0, 9);
  add_item (recording, new Annotation () { tool = Tool.BLUR, x1 = 8, y1 = 9, x2 = 10, y2 = 11 },
    2, 4);

  var args = build (OutputFormat.GIF, recording, { "/1.png", "/2.png" });
  var all = "enable='gte(t,-1)*lt(t,1000000000)'";
  var part = "enable='gte(t,0.750000)*lt(t,2.250000)'";
  assert_cmpstr (get_graph (args), CompareOperator.EQ, "[0:v]format=gbrp,split=3[v0][c1][c2];"
    + "[c1]crop=67:55:31:21,scale=4:3:flags=bilinear,scale=67:55:flags=bilinear[b1];"
    + "[v0][b1]overlay=31:21:eof_action=repeat:format=gbrp:" + all + "[v1];"
    + "[c2]crop=2:2:8:9,scale=1:1:flags=bilinear,scale=2:2:flags=bilinear[b2];"
    + "[v1][b2]overlay=8:9:eof_action=repeat:format=gbrp:" + part + "[v2];"
    + "[v2][1:v]overlay=eof_action=repeat:format=gbrp:" + part + "[v3];"
    + "[v3][2:v]overlay=eof_action=repeat:format=gbrp:" + all + "[v4];"
    + "[v4]null[v]");
  assert ("-i /in -i /1.png -i /2.png -filter_complex" in string.joinv (" ", args));
}

void test_scale () {
  var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, WIDTH, HEIGHT);
  var recording = new AnnotatedRecording (pixbuf, 2, { 0 });
  recording.add (create_blur ());
  assert ("scale=2:1:flags=bilinear,scale=67:55:" in
    get_graph (build (OutputFormat.GIF, recording, {})));
}

void test_locale () {
  if (Intl.setlocale (LocaleCategory.ALL, "it_IT.UTF-8") == null) {
    Test.skip ("it_IT.UTF-8 not found");
    return;
  }

  assert ("%.1f".printf (0.5) == "0,5");
  test_ranges ();
  test_order ();
  Intl.setlocale (LocaleCategory.ALL, "C");
}

void test_config_copy () {
  var config = new RecordingConfig () {
    output_format = OutputFormat.MP4, framerate = 7, downsample = 3,
    capture_mouse = false, capture_sound = false, mp4_codec = "av1", mp4_vaapi = true,
    gifski_enabled = true, gifski_quality = 11
  };
  var copy = config.copy ();
  assert (copy != config);

  // Also covers properties added later
  foreach (var property in config.get_class ().list_properties ()) {
    var first = Value (property.value_type);
    var second = Value (property.value_type);
    config.get_property (property.name, ref first);
    copy.get_property (property.name, ref second);
    assert (!property.value_defaults (first));
    assert (property.values_cmp (first, second) == 0);
  }

  copy.framerate = 8;
  assert (config.framerate == 7);
}

// ------------------------------------------------------------------- ffmpeg

string get_sound (File file) {
  return run_command ({ "ffmpeg", "-nostdin", "-v", "error", "-i", file.get_path (),
    "-map", "0:a", "-c", "copy", "-f", "md5", "-" });
}

void check_range (string name, OutputFormat format) {
  var input = create_clip (name);
  var times = read_times (input);
  assert (times.length == N_FRAMES);

  var recording = create_recording (times);
  add_item (recording, create_line (20), 2, 4);
  add_item (recording, create_line (50), 5, 5);
  add_item (recording, create_line (80), 0, 0);
  add_item (recording, create_line (100), 7, 9);

  var output = burn_in (recording, create_config (format), input);
  var frames = read_frames (output, times);
  for (int i = 0; i < N_FRAMES; i++) {
    assert (frames[i].width == WIDTH && frames[i].height == HEIGHT);
    assert (is_red (frames[i], 30, 20) == (i >= 2 && i <= 4));
    assert (is_red (frames[i], 30, 50) == (i == 5));
    assert (is_red (frames[i], 30, 80) == (i == 0));
    assert (is_red (frames[i], 30, 100) == (i >= 7));
    // The frame itself, which proves the order of the frames
    assert ((get_pixel (frames[i], 120, 60, 1) - i * 10).abs () <= 4);
  }

  if (name.has_suffix (".mp4") || name == "opus.webm") {
    assert_cmpstr (get_sound (output), CompareOperator.EQ, get_sound (input));
  } else {
    assert (run_command ({ "ffprobe", "-v", "error", "-select_streams", "a",
      "-show_entries", "stream=index", "-of", "csv", output.get_path () }) == "");
  }

  clear_temp_files ();
}

void test_range (string name) {
  if (!has_ffmpeg () || !has_ffmpeg ("libx264") || !has_ffmpeg ("libvpx-vp9")
    || (name == "mp3.mp4" && !has_ffmpeg ("libmp3lame"))
    || (name == "opus.webm" && !has_ffmpeg ("libopus"))) {
    return;
  }

  // MP4 is only recorded for MP4, the sound of which WebM cannot hold
  if (!name.has_suffix (".mp4")) {
    check_range (name, OutputFormat.GIF);
    check_range (name, OutputFormat.WEBM);
  }

  if (name != "opus.webm") {
    check_range (name, OutputFormat.MP4);
  }
}

void test_codec (string codec, string encoder) {
  if (!has_ffmpeg (encoder)) {
    return;
  }

  var input = create_clip ("variable.mkv");
  var times = read_times (input);
  var recording = create_recording (times);
  add_item (recording, create_line (20), 2, 4);
  var config = create_config (OutputFormat.MP4);
  config.mp4_codec = codec;
  var frames = read_frames (burn_in (recording, config, input), times);
  for (int i = 0; i < N_FRAMES; i++) {
    assert (is_red (frames[i], 30, 20) == (i >= 2 && i <= 4));
  }

  clear_temp_files ();
}

// Whether all pixels are neither close to black nor to white
bool is_blurred (Gdk.Pixbuf frame, int inset, int shift = 0) {
  for (int y = BLUR_Y + shift + inset; y < BLUR_Y + shift + BLUR_HEIGHT - inset; y++) {
    for (int x = BLUR_X + shift + inset; x < BLUR_X + shift + BLUR_WIDTH - inset; x++) {
      for (int channel = 0; channel < 3; channel++) {
        var value = get_pixel (frame, x, y, channel);
        if (value < 96 || value > 160) {
          return false;
        }
      }
    }
  }

  return true;
}

// The columns and rows next to the region are not blurred
bool has_stripes_around (Gdk.Pixbuf frame) {
  foreach (var y in new int[] { BLUR_Y - 1, BLUR_Y + BLUR_HEIGHT }) {
    for (int x = BLUR_X; x < BLUR_X + BLUR_WIDTH; x++) {
      if ((get_pixel (frame, x, y, 1) - (x % 2) * 255).abs () > 2) {
        return false;
      }
    }
  }

  for (int y = BLUR_Y; y < BLUR_Y + BLUR_HEIGHT; y++) {
    foreach (var x in new int[] { BLUR_X - 1, BLUR_X + BLUR_WIDTH }) {
      if ((get_pixel (frame, x, y, 1) - (x % 2) * 255).abs () > 2) {
        return false;
      }
    }
  }

  return true;
}

File burn_in_lossless (AnnotatedRecording recording, File input) {
  var output = Path.build_filename (temp_dir, "lossless.mkv");
  string[] args = {};
  foreach (var arg in BurnInPostProcessor.build_arguments (
    recording, create_config (OutputFormat.WEBM), input.get_path (), {}, output)) {
    if (arg == "-map") {
      break;
    }

    args += arg;
  }

  foreach (var arg in new string[] {
    "-map", "[v]", "-pix_fmt", "yuv420p", "-c:v", "ffv1",
    "-fps_mode", "passthrough", "-enc_time_base", "-1", output
  }) {
    args += arg;
  }

  run_command (args);
  return File.new_for_path (output);
}

// The second blur overlaps the first one
void check_blur (string name, int first, int last, bool second_blur) {
  var input = create_clip (name, true);
  var times = read_times (input);
  assert (times.length == N_FRAMES);
  var recording = create_recording (times);
  add_item (recording, create_blur (), first, last);
  if (second_blur) {
    add_item (recording, create_blur (BLUR_X + 20, BLUR_Y + 20), first, last);
  }

  // Without the sound the file starts at the first frame
  var frames = read_frames (burn_in_lossless (recording, input), times, times[0]);
  for (int i = 0; i < N_FRAMES; i++) {
    assert (is_blurred (frames[i], 0) == (i >= first && i <= last));
    if (second_blur) {
      assert (is_blurred (frames[i], 0, 20) == (i >= first && i <= last));
    } else {
      assert (has_stripes_around (frames[i]));
    }
  }

  var is_mp4 = name.has_suffix (".mp4");
  foreach (var format in new OutputFormat[] { OutputFormat.WEBM, OutputFormat.MP4 }) {
    if (is_mp4 && format == OutputFormat.WEBM) {
      // WebM cannot hold its sound
      continue;
    }

    frames = read_frames (burn_in (recording, create_config (format), input), times);
    for (int i = 0; i < N_FRAMES; i++) {
      assert (is_blurred (frames[i], 4) == (i >= first && i <= last));
    }
  }

  if (!is_mp4) {
    // RGB, so the whole region
    frames = read_frames (burn_in (recording, create_config (OutputFormat.GIF), input), times);
    for (int i = 0; i < N_FRAMES; i++) {
      assert (is_blurred (frames[i], 0) == (i >= first && i <= last));
    }
  }

  clear_temp_files ();
}

void test_blur () {
  if (!has_ffmpeg () || !has_ffmpeg ("libx264") || !has_ffmpeg ("libvpx-vp9")) {
    return;
  }

  check_blur ("constant.mkv", 0, 9, false);
  check_blur ("constant.mkv", 2, 4, true);
  check_blur ("variable.mkv", 2, 4, false);
  check_blur ("close.mkv", 2, 4, false);
  check_blur ("late-start.mkv", 2, 4, false);
  check_blur ("late-video.mp4", 0, 0, false);
  check_blur ("late-video.mp4", 8, 9, false);
}

// Shapes are above blurs, and blurs show nothing of shapes
void test_blur_below_shapes () {
  if (!has_ffmpeg ()) {
    return;
  }

  var input = create_clip ("constant.mkv", true);
  var times = read_times (input);
  var recording = create_recording (times);
  add_item (recording, create_line (40), 0, 9);
  add_item (recording, create_blur (), 0, 9);

  var frames = read_frames (
    burn_in (recording, create_config (OutputFormat.GIF), input), times);
  foreach (var frame in frames) {
    assert (get_pixel (frame, 50, 40, 0) == 255);
    assert (get_pixel (frame, 50, 40, 1) == 0);
    assert (!is_red (frame, 50, 60));
  }

  clear_temp_files ();
}

// The sizes a region can be reduced to must all be accepted by ffmpeg
void test_small_blurs () {
  if (!has_ffmpeg ()) {
    return;
  }

  var input = create_clip ("constant.mkv", true);
  var recording = create_recording (read_times (input));
  foreach (var size in new int[] { 1, 2, 3, 15, 17 }) {
    foreach (var other in new int[] { 1, 33, HEIGHT }) {
      add_item (recording, new Annotation () {
        tool = Tool.BLUR, x1 = 0, y1 = 0, x2 = size, y2 = other }, 0, 9);
      add_item (recording, new Annotation () {
        tool = Tool.BLUR, x1 = WIDTH, y1 = HEIGHT, x2 = WIDTH - other, y2 = HEIGHT - size },
        0, 9);
    }
  }

  burn_in (recording, create_config (OutputFormat.GIF), input);
  clear_temp_files ();
}

// Neither a blur nor a shape is left, as the only blur is outside
void test_no_visible_items () {
  if (!has_ffmpeg ()) {
    return;
  }

  var input = create_clip ("constant.mkv");
  var times = read_times (input);
  var recording = create_recording (times);
  add_item (recording, create_blur (WIDTH + 5), 0, 9);
  read_frames (burn_in (recording, create_config (OutputFormat.GIF), input), times);
  clear_temp_files ();
}

string get_frame_hashes (File file) {
  var result = "";
  foreach (var line in run_command ({ "ffmpeg", "-nostdin", "-v", "error",
    "-i", file.get_path (), "-map", "0:v", "-fps_mode", "passthrough",
    "-pix_fmt", "gbrp", "-f", "framemd5", "-" }).split ("\n")) {
    if (!line.has_prefix ("#") && line != "") {
      result += line.substring (line.last_index_of (",") + 1).strip () + "\n";
    }
  }

  return result;
}

void test_identical () {
  if (!has_ffmpeg () || !has_ffmpeg ("libvpx-vp9")) {
    return;
  }

  foreach (var name in new string[] { "variable.webm", "constant.mkv" }) {
    var input = create_clip (name, true);
    var times = read_times (input);
    var recording = create_recording (times);
    add_item (recording, create_line (20), 2, 4);
    add_item (recording, create_blur (), 3, 5);

    var expected = get_frame_hashes (input).split ("\n");
    var actual = get_frame_hashes (
      burn_in (recording, create_config (OutputFormat.GIF), input)).split ("\n");
    assert (expected.length == N_FRAMES + 1);
    assert (actual.length == N_FRAMES + 1);
    for (int i = 0; i < N_FRAMES; i++) {
      assert ((expected[i] == actual[i]) == (i < 2 || i > 5));
    }

    clear_temp_files ();
  }
}

string get_digest (File file) {
  try {
    uint8[] data;
    FileUtils.get_data (file.get_path (), out data);
    return Checksum.compute_for_data (ChecksumType.SHA256, data);
  } catch (FileError e) {
    error (e.message);
  }
}

void test_export () {
  if (!has_ffmpeg () || !has_ffmpeg ("libvpx-vp9") || !has_ffmpeg ("libx264")) {
    return;
  }

  foreach (var format in new OutputFormat[] {
    OutputFormat.GIF, OutputFormat.APNG, OutputFormat.WEBM, OutputFormat.MP4
  }) {
    foreach (var with_items in new bool[] { false, true }) {
      var captured = create_clip ("variable.webm");
      var digest = get_digest (captured);
      var recording = create_recording (read_times (captured));
      if (with_items) {
        add_item (recording, create_line (20), 2, 9);
        add_item (recording, create_blur (), 0, 9);
      }

      try {
        var exporter = new RecordingExporter (captured, create_config (format));
        var file = export (exporter, recording);
        assert (!exporter.is_cancelled);
        var is_video = format == OutputFormat.WEBM || format == OutputFormat.MP4;
        if (is_video && !with_items) {
          assert (file == captured);
          assert_temp_files ({ "variable.webm" });
        } else {
          assert_temp_files ({ "variable.webm", file.get_basename () });
          assert (file.get_basename ().has_suffix (
            "." + Utils.get_file_extension_for_format (format)));
          var info = file.query_info ("unix::mode", FileQueryInfoFlags.NONE);
          assert ((info.get_attribute_uint32 ("unix::mode") & 0777) == 0644);

          var found = run_command ({ "ffprobe", "-v", "error", "-select_streams", "v",
            "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1",
            file.get_path () }).strip ();
          string[] codecs = { "apng", "gif", "h264", "vp9" };
          assert_cmpstr (found, CompareOperator.EQ, codecs[(int) format]);
          file.delete ();
        }
      } catch (Error e) {
        error (e.message);
      }

      assert_cmpstr (get_digest (captured), CompareOperator.EQ, digest);
      clear_temp_files ();
    }
  }
}

void test_missing_input () {
  if (!has_ffmpeg ()) {
    return;
  }

  foreach (var format in new OutputFormat[] { OutputFormat.GIF, OutputFormat.WEBM }) {
    var recording = create_default_recording ();
    add_item (recording, create_line (20), 2, 4);
    add_item (recording, create_blur (), 2, 4);
    var exporter = new RecordingExporter (
      File.new_for_path (Path.build_filename (temp_dir, "missing")), create_config (format));
    try {
      export (exporter, recording);
      assert_not_reached ();
    } catch (RecordingError e) {
      assert ("No such file" in e.message);
      assert (!exporter.is_cancelled);
    }

    assert_temp_files ({});
  }
}

// --------------------------------------------------- Failing and cancelling

// Writes its output and the step to the log, and after that fails or hangs at
// the step given by the variables.
const string FAKE_COMMAND = """#!/bin/sh
dir="${0%/*}"
case "$*" in
  *encoder=*) exit 0;;
  *palettegen*) step=palettegen;;
  *paletteuse*) step=paletteuse;;
  *%04d.png*) step=extract;;
  *filter_complex*) step=burn_in;;
  *) step=gifski;;
esac
out=""
last=""
for arg; do
  [ "$last" = "-o" ] && out="$arg"
  last="$arg"
done
[ -z "$out" ] && out="$last"
case "$out" in
  *%04d.png) for n in 0001 0002; do echo x > "${out%%04d.png}$n.png"; done;;
  *) echo x > "$out";;
esac
echo "$*" > "$dir/args"
echo $step >> "$dir/log"
[ "$FAKE_HANG" = $step ] && exec sleep 30
[ "$FAKE_FAIL" = $step ] && exit 1
exit 0
""";

void set_fake_commands () {
  foreach (var name in new string[] { "ffmpeg", "gifski" }) {
    var path = Path.build_filename (bin_dir, name);
    try {
      FileUtils.set_contents (path, FAKE_COMMAND);
    } catch (FileError e) {
      error (e.message);
    }

    FileUtils.chmod (path, 0755);
  }

  Environment.set_variable ("PATH", bin_dir + ":" + old_path, true);
}

void unset_fake_commands () {
  Environment.set_variable ("PATH", old_path, true);
  Environment.unset_variable ("FAKE_HANG");
  Environment.unset_variable ("FAKE_FAIL");
  foreach (var name in new string[] { "ffmpeg", "gifski", "log", "args" }) {
    FileUtils.remove (Path.build_filename (bin_dir, name));
  }
}

string get_log () {
  var path = Path.build_filename (bin_dir, "log");
  string log = "";
  if (FileUtils.test (path, FileTest.EXISTS)) {
    try {
      FileUtils.get_contents (path, out log);
    } catch (FileError e) {
      error (e.message);
    }
  }

  return log.replace ("\n", " ");
}

struct Case {
  OutputFormat format;
  bool gifski;
  bool items;
  // The steps run, the last one is the one that fails or is cancelled
  string log;
}

const Case[] CASES = {
  { OutputFormat.WEBM, false, true, "burn_in " },
  { OutputFormat.MP4, false, true, "burn_in " },
  { OutputFormat.GIF, false, true, "burn_in " },
  { OutputFormat.GIF, false, true, "burn_in palettegen " },
  { OutputFormat.GIF, false, true, "burn_in palettegen paletteuse " },
  { OutputFormat.GIF, false, false, "palettegen " },
  { OutputFormat.GIF, false, false, "palettegen paletteuse " },
  { OutputFormat.APNG, false, true, "burn_in palettegen paletteuse " },
  { OutputFormat.GIF, true, true, "burn_in extract " },
  { OutputFormat.GIF, true, true, "burn_in extract gifski " },
  { OutputFormat.GIF, true, false, "extract " },
  { OutputFormat.GIF, true, false, "extract gifski " }
};

enum Ending {
  FAILED,
  CANCELLED,
  // The command already succeeded, but that was not noticed yet
  CANCELLED_LATE
}

RecordingExporter create_case (Case c, out File captured, out AnnotatedRecording recording) {
  captured = File.new_for_path (Path.build_filename (temp_dir, "captured.webm"));
  try {
    FileUtils.set_contents (captured.get_path (), "captured");
  } catch (FileError e) {
    error (e.message);
  }

  recording = create_default_recording ();
  if (c.items) {
    add_item (recording, create_line (20), 2, 4);
    add_item (recording, create_line (30), 2, 4);
    add_item (recording, create_blur (), 2, 4);
  }

  var config = create_config (c.format);
  config.gifski_enabled = c.gifski;
  return new RecordingExporter (captured, config);
}

void check_captured (File captured) {
  string content = "";
  try {
    FileUtils.get_contents (captured.get_path (), out content);
  } catch (FileError e) {
    error (e.message);
  }

  assert (content == "captured");
  assert_temp_files ({ "captured.webm" });
  clear_temp_files ();
}

void check_case (Case c, Ending ending) {
  set_fake_commands ();
  File captured;
  AnnotatedRecording recording;
  var exporter = create_case (c, out captured, out recording);
  var steps = c.log.strip ().split (" ");
  var step = steps[steps.length - 1];
  if (ending == Ending.FAILED) {
    Environment.set_variable ("FAKE_FAIL", step, true);
  } else if (ending == Ending.CANCELLED) {
    Environment.set_variable ("FAKE_HANG", step, true);
  }

  var timer = new Timer ();
  var loop = new MainLoop ();
  var timeout = Timeout.add_seconds (20, () => {
    error ("Timeout");
  });
  exporter.export.begin (recording, (obj, res) => {
    try {
      exporter.export.end (res);
      assert_not_reached ();
    } catch (RecordingError e) {
      assert (e is RecordingError.POSTPROCESSING_ABORTED);
    }

    loop.quit ();
  });

  if (ending != Ending.FAILED) {
    while (get_log () != c.log) {
      loop.get_context ().iteration (false);
      Thread.usleep (200);
    }

    // Let the command exit without noticing it
    Thread.usleep (ending == Ending.CANCELLED_LATE ? 50000 : 0);
    exporter.cancel ();
  }

  loop.run ();
  Source.remove (timeout);
  assert (timer.elapsed () < 15);
  assert (exporter.is_cancelled == (ending != Ending.FAILED));
  assert_cmpstr (get_log (), CompareOperator.EQ, c.log);
  check_captured (captured);
  unset_fake_commands ();
}

void test_failures () {
  foreach (var c in CASES) {
    check_case (c, Ending.FAILED);
  }
}

void test_cancel () {
  foreach (var c in CASES) {
    check_case (c, Ending.CANCELLED);
  }
}

void test_cancel_late () {
  foreach (var c in CASES) {
    check_case (c, Ending.CANCELLED_LATE);
  }
}

void test_cancel_before_start () {
  set_fake_commands ();
  foreach (var c in CASES) {
    File captured;
    AnnotatedRecording recording;
    var exporter = create_case (c, out captured, out recording);
    exporter.cancel ();
    try {
      export (exporter, recording);
      assert_not_reached ();
    } catch (RecordingError e) {
      assert (exporter.is_cancelled);
    }

    assert (get_log () == "");
    check_captured (captured);
  }

  unset_fake_commands ();
}

void test_cancel_while_rendering () {
  set_fake_commands ();
  File captured;
  AnnotatedRecording recording;
  var exporter = create_case (CASES[0], out captured, out recording);
  try {
    exporter.export.end (await ((callback) => {
      exporter.export.begin (recording, (owned) callback);
      // Images and output
      assert (list_temp_files ().length == 4);
      assert (get_log () == "");
      exporter.cancel ();
    }));
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (exporter.is_cancelled);
  }

  assert (get_log () == "");
  check_captured (captured);
  unset_fake_commands ();
}

// The items are those at the start of the export
void test_change_while_rendering () {
  set_fake_commands ();
  File captured;
  AnnotatedRecording recording;
  var exporter = create_case (CASES[0], out captured, out recording);
  try {
    var file = exporter.export.end (await ((callback) => {
      exporter.export.begin (recording, (owned) callback);
      recording.add (create_line (70));
      recording.remove (1);
      recording.remove (2);
      recording.remove (3);
    }));
    file.delete ();

    string arguments;
    FileUtils.get_contents (Path.build_filename (bin_dir, "args"), out arguments);
    assert ("crop=" in arguments);
    assert ("[2:v]" in arguments);
    assert (!("[3:v]" in arguments));
  } catch (Error e) {
    error (e.message);
  }

  assert (get_log () == "burn_in ");
  check_captured (captured);
  unset_fake_commands ();
}

void test_cancel_after_end () {
  File captured;
  AnnotatedRecording recording;
  Case c = { OutputFormat.WEBM, false, false, "" };
  var exporter = create_case (c, out captured, out recording);
  try {
    assert (export (exporter, recording) == captured);
  } catch (RecordingError e) {
    error (e.message);
  }

  exporter.cancel ();
  assert (exporter.is_cancelled);
  check_captured (captured);
}

// Runs a shell script once or twice
class ScriptStep : CliPostProcessor {
  private string script;
  private int runs;

  public ScriptStep (string script, int runs = 1) {
    this.script = script;
    this.runs = runs;
  }

  public override async Array<File>? process_async (Array<File> files) throws RecordingError {
    for (int i = 0; i < runs; i++) {
      yield spawn_command_async ({ "/bin/sh", "-c", script });
    }

    return files;
  }
}

// Returns the message of the error, "" if there is none
string run_script (ScriptStep step, uint cancel_after = 0) {
  var cancel_timeout = 0u;
  if (cancel_after != 0) {
    cancel_timeout = Timeout.add (cancel_after, () => {
      cancel_timeout = 0;
      step.cancel ();
      return false;
    });
  }

  string message = "";
  try {
    step.process_async.end (await ((callback) => {
      step.process_async.begin (new Array<File> (), (owned) callback);
    }));
  } catch (RecordingError e) {
    assert (e is RecordingError.POSTPROCESSING_ABORTED);
    message = e.message;
  }

  assert (cancel_timeout == 0);
  return message;
}

// More than fits into a pipe
const string MUCH_OUTPUT = "seq -f 'out %.0f' 100000; seq -f 'err %.0f' 100000 >&2; ";

void test_much_output () {
  assert_cmpstr (run_script (new ScriptStep (MUCH_OUTPUT, 2)), CompareOperator.EQ, "");

  var message = run_script (new ScriptStep (
    MUCH_OUTPUT + "printf 'caf\\303\\251 \\377\\nthe last line'; exit 3"));
  assert ("failed with status 768 (received signal 0)" in message);
  assert ("err 100000\ncafé " in message);
  assert (message.has_suffix ("the last line"));
  assert (message.validate ());
  assert (!("out 1\n" in message));
  assert (message.length < 100000);
}

void test_little_output () {
  var message = run_script (new ScriptStep ("echo one; echo two >&2; exit 1"));
  assert (message.has_suffix (
    "failed with status 256 (received signal 0).\n\nOutput:\none\ntwo\n"));
  message = run_script (new ScriptStep ("kill -9 $$"));
  assert (message.has_suffix ("failed with status 9 (received signal 9).\n\nOutput:\n"));
}

void test_cancel_output () {
  foreach (var script in new string[] {
    "exec yes",
    // Keeps the pipe open after the shell was killed
    "sleep 30 & while :; do echo x; done",
    "exec sleep 30",
    "exec >&- 2>&-; exec sleep 30"
  }) {
    var timer = new Timer ();
    var message = run_script (new ScriptStep (script, 2), 300);
    assert (message != "");
    assert (timer.elapsed () < 10);
  }
}

// Also if the step was not yet started when it was cancelled
void test_cancel_unstarted () {
  var marker = Path.build_filename (temp_dir, "started");
  var step = new ScriptStep ("touch '%s'".printf (marker));
  step.cancel ();
  assert (run_script (step) != "");
  assert (!FileUtils.test (marker, FileTest.EXISTS));
}

class TwoFilesStep : Object, PostProcessor {
  public async Array<File>? process_async (Array<File> files) throws RecordingError {
    var result = new Array<File> ();
    try {
      result.append_val (File.new_for_path (Utils.create_temp_file ("a")));
      result.append_val (File.new_for_path (Utils.create_temp_file ("b")));
    } catch (FileError e) {
      error (e.message);
    }

    return result;
  }

  public void cancel () {
  }
}

// Recordings without annotations still have their input deleted
void test_pipeline_deletes_input () {
  foreach (var keep_input in new bool[] { false, true }) {
    var pipeline = new PostProcessingPipeline ();
    assert (!pipeline.keep_input);
    pipeline.keep_input = keep_input;
    pipeline.add (new TwoFilesStep ());
    pipeline.add (new TwoFilesStep ());

    var path = Path.build_filename (temp_dir, "input");
    try {
      FileUtils.set_contents (path, "x");
      var files = new Array<File> ();
      files.append_val (File.new_for_path (path));
      pipeline.process_async.end (await ((callback) => {
        pipeline.process_async.begin (files, (owned) callback);
      }));
    } catch (Error e) {
      error (e.message);
    }

    assert (FileUtils.test (path, FileTest.EXISTS) == keep_input);
    assert (list_temp_files ().length == (keep_input ? 3 : 2));
    clear_temp_files ();
  }
}

void test_interface () {
  AnnotationEncoder[] encoders = {
    new Snapshot (),
    new RecordingExporter (File.new_for_path ("/captured"), new RecordingConfig ())
  };
  foreach (var encoder in encoders) {
    assert (!encoder.is_cancelled);
    encoder.cancel ();
    assert (encoder.is_cancelled);
  }
}

int main (string[] args) {
  try {
    dir = DirUtils.make_tmp ("peek-test-XXXXXX");
  } catch (FileError e) {
    error (e.message);
  }

  // Before anything asks for the directory of temporary files
  Environment.set_variable ("XDG_CACHE_HOME", dir, true);
  Test.init (ref args);
  temp_dir = Utils.get_temp_dir ();
  assert (temp_dir == Path.build_filename (dir, "peek"));
  bin_dir = Path.build_filename (dir, "bin");
  DirUtils.create (bin_dir, 0700);
  old_path = Environment.get_variable ("PATH");

  Test.add_func ("/recording_exporter/arguments", test_arguments);
  Test.add_func ("/recording_exporter/output_parameters", test_output_parameters);
  Test.add_func ("/recording_exporter/ranges", test_ranges);
  Test.add_func ("/recording_exporter/order", test_order);
  Test.add_func ("/recording_exporter/scale", test_scale);
  Test.add_func ("/recording_exporter/locale", test_locale);
  Test.add_func ("/recording_exporter/config_copy", test_config_copy);
  foreach (var name in new string[] {
    "constant.mkv", "variable.mkv", "ntsc.mkv", "close.mkv", "late-start.mkv",
    "late-video.mp4", "mp3.mp4", "opus.webm"
  }) {
    var clip = name;
    Test.add_data_func ("/recording_exporter/range/" + name.replace (".", "_"),
      () => test_range (clip));
  }

  Test.add_func ("/recording_exporter/hevc", () => test_codec ("hevc", "libx265"));
  Test.add_func ("/recording_exporter/av1", () => test_codec ("av1", "libsvtav1"));
  Test.add_func ("/recording_exporter/blur", test_blur);
  Test.add_func ("/recording_exporter/blur_below_shapes", test_blur_below_shapes);
  Test.add_func ("/recording_exporter/small_blurs", test_small_blurs);
  Test.add_func ("/recording_exporter/no_visible_items", test_no_visible_items);
  Test.add_func ("/recording_exporter/identical", test_identical);
  Test.add_func ("/recording_exporter/export", test_export);
  Test.add_func ("/recording_exporter/missing_input", test_missing_input);
  Test.add_func ("/recording_exporter/failures", test_failures);
  Test.add_func ("/recording_exporter/cancel", test_cancel);
  Test.add_func ("/recording_exporter/cancel_late", test_cancel_late);
  Test.add_func ("/recording_exporter/cancel_before_start", test_cancel_before_start);
  Test.add_func ("/recording_exporter/cancel_while_rendering", test_cancel_while_rendering);
  Test.add_func ("/recording_exporter/cancel_after_end", test_cancel_after_end);
  Test.add_func ("/recording_exporter/change_while_rendering", test_change_while_rendering);
  Test.add_func ("/recording_exporter/much_output", test_much_output);
  Test.add_func ("/recording_exporter/little_output", test_little_output);
  Test.add_func ("/recording_exporter/cancel_output", test_cancel_output);
  Test.add_func ("/recording_exporter/cancel_unstarted", test_cancel_unstarted);
  Test.add_func ("/recording_exporter/pipeline_input", test_pipeline_deletes_input);
  Test.add_func ("/recording_exporter/interface", test_interface);

  var result = Test.run ();
  clear_temp_files ();
  DirUtils.remove (temp_dir);
  DirUtils.remove (bin_dir);
  DirUtils.remove (dir);
  return result;
}
