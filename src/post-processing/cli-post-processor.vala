/*
Peek Copyright (c) 2017 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.PostProcessing {

  /**
  * Common base class for post processors calling external CLI tools. Once
  * cancelled they do not start any more commands.
  */
  public abstract class CliPostProcessor : Object, PostProcessor {
    // How much of the end of a command's output is kept in bytes
    private const uint OUTPUT_LIMIT = 65536;

    private Subprocess? subprocess = null;
    private Cancellable cancellable = new Cancellable ();

    public abstract async Array<File>? process_async (Array<File> files) throws RecordingError;

    public void cancel () {
      cancellable.cancel ();

      if (subprocess != null) {
        subprocess.force_exit ();
      }
    }

    protected void check_cancelled () throws RecordingError {
      if (cancellable.is_cancelled ()) {
        throw new RecordingError.POSTPROCESSING_ABORTED ("The post processing was cancelled.");
      }
    }

    protected async int spawn_command_async (string[] argv) throws RecordingError {
      check_cancelled ();

      string output;
      try {
        subprocess = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
        output = yield read_output_async (subprocess);
        yield subprocess.wait_async ();
      } catch (Error e) {
        stderr.printf ("Error: %s\n", e.message);
        string message = Utils.get_command_failed_message (argv);
        throw new RecordingError.POSTPROCESSING_ABORTED (message);
      }

      int status = subprocess.get_status ();
      if (!Utils.is_exit_status_success (status)) {
        string message = Utils.get_command_failed_message (argv, subprocess, output);
        subprocess = null;
        throw new RecordingError.POSTPROCESSING_ABORTED (message);
      }

      subprocess = null;
      return status;
    }

    /**
    * Reads all output, as a command blocks once the pipe is full, and returns
    * the end of it.
    */
    private async string read_output_async (Subprocess process) {
      var pipe = process.get_stdout_pipe ();
      var buffer = new uint8[4096];
      var output = new ByteArray ();

      try {
        ssize_t length;
        while ((length = yield pipe.read_async (buffer, Priority.DEFAULT, cancellable)) > 0) {
          output.append (buffer[0:length]);
          if (output.len > OUTPUT_LIMIT) {
            output.remove_range (0, output.len - OUTPUT_LIMIT);
          }
        }
      } catch (IOError e) {
        // Nobody reads the output anymore
        process.force_exit ();
        if (!(e is IOError.CANCELLED)) {
          stderr.printf ("Error: %s\n", e.message);
        }
      }

      // The bytes are neither terminated nor necessarily valid UTF-8
      var text = new StringBuilder ();
      text.append_len ((string) output.data, (ssize_t) output.len);
      return Filename.display_name (text.str);
    }
  }
}
