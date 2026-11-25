/*
Peek Copyright (c) 2017-2018 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Recording {
  public class RecordingConfig : Object {
    public OutputFormat output_format { get; set; default = OutputFormat.GIF; }
    public int framerate { get; set; default = DEFAULT_FRAMERATE; }
    public int downsample { get; set; default = DEFAULT_DOWNSAMPLE; }
    public bool capture_mouse { get; set; default = true; }
    public bool capture_sound { get; set; default = true; }
    public string mp4_codec { get; set; default = "h264"; }
    public bool mp4_vaapi { get; set; default = false; }
    public bool gifski_enabled { get; set; default = false; }
    public int gifski_quality { get; set; default = DEFAULT_GIFSKI_QUALITY; }

    public RecordingConfig copy () {
      return new RecordingConfig () {
        output_format = output_format, framerate = framerate, downsample = downsample,
        capture_mouse = capture_mouse, capture_sound = capture_sound,
        mp4_codec = mp4_codec, mp4_vaapi = mp4_vaapi,
        gifski_enabled = gifski_enabled, gifski_quality = gifski_quality
      };
    }
  }
}
