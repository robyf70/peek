/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Peek.Annotations;
using Peek.PostProcessing;

namespace Peek.Recording {

  /**
  * Creates the file to be saved from a captured recording and the items drawn
  * on it. Use a new instance for each export.
  */
  public class RecordingExporter : Object, AnnotationEncoder {
    private File captured;
    private RecordingConfig config;
    private PostProcessingPipeline? pipeline = null;

    private bool cancelled = false;

    public bool is_cancelled {
      get { return cancelled; }
    }

    public RecordingExporter (File captured, RecordingConfig config) {
      this.captured = captured;
      this.config = config;
    }

    /**
    * Returns the captured file itself if nothing has to be done. Otherwise the
    * caller has to delete the returned file. The captured file is always kept.
    */
    public async File export (AnnotatedRecording recording) throws RecordingError {
      check_cancelled ();

      var pipeline = new PostProcessingPipeline () { keep_input = true };
      if (recording.has_items) {
        pipeline.add (new BurnInPostProcessor (recording, config));
      }

      pipeline.add_conversion (config);

      var files = new Array<File> ();
      files.append_val (captured);
      this.pipeline = pipeline;
      try {
        files = yield pipeline.process_async (files);
      } finally {
        this.pipeline = null;
      }

      if (files == null || files.length == 0) {
        check_cancelled ();
        throw new RecordingError.POSTPROCESSING_ABORTED (
          "Missing output file after post processing.");
      }

      var file = files.index (0);
      if (file.equal (captured)) {
        check_cancelled ();
        if (config.output_format == OutputFormat.GIF
            || config.output_format == OutputFormat.APNG) {
          throw new RecordingError.POSTPROCESSING_ABORTED (
            "No command was found to convert the recording.");
        }

        return captured;
      }

      if (cancelled) {
        FileUtils.remove (file.get_path ());
        check_cancelled ();
      }

      // As for recordings without items, temporary files are private
      FileUtils.chmod (file.get_path (), 0644);
      return file;
    }

    /**
    * Makes a running export fail. If it just succeeded the caller still has to
    * check is_cancelled.
    */
    public void cancel () {
      cancelled = true;
      if (pipeline != null) {
        pipeline.cancel ();
      }
    }

    private void check_cancelled () throws RecordingError {
      if (cancelled) {
        throw new RecordingError.POSTPROCESSING_ABORTED ("The export was cancelled.");
      }
    }
  }

}
