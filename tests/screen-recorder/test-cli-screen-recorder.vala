using Peek;
using Peek.Recording;

class TestCliScreenRecorder : CliScreenRecorder {
  public bool stop_command_called { get; set; default = false; }

  public override void start_recording (RecordingArea area) throws RecordingError {
    is_recording = true;
    stop_command_called = false;
  }

  protected override void stop_recording () {
    stop_command_called = true;
  }
}

void test_cancel () {
  var recorder = new TestCliScreenRecorder ();
  bool recording_aborted_called = false;
  recorder.recording_aborted.connect ((reason) => {
    recording_aborted_called = true;
    assert (reason == null);
  });

  try {
    recorder.record (RecordingArea ());
  } catch (RecordingError e) {
    assert (false);
  }

  assert (recorder.is_recording);
  assert (!recorder.stop_command_called);

  recorder.cancel ();

  assert (!recorder.is_recording);
  assert (recorder.stop_command_called);
  assert (recording_aborted_called);
}

// Records into a file of its own, with a process that exits 300 ms after being
// stopped unless a command is set
class TestCapturingRecorder : CliScreenRecorder {
  public string? path = null;
  public string command = "read line; sleep 0.3";
  public bool fail_to_start = false;

  public int captured = 0;
  public int started = 0;
  public int finished = 0;
  public int aborted = 0;
  public File? file = null;

  public TestCapturingRecorder () {
    config.output_format = OutputFormat.WEBM;
    recording_captured.connect ((file) => {
      captured++;
      this.file = file;
    });
    recording_postprocess_started.connect (() => started++);
    recording_finished.connect ((file) => {
      finished++;
      this.file = file;
    });
    recording_aborted.connect ((reason) => aborted++);
  }

  protected override void start_recording (RecordingArea area) throws RecordingError {
    try {
      FileUtils.close (FileUtils.open_tmp ("peek-test-XXXXXX", out temp_file));
    } catch (FileError e) {
      assert_not_reached ();
    }

    path = temp_file;
    if (fail_to_start) {
      throw new RecordingError.INITIALIZING_RECORDING_FAILED ("test");
    }

    spawn_record_command ({ "sh", "-c", command, path });
  }

  protected override void stop_recording () {
    try {
      size_t written;
      input.write_all ({ '\n' }, out written);
      input.flush ();
    } catch (Error e) {
      assert_not_reached ();
    }
  }

  public void start () {
    try {
      record (RecordingArea ());
    } catch (RecordingError e) {
      assert_not_reached ();
    }
  }

  public void finish () {
    Thread.usleep (1100000); // Shorter recordings are cancelled
    stop ();
  }

  // As the GNOME Shell recorder does after waiting, even if cancelled
  public void finalize_late () {
    finalize_recording ();
  }

  public bool file_exists () {
    return FileUtils.test (path, FileTest.EXISTS);
  }
}

void run_main_loop (uint milliseconds) {
  var loop = new MainLoop ();
  Timeout.add (milliseconds, () => {
    loop.quit ();
    return false;
  });
  loop.run ();
}

void test_not_deferred () {
  var recorder = new TestCapturingRecorder ();
  assert (!recorder.defer_post_processing);
  recorder.start ();
  recorder.defer_post_processing = true; // Only for the next recording
  recorder.finish ();
  run_main_loop (800);

  assert (recorder.captured == 0);
  assert (recorder.started == 1);
  assert (recorder.finished == 1);
  assert (recorder.aborted == 0);
  assert (recorder.file.get_path () == recorder.path);
  FileUtils.remove (recorder.path);
}

void test_deferred () {
  var recorder = new TestCapturingRecorder ();
  recorder.defer_post_processing = true;
  recorder.start ();
  recorder.defer_post_processing = false;
  recorder.config.output_format = OutputFormat.GIF;
  recorder.finish ();
  run_main_loop (800);

  assert (recorder.captured == 1);
  assert (recorder.started == 0);
  assert (recorder.finished == 0);
  assert (!recorder.is_recording);
  assert (recorder.file.get_path () == recorder.path);
  Posix.Stat info;
  assert (Posix.stat (recorder.path, out info) == 0);
  assert ((info.st_mode & 0777) == 0644);

  // The file now belongs to the receiver
  recorder.cancel ();
  assert (recorder.file_exists ());
  assert (recorder.aborted == 0);

  // Uses the settings of the recording, so there is no conversion to GIF
  recorder.post_process (recorder.file);
  assert (recorder.started == 1);
  run_main_loop (200);
  assert (recorder.finished == 1);
  assert (recorder.captured == 1);
  assert (recorder.aborted == 0);
  assert (recorder.file.get_path () == recorder.path);
  FileUtils.remove (recorder.path);
}

void test_post_process_failure_after_cancel () {
  if (!Utils.check_for_executable ("ffmpeg")) {
    Test.skip ("ffmpeg is missing");
    return;
  }

  var recorder = new TestCapturingRecorder ();
  recorder.config.output_format = OutputFormat.APNG;
  recorder.defer_post_processing = true;
  recorder.start ();
  recorder.finish ();
  run_main_loop (800);
  assert (recorder.captured == 1);

  recorder.cancel ();
  FileUtils.remove (recorder.path);
  recorder.post_process (recorder.file);
  run_main_loop (500);
  assert (recorder.finished == 0);
  assert (recorder.aborted == 1);
}

void test_cancel_after_post_process_failure () {
  if (!Utils.check_for_executable ("ffmpeg")) {
    Test.skip ("ffmpeg is missing");
    return;
  }

  // The recorded file is empty
  var recorder = new TestCapturingRecorder ();
  recorder.config.output_format = OutputFormat.APNG;
  recorder.start ();
  recorder.finish ();
  run_main_loop (1500);
  assert (recorder.aborted == 1);

  recorder.cancel ();
  assert (recorder.aborted == 1);

  recorder.start ();
  assert (recorder.aborted == 1);
  recorder.cancel ();
  assert (recorder.aborted == 2);
}

void test_deferred_process_exits_itself () {
  var recorder = new TestCapturingRecorder ();
  recorder.command = "true";
  recorder.defer_post_processing = true;
  recorder.start ();
  run_main_loop (200);
  assert (recorder.captured == 1);
  assert (!recorder.is_recording);

  recorder.cancel ();
  assert (recorder.aborted == 0);
  assert (recorder.file_exists ());
  FileUtils.remove (recorder.path);
}

void test_deferred_cancel_after_stop () {
  var recorder = new TestCapturingRecorder ();
  recorder.defer_post_processing = true;
  recorder.start ();
  recorder.finish ();
  recorder.cancel ();
  assert (recorder.aborted == 1);
  assert (!recorder.file_exists ());

  run_main_loop (800);
  recorder.finalize_late ();
  assert (recorder.captured == 0);
  assert (recorder.started == 0);
  assert (recorder.aborted == 1);
  assert (!recorder.file_exists ());
}

void test_cancelled_file_is_removed () {
  foreach (var record_again in new bool[] { false, true }) {
    // Creates its file only after it got cancelled
    var recorder = new TestCapturingRecorder ();
    recorder.command = "read line; sleep 0.3; : > \"$0\"";
    recorder.start ();
    var path = recorder.path;
    recorder.cancel ();
    assert (!FileUtils.test (path, FileTest.EXISTS));
    if (record_again) {
      recorder.command = "read line";
      recorder.start ();
    }

    run_main_loop (600);
    assert (!FileUtils.test (path, FileTest.EXISTS));
    if (record_again) {
      assert (recorder.is_recording);
      assert (recorder.file_exists ());
      recorder.cancel ();
      run_main_loop (100);
    }
  }
}

void test_deferred_record_after_cancel () {
  var recorder = new TestCapturingRecorder ();
  recorder.defer_post_processing = true;
  recorder.start ();
  var first_path = recorder.path;
  recorder.finish ();
  recorder.cancel ();

  // The first process is still running and must not end this recording
  recorder.start ();
  run_main_loop (800);
  assert (recorder.captured == 0);
  assert (recorder.is_recording);

  recorder.finish ();
  run_main_loop (800);
  assert (recorder.captured == 1);
  assert (recorder.aborted == 1);
  assert (recorder.file.get_path () == recorder.path);
  assert (recorder.file_exists ());
  assert (!FileUtils.test (first_path, FileTest.EXISTS));
  FileUtils.remove (recorder.path);
}

void test_deferred_record_when_captured () {
  var recorder = new TestCapturingRecorder ();
  recorder.defer_post_processing = true;
  string? first_path = null;
  recorder.recording_captured.connect ((file) => {
    if (first_path == null) {
      first_path = file.get_path ();
      recorder.start ();
    }
  });
  recorder.start ();
  recorder.finish ();
  run_main_loop (800);
  assert (recorder.is_recording);

  recorder.finish ();
  run_main_loop (800);
  assert (recorder.captured == 2);
  assert (recorder.aborted == 0);
  assert (FileUtils.remove (first_path) == 0);
  assert (FileUtils.remove (recorder.path) == 0);
}

void test_deferred_failure () {
  var recorder = new TestCapturingRecorder ();
  recorder.command = "read line; exit 1";
  recorder.defer_post_processing = true;
  recorder.start ();
  recorder.finish ();
  run_main_loop (300);
  assert (recorder.captured == 0);
  assert (recorder.aborted == 1);
  assert (!recorder.file_exists ());

  recorder.cancel ();
  assert (recorder.aborted == 1);

  recorder.fail_to_start = true;
  try {
    recorder.record (RecordingArea ());
    assert_not_reached ();
  } catch (RecordingError e) {
    assert (!recorder.file_exists ());
  }

  recorder.cancel ();
  assert (recorder.aborted == 1);
}

void test_encoding_config () {
  var recorder = new TestCliScreenRecorder ();
  recorder.config.mp4_codec = "h265";
  try {
    recorder.record (RecordingArea ());
  } catch (RecordingError e) {
    assert_not_reached ();
  }

  recorder.config.mp4_codec = "av1";
  assert (recorder.encoding_config.mp4_codec == "h265");
  recorder.cancel ();
  assert (recorder.encoding_config.mp4_codec == "h265");
}

void main (string[] args) {
  string cache_dir;
  try {
    cache_dir = DirUtils.make_tmp ("peek-test-XXXXXX");
  } catch (FileError e) {
    assert_not_reached ();
  }

  Environment.set_variable ("XDG_CACHE_HOME", cache_dir, true);

  Test.init (ref args);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_cancel",
    test_cancel);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_not_deferred",
    test_not_deferred);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred",
    test_deferred);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_post_process_failure_after_cancel",
    test_post_process_failure_after_cancel);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_cancel_after_post_process_failure",
    test_cancel_after_post_process_failure);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred_process_exits_itself",
    test_deferred_process_exits_itself);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred_cancel_after_stop",
    test_deferred_cancel_after_stop);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_cancelled_file_is_removed",
    test_cancelled_file_is_removed);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred_record_after_cancel",
    test_deferred_record_after_cancel);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred_record_when_captured",
    test_deferred_record_when_captured);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_deferred_failure",
    test_deferred_failure);

  Test.add_func (
    "/screen-recorder/cli-screen-recorder/test_encoding_config",
    test_encoding_config);

  Test.run ();

  DirUtils.remove (Path.build_filename (cache_dir, "peek"));
  DirUtils.remove (cache_dir);
}
