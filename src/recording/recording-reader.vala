/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Recording {

  /**
  * Reads the frame times and single frames of a recorded file.
  */
  public class RecordingReader : Object {
    private const string FRAME_TIME_KEY = "best_effort_timestamp_time=";
    private const string START_TIME_KEY = "start_time=";

    // Codecs of ffmpeg do not recommend more
    private const uint MAX_THREADS = 16;

    private string path;
    private double[] times = {};
    private GenericArray<Subprocess> processes = new GenericArray<Subprocess> ();
    private Cancellable cancellable = new Cancellable ();
    private bool is_fetching = false;
    private int pending_frame = -1;

    public signal void frame_ready (int frame, Gdk.Pixbuf pixbuf);
    public signal void frame_failed (int frame, string message);

    public RecordingReader (File file) {
      path = file.get_path ();
    }

    public static bool is_available () {
      return Utils.check_for_executable ("ffmpeg")
        && Utils.check_for_executable ("ffprobe");
    }

    /**
    * The times of all frames in seconds since the start of the file, in
    * ascending order. Has to be called before reading other than the first
    * frame.
    */
    public async double[] read_times () throws RecordingError {
      // Packets are not the same as frames, VP8 has packets that show nothing.
      string[] argv = {
        "ffprobe", "-v", "error",
        "-threads", uint.min (get_num_processors (), MAX_THREADS).to_string (),
        "-select_streams", "v:0",
        "-show_entries", "frame=best_effort_timestamp_time:format=start_time",
        "-of", "default=nw=1",
        path
      };

      string errors;
      var output = yield run (argv, out errors);
      var result = parse_times (to_text (output));
      if (result.length == 0) {
        throw new RecordingError.POSTPROCESSING_ABORTED (
          get_message (errors, "The recording has no frames."));
      }

      times = result;
      return result;
    }

    public async Gdk.Pixbuf read_frame (int frame) throws RecordingError {
      if (frame != 0 && (frame < 0 || frame >= times.length)) {
        throw new RecordingError.POSTPROCESSING_ABORTED (
          "There is no frame %i.".printf (frame));
      }

      string[] argv = { "ffmpeg", "-nostdin", "-v", "error" };
      if (frame > 0) {
        argv += "-ss";
        argv += get_seek_time (times, frame);
      }

      foreach (var arg in new string[] {
        "-i", path, "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "-"
      }) {
        argv += arg;
      }

      string errors;
      var output = yield run (argv, out errors);
      return decode (output, errors);
    }

    /**
    * Reads a frame and emits frame_ready or frame_failed. While a frame is being
    * read only the latest request is remembered.
    */
    public void request_frame (int frame)
      requires (frame >= 0 && frame < times.length) {
      pending_frame = frame;
      if (!is_fetching) {
        fetch.begin ();
      }
    }

    /**
    * Stops all reading. Nothing is read and no signals are emitted afterwards.
    */
    public void close () {
      cancellable.cancel ();
      for (int i = 0; i < processes.length; i++) {
        processes[i].force_exit ();
      }
    }

    /**
    * Parses the output of ffprobe.
    */
    public static double[] parse_times (string output) {
      double start_time = 0;
      var sorted = new GenericArray<double?> ();

      foreach (var line in output.split ("\n")) {
        double time;
        if (line.has_prefix (FRAME_TIME_KEY)) {
          if (double.try_parse (line.substring (FRAME_TIME_KEY.length), out time)) {
            sorted.add (time);
          }
        } else if (line.has_prefix (START_TIME_KEY)) {
          if (double.try_parse (line.substring (START_TIME_KEY.length), out time)) {
            start_time = time;
          }
        }
      }

      sorted.sort ((a, b) => {
        double first = a, second = b;
        return first < second ? -1 : (first > second ? 1 : 0);
      });

      double[] result = {};
      double previous = 0;
      for (int i = 0; i < sorted.length; i++) {
        double time = sorted[i];
        if (i == 0 || time != previous) {
          result += time - start_time;
        }

        previous = time;
      }

      return result;
    }

    /**
    * A time between the previous frame and this one, so that rounding cannot
    * lead to another frame.
    */
    public static string get_seek_time (double[] times, int frame)
      requires (frame > 0 && frame < times.length) {
      var buffer = new char[double.DTOSTR_BUF_SIZE];
      return ((times[frame - 1] + times[frame]) / 2).format (buffer, "%.6f");
    }

    private async void fetch () {
      is_fetching = true;

      while (pending_frame >= 0 && !cancellable.is_cancelled ()) {
        var frame = pending_frame;
        pending_frame = -1;

        Gdk.Pixbuf? pixbuf = null;
        string message = "";
        try {
          pixbuf = yield read_frame (frame);
        } catch (RecordingError e) {
          message = e.message;
        }

        if (cancellable.is_cancelled ()) {
          break;
        }

        if (pixbuf != null) {
          frame_ready (frame, pixbuf);
        } else {
          frame_failed (frame, message);
        }
      }

      is_fetching = false;
    }

    private async Bytes run (string[] argv, out string errors) throws RecordingError {
      Subprocess? process = null;
      Bytes? output = null;
      Bytes? error_output = null;

      try {
        cancellable.set_error_if_cancelled ();
        process = new Subprocess.newv (argv,
          SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        processes.add (process);
        yield process.communicate_async (null, cancellable, out output, out error_output);
        cancellable.set_error_if_cancelled ();
      } catch (Error e) {
        throw new RecordingError.POSTPROCESSING_ABORTED (e.message);
      } finally {
        if (process != null) {
          processes.remove (process);
        }
      }

      errors = to_text (error_output).strip ();
      if (!process.get_successful ()) {
        throw new RecordingError.POSTPROCESSING_ABORTED (get_message (
          errors, "%s failed with status %i.".printf (argv[0], process.get_status ())));
      }

      return output;
    }

    private static Gdk.Pixbuf decode (Bytes data, string errors) throws RecordingError {
      Gdk.Pixbuf? pixbuf = null;

      try {
        var loader = new Gdk.PixbufLoader ();
        if (data.length > 0) {
          // Closes the loader on errors
          loader.write (data.get_data ());
        }

        loader.close ();
        pixbuf = loader.get_pixbuf ();
      } catch (Error e) {
        throw new RecordingError.POSTPROCESSING_ABORTED (get_message (errors, e.message));
      }

      if (pixbuf == null) {
        throw new RecordingError.POSTPROCESSING_ABORTED (
          get_message (errors, "The frame could not be read."));
      }

      return pixbuf;
    }

    private static string get_message (string errors, string fallback) {
      return errors != "" ? errors : fallback;
    }

    // The bytes are neither terminated nor necessarily valid UTF-8
    private static string to_text (Bytes bytes) {
      var text = new StringBuilder ();
      if (bytes.length > 0) {
        text.append_len ((string) bytes.get_data (), (ssize_t) bytes.length);
      }

      return Filename.display_name (text.str);
    }
  }

}
