/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Peek.PostProcessing;

namespace Peek.Recording {

  /**
  * Takes a single still image of the recording area. X11 only.
  */
  public class Snapshot : Object {
    private const string JPEG_QUALITY = "95";

    private StillGifConverter converter = new StillGifConverter ();

    public bool is_cancelled { get; private set; default = false; }

    public static bool is_format_available (OutputFormat format) {
      // On Wayland the X11 root window does not contain native windows
      if (!format.is_image () || DesktopIntegration.is_wayland ()) {
        return false;
      }

      return format != OutputFormat.STILL_GIF
        || Utils.check_for_executable ("ffmpeg");
    }

    public static Gdk.Pixbuf grab (RecordingArea area) throws RecordingError {
      if (area.width < 1 || area.height < 1) {
        throw new RecordingError.INITIALIZING_RECORDING_FAILED (
          "The area is not visible on the screen.");
      }

      // The area is in device pixels, but GDK expects logical pixels. The
      // resulting pixbuf has the full device resolution.
      int scale = area.widget.get_scale_factor ();
      var pixbuf = Gdk.pixbuf_get_from_window (
        Gdk.get_default_root_window (),
        area.left / scale, area.top / scale,
        area.width / scale, area.height / scale);

      if (pixbuf == null) {
        throw new RecordingError.INITIALIZING_RECORDING_FAILED (
          "The screen content could not be read.");
      }

      return pixbuf;
    }

    /**
    * Writes the image to a temporary file, which the caller has to delete.
    */
    public async File encode (Gdk.Pixbuf pixbuf, OutputFormat format) throws RecordingError {
      // gdk-pixbuf cannot write GIF, ffmpeg converts it from PNG.
      if (format == OutputFormat.STILL_GIF) {
        var png_file = save (pixbuf, OutputFormat.PNG);
        try {
          return yield converter.convert_async (png_file);
        } finally {
          FileUtils.remove (png_file.get_path ());
        }
      }

      return save (pixbuf, format);
    }

    /**
    * Makes a running encode fail. If it just succeeded the caller still has to
    * check is_cancelled.
    */
    public void cancel () {
      is_cancelled = true;
      converter.cancel ();
    }

    private static File save (Gdk.Pixbuf pixbuf, OutputFormat format) throws RecordingError {
      string? path = null;

      try {
        path = Utils.create_temp_file (Utils.get_file_extension_for_format (format));

        if (format == OutputFormat.JPEG) {
          pixbuf.save (path, "jpeg", "quality", JPEG_QUALITY);
        } else {
          pixbuf.save (path, format.to_string ());
        }

        return File.new_for_path (path);
      } catch (Error e) {
        if (path != null) {
          FileUtils.remove (path);
        }

        throw new RecordingError.POSTPROCESSING_ABORTED (e.message);
      }
    }
  }

  private class StillGifConverter : CliPostProcessor {
    public override async Array<File>? process_async (Array<File> files) throws RecordingError {
      var result = new Array<File> ();
      result.append_val (yield convert_async (files.index (0)));
      return result;
    }

    public async File convert_async (File png_file) throws RecordingError {
      string gif_path;
      try {
        gif_path = Utils.create_temp_file ("gif");
      } catch (FileError e) {
        throw new RecordingError.POSTPROCESSING_ABORTED (e.message);
      }

      string[] args = {
        "ffmpeg", "-y",
        "-i", png_file.get_path (),
        "-filter_complex", "split[a][b];[a]palettegen[p];[b][p]paletteuse",
        gif_path
      };

      try {
        yield spawn_command_async (args);
      } catch (RecordingError e) {
        FileUtils.remove (gif_path);
        throw e;
      }

      return File.new_for_path (gif_path);
    }
  }
}
