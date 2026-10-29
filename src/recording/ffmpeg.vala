/*
Peek Copyright (c) 2015-2018 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Recording.Ffmpeg {
  public void add_output_parameters (
    Array<string> args, RecordingConfig config, out string extension) {
    if (config.output_format == OutputFormat.WEBM) {
      extension = Utils.get_file_extension_for_format (config.output_format);
      args.append_val ("-codec:v");
      args.append_val ("libvpx-vp9");
      args.append_val ("-qmin");
      args.append_val ("10");
      args.append_val ("-qmax");
      args.append_val ("50");
      args.append_val ("-crf");
      args.append_val ("13");
      args.append_val ("-b:v");
      args.append_val ("1M");
      args.append_val ("-pix_fmt");
      args.append_val ("yuv420p");
    } else if (config.output_format == OutputFormat.MP4) {
      extension = Utils.get_file_extension_for_format (config.output_format);
      args.append_val ("-codec:v");
      if (use_vaapi (config)) {
        // Frames arrive as VAAPI surfaces (see add_vaapi_filter), so no -pix_fmt
        args.append_val (config.mp4_codec + "_vaapi");
        if (config.mp4_codec == "hevc") {
          args.append_val ("-tag:v");
          args.append_val ("hvc1");
        }
      } else if (config.mp4_codec == "hevc") {
        args.append_val ("libx265");
        args.append_val ("-preset:v");
        args.append_val ("fast");
        // Without the hvc1 tag Apple players refuse HEVC in MP4
        args.append_val ("-tag:v");
        args.append_val ("hvc1");
      } else if (config.mp4_codec == "av1") {
        args.append_val ("libsvtav1");
        args.append_val ("-preset:v");
        args.append_val ("8");
      } else {
        args.append_val ("libx264");
        args.append_val ("-preset:v");
        args.append_val ("fast");
        if (!has_10bit_libx264 ()) {
          args.append_val ("-profile:v");
          args.append_val ("baseline");
        } else {
          stderr.printf ("Warning: libx264 compiled with 10bit support, baseline profile not available. The recorded MP4 might not be playable on all devices.\n");
        }
      }
      if (!use_vaapi (config)) {
        args.append_val ("-pix_fmt");
        args.append_val ("yuv420p");
      }
    } else {
      extension = "webm";
      args.append_val ("-codec:v");
      args.append_val ("libvpx-vp9");
      args.append_val ("-lossless");
      args.append_val ("1");
    }

    args.append_val ("-r");
    args.append_val (config.framerate.to_string ());
  }

  // ponytail: first render node only, add a device setting for multi-GPU machines
  private const string VAAPI_DEVICE = "/dev/dri/renderD128";

  public bool use_vaapi (RecordingConfig config) {
    return config.output_format == OutputFormat.MP4 && config.mp4_vaapi;
  }

  public void add_vaapi_device (Array<string> args, RecordingConfig config) {
    if (use_vaapi (config)) {
      args.append_val ("-vaapi_device");
      args.append_val (VAAPI_DEVICE);
    }
  }

  public string add_vaapi_filter (string filter, RecordingConfig config) {
    return use_vaapi (config) ? filter + ", format=nv12, hwupload" : filter;
  }

  private bool has_10bit_libx264 () {
    string[] args = {
      "ffmpeg", "-h", "encoder=libx264"
    };

    int status;
    string output;

    try {
      Process.spawn_sync (null, args, null,
        SpawnFlags.SEARCH_PATH,
        null, out output, null, out status);
      return output.index_of ("10le") != -1;
    } catch (SpawnError e) {
      debug ("Error: %s", e.message);
    }

    return false;
  }
}
