/*
Peek Copyright (c) 2016-2017 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Recording {

  public interface ScreenRecorder : Object {
    public abstract bool is_recording { get; protected set; }

    public abstract RecordingConfig config { get; protected set; }

    /**
    * Copy of the config made when the recording was started, with the settings
    * to use for encoding it again. Only available after the first recording.
    */
    public abstract RecordingConfig encoding_config { get; protected set; }

    /**
    * Whether recording_captured is emitted instead of starting the post
    * processing. Only read when a recording is started.
    */
    public abstract bool defer_post_processing { get; set; default = false; }

    public abstract int64 elapsed_seconds { get; }

    public signal void recording_started ();

    /**
    * The receiver owns the file.
    */
    public signal void recording_captured (File file);

    public signal void recording_postprocess_started ();

    public signal void recording_finished (File file);

    public signal void recording_aborted (RecordingError? reason);

    public abstract void record (RecordingArea area) throws RecordingError;

    public abstract void stop ();

    public abstract void cancel ();

    /**
    * Runs the post processing deferred by defer_post_processing.
    */
    public abstract void post_process (File file);
  }

}
