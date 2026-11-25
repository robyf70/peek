/*
Peek Copyright (c) 2017-2018 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Peek.PostProcessing;

namespace Peek.Recording {

  public abstract class BaseScreenRecorder : Object, ScreenRecorder {
    protected string temp_file;

    public bool is_recording { get; protected set; }

    public RecordingConfig config { get; protected set; }

    public RecordingConfig encoding_config { get; protected set; }

    public bool defer_post_processing { get; set; default = false; }

    // Values for the current recording
    private bool is_deferred = false;
    private bool is_capture_pending = false;

    private PostProcessor? active_post_processor = null;

    private bool _is_cancelling;
    protected bool is_cancelling {
      get {
        return _is_cancelling && !is_recording;
      }
    }

    private int64 start_time = 0;

    public int64 elapsed_seconds {
      get {
        if (start_time == 0) {
          return 0;
        }

        var now = get_monotonic_time ();
        return (now - start_time) / 1000000;
      }
    }

    protected BaseScreenRecorder () {
      config = new RecordingConfig ();

      // Runs before all other handlers
      recording_aborted.connect (() => {
        discard_pending_capture ();
      });
    }

    public void record (RecordingArea area) throws RecordingError {
      // Cancel running recording
      cancel ();
      encoding_config = create_encoding_config ();
      is_deferred = defer_post_processing;
      is_capture_pending = is_deferred;
      try {
        start_recording (area);
      } catch (RecordingError e) {
        discard_pending_capture ();
        throw e;
      }

      start_time = get_monotonic_time ();
    }

    public void stop () {
      debug ("Recording stopped");

      if (elapsed_seconds > 0) {
        _is_cancelling = false;
        is_recording = false;
        stop_recording ();
      } else {
        cancel ();
      }
    }

    protected void finalize_recording () {
      if (is_deferred) {
        hand_over_capture ();
        return;
      }

      start_post_processing (File.new_for_path (temp_file), config);
    }

    private void hand_over_capture () {
      // Cancelled or failed in the meantime
      if (!is_capture_pending) {
        return;
      }

      var file = File.new_for_path (temp_file);
      temp_file = null;
      is_capture_pending = false;
      is_recording = false;
      start_time = 0;
      FileUtils.chmod (file.get_path (), 0644);
      recording_captured (file);
    }

    private void discard_pending_capture () {
      if (is_capture_pending) {
        is_capture_pending = false;
        remove_temp_file ();
      }
    }

    public void post_process (File file) {
      // Set by a cancel after the recording was captured
      _is_cancelling = false;
      start_post_processing (file, encoding_config);
    }

    private void start_post_processing (File captured, RecordingConfig config) {
      debug ("Started post processing");
      var pipeline = build_post_processor_pipeline (config);
      run_post_processors_async.begin (pipeline, captured, (obj, res) => {
        debug ("Finished post processing");
        try {
          var file = run_post_processors_async.end (res);
          if (file != null) {
            FileUtils.chmod (file.get_path (), 0644);
            recording_finished (file);
          } else {
            var reason = new RecordingError.POSTPROCESSING_ABORTED (
              "Missing output file after post processing.");
            handle_postprocessing_failed (reason);
          }
        } catch (RecordingError e) {
          handle_postprocessing_failed (e);
        }
      });
      recording_postprocess_started ();
    }

    private void handle_postprocessing_failed (RecordingError reason) {
      if (_is_cancelling) {
        _is_cancelling = false;
        return;
      } else {
        recording_aborted (reason);
      }
    }

    public void cancel () {
      _is_cancelling = true;
      start_time = 0;
      if (is_recording) {
        is_recording = false;
        stop_recording ();
        remove_temp_file ();
        recording_aborted (null);
      } else if (active_post_processor != null) {
        active_post_processor.cancel ();
        active_post_processor = null;
        recording_aborted (null);
      } else if (is_capture_pending) {
        // Stopped, but the file is not finished yet
        recording_aborted (null);
      }
    }

    protected abstract void start_recording (RecordingArea area) throws RecordingError;
    protected abstract void stop_recording ();

    protected virtual RecordingConfig create_encoding_config () {
      return config.copy ();
    }

    protected virtual PostProcessingPipeline build_post_processor_pipeline (RecordingConfig config) {
      var pipeline = new PostProcessingPipeline ();
      pipeline.add_conversion (config);
      return pipeline;
    }

    private async File? run_post_processors_async (
      PostProcessingPipeline pipeline, File captured) throws RecordingError {
      var files = new Array<File> ();
      files.append_val (captured);

      active_post_processor = pipeline;
      try {
        files = yield pipeline.process_async (files);
      } finally {
        // Might already be that of the next recording
        if (active_post_processor == pipeline) {
          active_post_processor = null;
        }
      }

      // Might already be that of the next recording
      if (temp_file == captured.get_path ()) {
        temp_file = null;
      }

      if (files == null || files.length == 0) {
        return null;
      }

      return files.index (0);
    }

    protected void remove_temp_file () {
      if (temp_file != null) {
        FileUtils.remove (temp_file);
        temp_file = null;
      }
    }
  }

}
