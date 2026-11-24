/*
Peek Copyright (c) 2017 by Philipp Wolfer <ph.wolfer@gmail.com>

This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Gtk;

namespace Peek.Ui {
  [GtkTemplate (ui = "/com/uploadedlobster/peek/set-window-size-dialog.ui")]
  class SetWindowSizeDialog : Gtk.Dialog {

    private static SetWindowSizeDialog? instance;

    public static Dialog present_single_instance (ApplicationWindow main_window) {
      if (instance == null) {
        instance = new SetWindowSizeDialog (main_window);
        instance.delete_event.connect ((event) => {
          instance = null;
          return false;
        });
      }

      int width, height;
      main_window.get_recording_view_size (out width, out height);
      instance.height = height;
      instance.width = width;

      instance.transient_for = main_window;
      instance.present ();
      return instance;
    }

    public static void close_instance () {
      if (instance != null) {
        instance.close ();
      }
    }

    [GtkChild]
    private unowned Adjustment width_adjustment;

    [GtkChild]
    private unowned Adjustment height_adjustment;

    private ApplicationWindow window;

    private SetWindowSizeDialog (ApplicationWindow window) {
      Object (use_header_bar: 1);
      this.window = window;
    }

    private int width {
      get {
        return (int) width_adjustment.value;
      }

      set {
        width_adjustment.value = value;
      }
    }

    private int height {
      get {
        return (int) height_adjustment.value;
      }

      set {
        height_adjustment.value = value;
      }
    }

    [GtkCallback]
    private void on_set_size_button_clicked (Button source) {
      window.resize_recording_area (width, height);
      this.close ();
    }

    [GtkCallback]
    private void on_cancel_button_clicked (Button source) {
      this.close ();
    }
  }
}
