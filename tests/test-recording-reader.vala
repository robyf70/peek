using Peek;
using Peek.Recording;

const string[] CLIPS = { "constant.mkv", "variable.mkv", "late-video.mp4", "late-start.mkv" };
const int N_FRAMES = 10;

string dir;
string old_path;

bool run_command (string[] argv) {
  string output, errors;
  int status;
  try {
    Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null,
      out output, out errors, out status);
  } catch (SpawnError e) {
    error (e.message);
  }

  if (status != 0) {
    Test.message ("%s", errors);
  }

  return status == 0;
}

// The gray of frame n is n * 10
string[] get_clip_args (string name) {
  var frames = "color=s=32x32:r=10:d=1,format=gray,geq=lum='N*10'";
  string[] args = { "ffmpeg", "-nostdin", "-v", "error", "-y" };

  switch (name) {
    case "variable.mkv":
      frames += ",setpts='N*(N+1)/2*0.1/TB'";
      break;
    case "late-video.mp4":
      frames += ",format=gbrp";
      foreach (var arg in new string[] {
        "-f", "lavfi", "-i", "sine=d=2", "-itsoffset", "0.5"
      }) {
        args += arg;
      }

      break;
  }

  foreach (var arg in new string[] { "-f", "lavfi", "-i", frames }) {
    args += arg;
  }

  string[] output_args;
  switch (name) {
    case "late-video.mp4":
      output_args = {
        "-map", "0:a", "-map", "1:v",
        "-c:v", "libx264rgb", "-qp", "0", "-c:a", "aac"
      };
      break;
    case "late-start.mkv":
      output_args = { "-c:v", "ffv1", "-output_ts_offset", "0.5" };
      break;
    default:
      output_args = { "-c:v", "ffv1" };
      break;
  }

  foreach (var arg in output_args) {
    args += arg;
  }

  args += Path.build_filename (dir, name);
  return args;
}

// Returns null if the clip cannot be made here
RecordingReader? open_clip (string name) {
  if (!RecordingReader.is_available ()) {
    Test.skip ("ffmpeg not found");
    return null;
  }

  var path = Path.build_filename (dir, name);
  if (!FileUtils.test (path, FileTest.EXISTS)) {
    if (name.has_suffix (".mp4")
      && !run_command ({ "sh", "-c", "ffmpeg -v error -encoders | grep -q libx264rgb" })) {
      Test.skip ("libx264rgb not found");
      return null;
    }

    if (!run_command (get_clip_args (name))) {
      error ("Failed to create %s", name);
    }
  }

  return new RecordingReader (File.new_for_path (path));
}

double get_expected_time (string name, int frame) {
  switch (name) {
    case "variable.mkv":
      return frame * (frame + 1) / 2 * 0.1;
    case "late-video.mp4":
      return 0.5 + frame * 0.1;
    default:
      return frame * 0.1;
  }
}

double[] read_times (RecordingReader reader) throws RecordingError {
  var loop = new MainLoop ();
  AsyncResult? result = null;
  reader.read_times.begin ((obj, res) => {
    result = res;
    loop.quit ();
  });
  loop.run ();
  return reader.read_times.end (result);
}

Gdk.Pixbuf read_frame (RecordingReader reader, int frame) throws RecordingError {
  var loop = new MainLoop ();
  AsyncResult? result = null;
  reader.read_frame.begin (frame, (obj, res) => {
    result = res;
    loop.quit ();
  });
  loop.run ();
  return reader.read_frame.end (result);
}

void wait (uint milliseconds) {
  var loop = new MainLoop ();
  Timeout.add (milliseconds, () => {
    loop.quit ();
    return false;
  });
  loop.run ();
}

// Uses a script as ffmpeg and ffprobe
void set_fake_commands (string script) {
  foreach (var name in new string[] { "ffmpeg", "ffprobe" }) {
    var path = Path.build_filename (dir, name);
    try {
      FileUtils.set_contents (path, "#!/bin/sh\n" + script);
    } catch (FileError e) {
      error (e.message);
    }

    FileUtils.chmod (path, 0755);
  }

  Environment.set_variable ("PATH", dir + ":" + old_path, true);
}

void unset_fake_commands () {
  Environment.set_variable ("PATH", old_path, true);
  foreach (var name in new string[] { "ffmpeg", "ffprobe", "pid" }) {
    FileUtils.remove (Path.build_filename (dir, name));
  }
}

const string FAKE_PROBE = """
case "$0" in
*ffprobe)
  printf 'best_effort_timestamp_time=0.0\nbest_effort_timestamp_time=0.1\nstart_time=0.0\n'
  exit 0;;
esac
""";

void test_parse_times () {
  var times = RecordingReader.parse_times (
    "best_effort_timestamp_time=0.900000\n"
    + "best_effort_timestamp_time=N/A\n"
    + "best_effort_timestamp_time=0.500000\n"
    + "best_effort_timestamp_time=0.700000\n"
    + "best_effort_timestamp_time=0.500000\n"
    + "start_time=0.500000\n");
  assert (times.length == 3);
  assert (times[0] == 0);
  assert (Math.fabs (times[1] - 0.2) < 1e-9);
  assert (Math.fabs (times[2] - 0.4) < 1e-9);
}

void test_parse_times_no_start () {
  var times = RecordingReader.parse_times (
    "best_effort_timestamp_time=0.500000\nstart_time=N/A\n");
  assert (times.length == 1);
  assert (times[0] == 0.5);
}

void test_parse_times_empty () {
  assert (RecordingReader.parse_times ("").length == 0);
  assert (RecordingReader.parse_times ("start_time=0.000000\n").length == 0);
}

void test_seek_time () {
  double[] times = { 0.5, 0.6, 1 };
  assert (RecordingReader.get_seek_time (times, 1) == "0.550000");
  assert (RecordingReader.get_seek_time (times, 2) == "0.800000");
}

void test_locale () {
  if (Intl.setlocale (LocaleCategory.ALL, "it_IT.UTF-8") == null) {
    Test.skip ("it_IT.UTF-8 not found");
    return;
  }

  assert ("%.1f".printf (0.5) == "0,5");
  test_seek_time ();
  test_parse_times ();
  Intl.setlocale (LocaleCategory.ALL, "C");
}

void test_clip (string name) {
  var reader = open_clip (name);
  if (reader == null) {
    return;
  }

  try {
    var times = read_times (reader);
    assert (times.length == N_FRAMES);
    for (int i = 0; i < N_FRAMES; i++) {
      assert (Math.fabs (times[i] - get_expected_time (name, i)) < 0.002);
    }

    foreach (var frame in new int[] { 0, 1, 5, N_FRAMES - 1 }) {
      var pixbuf = read_frame (reader, frame);
      assert (pixbuf.width == 32);
      assert (pixbuf.height == 32);
      assert (pixbuf.get_pixels ()[0] == frame * 10);
    }
  } catch (RecordingError e) {
    error (e.message);
  }
}

void test_request_frame () {
  var reader = open_clip (CLIPS[0]);
  if (reader == null) {
    return;
  }

  var log = "";
  var loop = new MainLoop ();
  reader.frame_ready.connect ((frame, pixbuf) => {
    assert (pixbuf.get_pixels ()[0] == frame * 10);
    log += "%d ".printf (frame);
    if (frame == 4) {
      loop.quit ();
    }
  });
  reader.frame_failed.connect ((frame, message) => {
    error (message);
  });

  try {
    read_times (reader);
  } catch (RecordingError e) {
    error (e.message);
  }

  for (int i = 1; i <= 4; i++) {
    reader.request_frame (i);
  }

  loop.run ();
  wait (500);
  assert (log == "1 4 ");
}

void test_missing_file () {
  if (!RecordingReader.is_available ()) {
    Test.skip ("ffmpeg not found");
    return;
  }

  var reader = new RecordingReader (File.new_for_path (Path.build_filename (dir, "missing")));
  try {
    read_times (reader);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert ("No such file" in e.message);
  }

  try {
    read_frame (reader, 0);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert ("No such file" in e.message);
  }
}

void test_unknown_frame () {
  var reader = new RecordingReader (File.new_for_path (Path.build_filename (dir, "missing")));
  foreach (var frame in new int[] { -1, 1 }) {
    try {
      read_frame (reader, frame);
      assert_not_reached ();
    } catch (RecordingError e) {
      assert ("There is no frame" in e.message);
    }
  }
}

void test_request_before_times () {
  var reader = new RecordingReader (File.new_for_path (Path.build_filename (dir, "missing")));
  Test.expect_message (null, LogLevelFlags.LEVEL_CRITICAL, "*assertion*failed*");
  reader.request_frame (0);
  Test.assert_expected_messages ();
}

// Both no frame times and no image, although the commands succeed
void test_no_output () {
  set_fake_commands ("echo the reason >&2\n");
  var reader = new RecordingReader (File.new_for_path ("/clip"));

  try {
    read_times (reader);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert ("the reason" in e.message);
  }

  try {
    read_frame (reader, 0);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert ("the reason" in e.message);
  }

  unset_fake_commands ();
}

// More errors than a pipe can hold, some of them not UTF-8
void test_errors () {
  set_fake_commands (FAKE_PROBE
    + "head -c 300000 /dev/zero | tr '\\0' 'x' >&2\nprintf '\\377 the end' >&2\nexit 1\n");
  var reader = new RecordingReader (File.new_for_path ("/clip"));

  try {
    read_times (reader);
    read_frame (reader, 1);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (e.message.validate ());
    assert (e.message.has_suffix ("the end"));
  }

  int failed = -1;
  var loop = new MainLoop ();
  reader.frame_failed.connect ((frame, message) => {
    failed = frame;
    reader.close ();
    loop.quit ();
  });
  reader.request_frame (0);
  reader.request_frame (1);
  loop.run ();
  wait (200);
  assert (failed == 0);

  unset_fake_commands ();
}

void test_close_in_handler () {
  var reader = open_clip (CLIPS[0]);
  if (reader == null) {
    return;
  }

  var count = 0;
  reader.frame_ready.connect (() => {
    count++;
    reader.close ();
  });
  reader.frame_failed.connect (() => {
    assert_not_reached ();
  });

  try {
    read_times (reader);
  } catch (RecordingError e) {
    error (e.message);
  }

  reader.request_frame (1);
  reader.request_frame (2);
  wait (1000);
  assert (count == 1);
}

void test_close () {
  set_fake_commands (FAKE_PROBE + "echo $$ > \"${0%/*}/pid\"\nexec sleep 30\n");
  var pid_file = Path.build_filename (dir, "pid");
  var reader = new RecordingReader (File.new_for_path ("/clip"));
  reader.frame_ready.connect (() => {
    assert_not_reached ();
  });
  reader.frame_failed.connect (() => {
    assert_not_reached ();
  });

  string pid = "";
  try {
    read_times (reader);
    reader.request_frame (0);
    reader.request_frame (1);
    while (!pid.has_suffix ("\n")) {
      wait (20);
      if (FileUtils.test (pid_file, FileTest.EXISTS)) {
        FileUtils.get_contents (pid_file, out pid);
      }
    }
  } catch (Error e) {
    error (e.message);
  }

  var proc = "/proc/" + pid.strip ();
  assert (FileUtils.test (proc, FileTest.EXISTS));

  var timer = new Timer ();
  Idle.add (() => {
    reader.close ();
    reader.close ();
    return false;
  });

  try {
    read_frame (reader, 1);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (e is RecordingError.POSTPROCESSING_ABORTED);
  }

  wait (200);
  assert (timer.elapsed () < 5);
  assert (!FileUtils.test (proc, FileTest.EXISTS));

  // Nothing is started any more
  FileUtils.remove (pid_file);
  reader.request_frame (1);
  try {
    read_times (reader);
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (e is RecordingError.POSTPROCESSING_ABORTED);
  }

  wait (200);
  assert (!FileUtils.test (pid_file, FileTest.EXISTS));
  unset_fake_commands ();
}

void test_close_idle () {
  var reader = new RecordingReader (File.new_for_path ("/clip"));
  reader.close ();
  reader.close ();
}

int main (string[] args) {
  Test.init (ref args);

  try {
    dir = DirUtils.make_tmp ("peek-test-XXXXXX");
  } catch (FileError e) {
    error (e.message);
  }

  old_path = Environment.get_variable ("PATH");

  Test.add_func ("/recording_reader/parse_times", test_parse_times);
  Test.add_func ("/recording_reader/parse_times_no_start", test_parse_times_no_start);
  Test.add_func ("/recording_reader/parse_times_empty", test_parse_times_empty);
  Test.add_func ("/recording_reader/seek_time", test_seek_time);
  Test.add_func ("/recording_reader/locale", test_locale);
  Test.add_func ("/recording_reader/constant_rate", () => test_clip (CLIPS[0]));
  Test.add_func ("/recording_reader/variable_rate", () => test_clip (CLIPS[1]));
  Test.add_func ("/recording_reader/late_video", () => test_clip (CLIPS[2]));
  Test.add_func ("/recording_reader/late_start", () => test_clip (CLIPS[3]));
  Test.add_func ("/recording_reader/request_frame", test_request_frame);
  Test.add_func ("/recording_reader/request_before_times", test_request_before_times);
  Test.add_func ("/recording_reader/unknown_frame", test_unknown_frame);
  Test.add_func ("/recording_reader/missing_file", test_missing_file);
  Test.add_func ("/recording_reader/no_output", test_no_output);
  Test.add_func ("/recording_reader/errors", test_errors);
  Test.add_func ("/recording_reader/close", test_close);
  Test.add_func ("/recording_reader/close_idle", test_close_idle);
  Test.add_func ("/recording_reader/close_in_handler", test_close_in_handler);

  var result = Test.run ();

  foreach (var name in CLIPS) {
    FileUtils.remove (Path.build_filename (dir, name));
  }

  DirUtils.remove (dir);
  return result;
}
