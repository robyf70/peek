/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Peek.Annotations;
using Peek.Recording;

namespace Peek.PostProcessing {

  /**
  * Uses ffmpeg to draw the items of a recording on its frames.
  */
  public class BurnInPostProcessor : CliPostProcessor {
    private AnnotatedRecording recording;
    private RecordingConfig config;

    public BurnInPostProcessor (AnnotatedRecording recording, RecordingConfig config) {
      this.recording = recording;
      this.config = config;
    }

    public override async Array<File>? process_async (Array<File> files) throws RecordingError {
      var items = recording.get_items ();
      string[] png_files = {};
      string? output_file = null;

      try {
        foreach (var item in items) {
          if (item.tool != Tool.BLUR) {
            png_files += Utils.create_temp_file ("png");
          }
        }

        output_file = Utils.create_temp_file (
          is_animation (config) ? "mkv" : Utils.get_file_extension_for_format (config.output_format));

        // Before anything else can change the items
        var args = build_arguments (
          recording, config, files.index (0).get_path (), png_files, output_file);

        int index = 0;
        foreach (var item in items) {
          if (item.tool != Tool.BLUR) {
            // Keeps the user interface responsive
            Idle.add (process_async.callback);
            yield;
            check_cancelled ();
            recording.render_item (item).save (png_files[index++], "png");
          }
        }

        yield spawn_command_async (args);
        check_cancelled ();
      } catch (Error e) {
        if (output_file != null) {
          FileUtils.remove (output_file);
        }

        throw new RecordingError.POSTPROCESSING_ABORTED (e.message);
      } finally {
        foreach (var png_file in png_files) {
          FileUtils.remove (png_file);
        }
      }

      var result = new Array<File> ();
      result.append_val (File.new_for_path (output_file));
      return result;
    }

    /**
    * The PNG files are those of all items other than blurs in drawing order.
    */
    public static string[] build_arguments (
      AnnotatedRecording recording, RecordingConfig config,
      string input, string[] png_files, string output) {
      var args = new Array<string> ();
      append (args, { "ffmpeg", "-nostdin", "-v", "error", "-y" });

      if (!is_animation (config)) {
        Ffmpeg.add_vaapi_device (args, config);
      }

      append (args, { "-i", input });
      foreach (var png_file in png_files) {
        append (args, { "-i", png_file });
      }

      append (args, {
        "-filter_complex", build_graph (recording, config),
        "-map", "[v]", "-map", "0:a?"
      });

      if (is_animation (config)) {
        // Lossless, the result is converted afterwards
        append (args, { "-c:v", "ffv1" });
      } else {
        Ffmpeg.add_codec_parameters (args, config);
      }

      // Keeps the times of all frames
      append (args, {
        "-c:a", "copy", "-fps_mode", "passthrough", "-enc_time_base", "-1", output
      });

      string[] result = {};
      for (uint i = 0; i < args.length; i++) {
        result += args.index (i);
      }

      return result;
    }

    // All in RGB, as 4:2:0 would move blurs to even positions, which leaves some
    // of the captured pixels visible, and would change frames without items.
    private static string build_graph (AnnotatedRecording recording, RecordingConfig config) {
      var blurs = new GenericArray<Annotation> ();
      var shapes = new GenericArray<Annotation> ();
      foreach (var item in recording.get_items ()) {
        if (item.tool != Tool.BLUR) {
          shapes.add (item);
        } else if (recording.get_blur_region (item) != null) {
          blurs.add (item);
        }
      }

      var graph = new StringBuilder ("[0:v]format=gbrp");
      if (blurs.length > 0) {
        graph.append_printf (",split=%d", blurs.length + 1);
      }

      graph.append ("[v0]");
      for (int i = 1; i <= blurs.length; i++) {
        graph.append_printf ("[c%d]", i);
      }

      int n = 0;
      for (int i = 0; i < blurs.length; i++) {
        var region = recording.get_blur_region (blurs[i]);
        var size = AnnotatedImage.BLUR_SIZE * recording.scale;
        n++;
        graph.append_printf (
          ";[c%d]crop=%d:%d:%d:%d,scale=%d:%d:flags=bilinear,scale=%d:%d:flags=bilinear[b%d]",
          n, region.width, region.height, region.x, region.y,
          int.max (1, region.width / size), int.max (1, region.height / size),
          region.width, region.height, n);
        graph.append_printf (";[v%d][b%d]overlay=%d:%d:%s[v%d]",
          n - 1, n, region.x, region.y, get_overlay_options (recording, blurs[i]), n);
      }

      for (int i = 0; i < shapes.length; i++) {
        n++;
        graph.append_printf (";[v%d][%d:v]overlay=%s[v%d]",
          n - 1, i + 1, get_overlay_options (recording, shapes[i]), n);
      }

      graph.append_printf (";[v%d]%s[v]", n, Ffmpeg.add_vaapi_filter ("null", config));
      return graph.str;
    }

    private static string get_overlay_options (AnnotatedRecording recording, Annotation a) {
      return "eof_action=repeat:format=gbrp:enable='gte(t,%s)*lt(t,%s)'".printf (
        a.first_frame == 0 ? "-1" : get_limit (recording, a.first_frame),
        a.last_frame == recording.n_frames - 1
          ? "1000000000" : get_limit (recording, a.last_frame + 1));
    }

    // Halfway to the previous frame, so that rounding cannot add or lose a frame
    private static string get_limit (AnnotatedRecording recording, int frame) {
      var buffer = new char[double.DTOSTR_BUF_SIZE];
      var time = (recording.get_time (frame - 1) + recording.get_time (frame)) / 2;
      return time.format (buffer, "%.6f");
    }

    private static bool is_animation (RecordingConfig config) {
      return config.output_format == OutputFormat.GIF
        || config.output_format == OutputFormat.APNG;
    }

    private static void append (Array<string> args, string[] values) {
      foreach (var value in values) {
        args.append_val (value);
      }
    }
  }
}
