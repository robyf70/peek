/*
Peek Copyright (c) 2017 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Peek.Recording;

namespace Peek.PostProcessing {

  /**
  * Uses ffmpeg to generate PNG images for each frame.
  */
  public class PostProcessingPipeline : Object, PostProcessor {
    private Array<PostProcessor> pipeline;
    private PostProcessor? active_post_processor = null;
    private bool cancelled = false;

    /**
    * Whether the files to process are kept. Those of all steps but the last one
    * are always deleted.
    */
    public bool keep_input { get; set; default = false; }

    public PostProcessingPipeline () {
      pipeline = new Array<PostProcessor>();
    }

    public void add (PostProcessor post_processor) {
      pipeline.append_val (post_processor);
    }

    /**
    * Adds the steps from a recorded file to the output format.
    */
    public void add_conversion (RecordingConfig config) {
      if (config.output_format == OutputFormat.GIF) {
        if (config.gifski_enabled && GifskiPostProcessor.is_available ()) {
          add (new ExtractFramesPostProcessor ());
          add (new GifskiPostProcessor (config));
        } else if (FfmpegPostProcessor.is_available ()) {
          add (new FfmpegPostProcessor (config));
        }
      } else if (config.output_format == OutputFormat.APNG) {
        add (new FfmpegPostProcessor (config));
      }
    }

    public async Array<File>? process_async (Array<File> files) throws RecordingError {
      var is_input = true;

      foreach (var post_processor in pipeline.data) {
        debug ("Running post processor %s with files %s", post_processor.get_type ().name (), files.length.to_string ());

        if (cancelled) {
          if (!is_input) {
            yield delete_files (files);
          }

          return null;
        }

        active_post_processor = post_processor;
        Array<File>? new_files = null;
        try {
          new_files = yield post_processor.process_async (files);
        } finally {
          if (!is_input || !keep_input) {
            yield delete_files (files);
          }
        }

        if (new_files == null) {
          cancelled = true;
          active_post_processor = null;
          return null;
        }

        files = new_files;
        is_input = false;
      }

      active_post_processor = null;

      return files;
    }

    public void cancel () {
      if (active_post_processor != null && !cancelled) {
        cancelled = true;
        active_post_processor.cancel ();
        active_post_processor = null;
      }
    }

    private static async void delete_files (Array<File> files) {
      foreach (var file in files.data) {
        try {
          yield file.delete_async ();
        } catch (Error e) {
          stderr.printf ("Error deleting temporary file %s: %s\n", file.get_path (), e.message);
        }
      }
    }
  }
}
