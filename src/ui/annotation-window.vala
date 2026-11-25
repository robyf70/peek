/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Gtk;
using Peek.Annotations;

namespace Peek.Ui {

  /**
  * Lets the user draw on a snapshot. The window never closes itself, its owner
  * has to destroy it.
  */
  [GtkTemplate (ui = "/com/uploadedlobster/peek/annotation-window.ui")]
  class AnnotationWindow : Gtk.Window {
    private struct ToolInfo {
      public Tool tool;
      public string icon_name;
      public string name;
      public string key;
      public string hint;
    }

    private struct ColorInfo {
      public string name;
      public string hex;
    }

    private struct WidthInfo {
      public string name;
      public int width;
    }

    private const ToolInfo[] TOOLS = {
      { Tool.RECTANGLE, "peek-rectangle-symbolic", N_ ("Rectangle"), "R",
        N_ ("Drag to draw a rectangle. Hold Shift for a square.") },
      { Tool.CIRCLE, "peek-circle-symbolic", N_ ("Circle"), "C",
        N_ ("Drag to draw an ellipse. Hold Shift for a circle.") },
      { Tool.LINE, "peek-line-symbolic", N_ ("Line"), "L",
        N_ ("Drag to draw a line. Hold Shift to snap to 45°.") },
      { Tool.ARROW, "peek-arrow-symbolic", N_ ("Arrow"), "A",
        N_ ("Drag from tail to tip. Hold Shift to snap to 45°.") },
      { Tool.BLUR, "peek-blur-symbolic", N_ ("Blur area"), "B",
        N_ ("Drag over the area to blur. Color and width do not apply.") },
      { Tool.TEXT, "peek-text-symbolic", N_ ("Text"), "T",
        N_ ("Click to place text. Enter confirms, Esc discards.") }
    };

    private const string DEFAULT_COLOR = "#e01b24";

    private const ColorInfo[] COLORS = {
      { N_ ("Red"), DEFAULT_COLOR },
      { N_ ("Yellow"), "#f6d32d" },
      { N_ ("Green"), "#2ec27e" },
      { N_ ("Blue"), "#1c71d8" },
      { N_ ("Black"), "#000000" },
      { N_ ("White"), "#ffffff" }
    };

    private const WidthInfo[] WIDTHS = {
      { N_ ("Thin"), 2 },
      { N_ ("Medium"), 4 },
      { N_ ("Thick"), 7 }
    };

    private const int SWATCH_SIZE = 18;

    // Shorter drags are ignored, in logical pixels
    private const double MIN_DRAG = 4;

    private const int MIN_ENTRY_WIDTH = 160;

    // Border width in peek.css
    private const int ENTRY_BORDER = 1;

    // Time in seconds for which the confirmation of a copy is displayed
    private const uint COPIED_MESSAGE_TIME = 4;

    public signal void save_requested ();

    public signal void cancelled ();

    public signal void cancel_refused ();

    /**
    * Cancel was requested while the window is busy.
    */
    public signal void encode_cancel_requested ();

    /**
    * The window was requested to close while it is busy.
    */
    public signal void close_requested ();

    /**
    * While busy only cancelling is possible.
    */
    public bool busy {
      get {
        return _busy;
      }
      set {
        _busy = value;
        draft = null;
        content_area.sensitive = !value;
        copy_button.sensitive = !value;
        save_button.sensitive = !value;
        update_undo_buttons ();

        if (!value) {
          canvas.grab_focus ();
        }
      }
    }

    [GtkChild]
    private unowned HeaderBar headerbar;

    [GtkChild]
    private unowned Button undo_button;

    [GtkChild]
    private unowned Button redo_button;

    [GtkChild]
    private unowned Button copy_button;

    [GtkChild]
    private unowned Button save_button;

    [GtkChild]
    private unowned Box content_area;

    [GtkChild]
    private unowned Box toolbar;

    [GtkChild]
    private unowned Box tool_box;

    [GtkChild]
    private unowned Box style_box;

    [GtkChild]
    private unowned Box color_box;

    [GtkChild]
    private unowned ColorButton custom_color_button;

    [GtkChild]
    private unowned Box width_box;

    [GtkChild]
    private unowned Overlay overlay;

    [GtkChild]
    private unowned DrawingArea canvas;

    [GtkChild]
    private unowned Entry text_entry;

    [GtkChild]
    private unowned Box status_bar;

    [GtkChild]
    private unowned Label status_label;

    [GtkChild]
    private unowned Label size_label;

    // All windows share the clipboard
    private static bool storing_clipboard = false;

    private GLib.Settings settings;
    private AnnotatedImage image;
    private int capture_scale;
    private RadioButton[] tool_buttons = {};
    private ToggleButton[] color_buttons = {};
    private bool updating_color_buttons = false;
    private CssProvider entry_style = new CssProvider ();
    private bool _busy = false;
    private ToolInfo tool = TOOLS[0];
    private Gdk.RGBA color;
    private int line_width;

    // The item being dragged
    private Annotation? draft = null;

    // Position of the text entry in image pixels
    private double text_x;
    private double text_y;

    private Gtk.Dialog? discard_dialog = null;
    private uint copied_message_timeout = 0;
    private uint entry_style_idle = 0;

    public AnnotationWindow (Gtk.Window parent, Gdk.Pixbuf pixbuf, int scale,
      string format_name) {
      Object (transient_for: parent);

      image = new AnnotatedImage (pixbuf, scale);
      image.changed.connect (on_image_changed);
      capture_scale = scale;
      settings = Peek.Application.get_app_settings ();

      // Questions asked by this window must not block other Peek windows
      new WindowGroup ().add_window (this);

      /// Translators: %s is the name of an image format, e.g. PNG
      save_button.label = _ ("Save as %s…").printf (format_name);
      size_label.label = "%d × %d".printf (image.width, image.height);

      text_entry.get_style_context ().add_provider (
        entry_style, STYLE_PROVIDER_PRIORITY_APPLICATION);
      overlay.get_child_position.connect (on_get_child_position);

      // Clicks which no other widget handled
      this.button_press_event.connect ((event) => {
        commit_text ();
        return false;
      });

      this.destroy.connect (() => {
        stop_copied_message ();

        if (entry_style_idle != 0) {
          Source.remove (entry_style_idle);
          entry_style_idle = 0;
        }
      });

      add_tool_buttons ();
      add_color_buttons ();
      add_width_buttons ();
      load_color ();
      update_undo_buttons ();
      show_hint ();
      set_initial_size (parent);
      canvas.grab_focus ();
    }

    /**
    * The annotated image. Confirms pending text first.
    */
    public Gdk.Pixbuf render () {
      commit_text ();
      return image.render ();
    }

    /**
    * Asks the user before annotations get lost. Emits either cancelled or
    * cancel_refused, possibly later.
    */
    public void request_cancel () {
      if (discard_dialog != null) {
        discard_dialog.present ();
        return;
      }

      if (!image.has_unsaved_changes && !has_pending_text () && draft == null) {
        cancelled ();
        return;
      }

      drop_draft ();

      discard_dialog = new MessageDialog (this,
        DialogFlags.MODAL | DialogFlags.DESTROY_WITH_PARENT,
        MessageType.QUESTION, ButtonsType.NONE,
        "%s", _ ("Discard annotations?"));
      discard_dialog.add_button (_ ("_Cancel"), ResponseType.CANCEL);
      var discard_button = discard_dialog.add_button (_ ("_Discard"), ResponseType.ACCEPT);
      discard_button.get_style_context ().add_class ("destructive-action");
      discard_dialog.set_default_response (ResponseType.CANCEL);
      discard_dialog.response.connect ((response) => {
        discard_dialog.destroy ();
        discard_dialog = null;

        if (response == ResponseType.ACCEPT) {
          cancelled ();
        } else {
          cancel_refused ();
        }
      });
      discard_dialog.present ();
    }

    public override bool delete_event (Gdk.EventAny event) {
      if (busy) {
        close_requested ();
      } else {
        request_cancel ();
      }

      return true;
    }

    public override bool key_press_event (Gdk.EventKey event) {
      return handle_key (event) || base.key_press_event (event);
    }

    private bool handle_key (Gdk.EventKey event) {
      var mods = event.state & accelerator_get_default_mod_mask ();
      var plain = mods == 0;
      var ctrl = mods == Gdk.ModifierType.CONTROL_MASK;
      var key = Gdk.keyval_to_lower (event.keyval);

      if (busy) {
        if (plain && key == Gdk.Key.Escape) {
          encode_cancel_requested ();
          return true;
        }

        return false;
      }

      // Finish the drag before doing anything else
      if (draft != null) {
        if (key == Gdk.Key.Escape) {
          drop_draft ();
        }

        return true;
      }

      if (ctrl && key == Gdk.Key.s) {
        save_requested ();
        return true;
      }

      var typing = get_focus () == text_entry;
      var has_selection = typing && text_entry.get_selection_bounds (null, null);

      if (ctrl && key == Gdk.Key.c && !has_selection) {
        copy ();
        return true;
      }

      if (typing) {
        return false;
      }

      if (ctrl && key == Gdk.Key.z) {
        undo ();
        return true;
      }

      if (mods == (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK)
          && key == Gdk.Key.z) {
        redo ();
        return true;
      }

      if (!plain) {
        return false;
      }

      switch (key) {
        case Gdk.Key.Escape:
          request_cancel ();
          return true;
        case Gdk.Key.Return:
        case Gdk.Key.KP_Enter:
        case Gdk.Key.ISO_Enter:
          if (get_focus () is Button) {
            return false;
          }

          save_requested ();
          return true;
        default:
          break;
      }

      for (int i = 0; i < TOOLS.length; i++) {
        if (Gdk.keyval_name (Gdk.keyval_to_upper (key)) == TOOLS[i].key) {
          tool_buttons[i].active = true;
          return true;
        }
      }

      return false;
    }

    private void add_tool_buttons () {
      RadioButton? group = null;
      foreach (var info in TOOLS) {
        var button = new RadioButton.from_widget (group);
        group = button;
        button.image = new Image.from_icon_name (info.icon_name, IconSize.BUTTON);
        add_icon_button (tool_box, button, _ (info.name),
          "%s (%s)".printf (_ (info.name), info.key));
        button.clicked.connect (() => {
          if (button.active) {
            select_tool (info);
          }
        });
        tool_buttons += button;
      }
    }

    private void add_color_buttons () {
      foreach (var info in COLORS) {
        var swatch_color = parse_color (info.hex);
        var button = new ToggleButton ();
        button.add (create_swatch ((cr, area) => {
          var alpha = area.is_sensitive () ? 1 : 0.4;
          cr.arc (SWATCH_SIZE / 2.0, SWATCH_SIZE / 2.0, SWATCH_SIZE / 2.0 - 0.5, 0, 2 * Math.PI);
          cr.set_source_rgba (swatch_color.red, swatch_color.green, swatch_color.blue, alpha);
          cr.fill_preserve ();
          cr.set_source_rgba (0.47, 0.46, 0.48, alpha);
          cr.set_line_width (1);
          cr.stroke ();
        }));
        add_icon_button (color_box, button, _ (info.name), _ (info.name));
        button.toggled.connect (() => {
          if (!updating_color_buttons) {
            select_color (swatch_color);
          }
        });
        color_buttons += button;
      }
    }

    private void add_width_buttons () {
      var saved_width = settings.get_int ("annotation-line-width");
      RadioButton? group = null;
      foreach (var info in WIDTHS) {
        var button = new RadioButton.from_widget (group);
        group = button;
        button.add (create_swatch ((cr, area) => {
          Gdk.cairo_set_source_rgba (cr, area.get_style_context ().get_color (area.get_state_flags ()));
          cr.rectangle (0, (SWATCH_SIZE - info.width) / 2.0, SWATCH_SIZE, info.width);
          cr.fill ();
        }));
        add_icon_button (width_box, button, _ (info.name), _ (info.name));

        // The last match is the widest one which fits
        if (info.width <= saved_width) {
          button.active = true;
          line_width = info.width;
        }

        button.toggled.connect (() => {
          if (button.active) {
            line_width = info.width;
            settings.set_int ("annotation-line-width", line_width);
            update_entry_style ();
          }
        });
      }
    }

    private static void add_icon_button (Box box, ToggleButton button,
      string name, string tooltip) {
      var radio = button as RadioButton;
      if (radio != null) {
        radio.set_mode (false);
      }

      button.focus_on_click = false;
      button.tooltip_text = tooltip;
      button.get_accessible ().set_name (name);
      box.add (button);
      button.show_all ();
    }

    private delegate void SwatchDrawFunc (Cairo.Context cr, Widget area);

    private static Widget create_swatch (owned SwatchDrawFunc draw_func) {
      var area = new DrawingArea ();
      area.set_size_request (SWATCH_SIZE, SWATCH_SIZE);
      area.halign = Align.CENTER;
      area.valign = Align.CENTER;
      area.draw.connect ((widget, cr) => {
        draw_func (cr, widget);
        return true;
      });
      return area;
    }

    private void select_tool (ToolInfo info) {
      commit_text ();
      tool = info;
      style_box.sensitive = tool.tool != Tool.BLUR;
      show_hint ();
    }

    private void load_color () {
      color = parse_color (settings.get_string ("annotation-color"));
      update_color ();
    }

    private void select_color (Gdk.RGBA new_color) {
      color = new_color;
      settings.set_string ("annotation-color", to_hex (color));
      update_color ();
    }

    private void update_color () {
      var hex = to_hex (color);

      updating_color_buttons = true;
      for (int i = 0; i < COLORS.length; i++) {
        color_buttons[i].active = COLORS[i].hex == hex;
      }
      updating_color_buttons = false;

      custom_color_button.rgba = color;
      update_entry_style ();
    }

    private static Gdk.RGBA parse_color (string text) {
      var rgba = Gdk.RGBA ();
      if (!rgba.parse (text)) {
        rgba.parse (DEFAULT_COLOR);
      }

      rgba.alpha = 1;
      return rgba;
    }

    private static string to_hex (Gdk.RGBA rgba) {
      return "#%02x%02x%02x".printf (
        (uint) Math.round (rgba.red * 255),
        (uint) Math.round (rgba.green * 255),
        (uint) Math.round (rgba.blue * 255));
    }

    /*
    * Fits the whole image, but uses at most 80% of the work area. The parent must
    * be realized.
    */
    private void set_initial_size (Gtk.Window parent) {
#if HAS_GDK_MONITOR
      var area = parent.get_display ().get_monitor_at_window (parent.get_window ()).get_workarea ();
#else
      var screen = parent.get_screen ();
      var area = screen.get_monitor_workarea (screen.get_monitor_at_window (parent.get_window ()));
#endif

      // The default size does not include the header bar
      int header_height, toolbar_height, status_height;
      headerbar.get_preferred_height (null, out header_height);
      toolbar.get_preferred_height (null, out toolbar_height);
      status_bar.get_preferred_height (null, out status_height);

      var device_scale = parent.get_scale_factor ();
      var width = image.width / device_scale + overlay.margin_start + overlay.margin_end + 1;
      var height = image.height / device_scale + overlay.margin_top + overlay.margin_bottom
        + toolbar_height + status_height + 3; // Two separators
      set_default_size (
        int.min (width, area.width * 8 / 10),
        int.min (height, area.height * 8 / 10 - header_height));
    }

    private void get_view (out double x, out double y, out double view_scale) {
      var width = canvas.get_allocated_width ();
      var height = canvas.get_allocated_height ();
      var device_scale = canvas.get_scale_factor ();
      view_scale = fit_scale (image.width, image.height, width, height, device_scale);

      // Align the image to device pixels to keep it sharp
      x = Math.floor ((width - image.width * view_scale) / 2 * device_scale) / device_scale;
      y = Math.floor ((height - image.height * view_scale) / 2 * device_scale) / device_scale;
    }

    private void to_image (double view_x, double view_y, out double x, out double y) {
      double left, top, view_scale;
      get_view (out left, out top, out view_scale);
      x = (view_x - left) / view_scale;
      y = (view_y - top) / view_scale;
    }

    private bool is_long_enough (Annotation a) {
      double view_scale;
      get_view (null, null, out view_scale);
      var dx = (a.x2 - a.x1).abs () * view_scale;
      var dy = (a.y2 - a.y1).abs () * view_scale;

      // A blur of an empty area would not be visible
      if (a.tool == Tool.BLUR && (dx == 0 || dy == 0)) {
        return false;
      }

      return Math.hypot (dx, dy) >= MIN_DRAG;
    }

    private Annotation create_annotation (double x, double y) {
      var annotation = new Annotation ();
      annotation.tool = tool.tool;
      annotation.color = color;
      annotation.width = line_width;
      annotation.x1 = annotation.x2 = x;
      annotation.y1 = annotation.y2 = y;
      return annotation;
    }

    private void drag_to (double view_x, double view_y, Gdk.ModifierType state) {
      double x, y;
      to_image (view_x, view_y, out x, out y);
      draft.x2 = x;
      draft.y2 = y;
      image.constrain (draft, (state & Gdk.ModifierType.SHIFT_MASK) != 0);
      canvas.queue_draw ();
    }

    private void drop_draft () {
      draft = null;
      canvas.queue_draw ();
    }

    [GtkCallback]
    private bool on_canvas_draw (Widget widget, Cairo.Context cr) {
      double left, top, view_scale;
      get_view (out left, out top, out view_scale);
      cr.translate (left, top);
      cr.scale (view_scale, view_scale);
      cr.rectangle (0, 0, image.width, image.height);
      cr.clip ();
      image.draw (cr, draft != null && is_long_enough (draft) ? draft : null);
      return true;
    }

    [GtkCallback]
    private void on_canvas_realize (Widget widget) {
      canvas.get_window ().set_cursor (
        new Gdk.Cursor.from_name (canvas.get_display (), "crosshair"));
    }

    [GtkCallback]
    private void on_canvas_size_allocate (Widget widget, Allocation allocation) {
      if (text_entry.visible && entry_style_idle == 0) {
        // The style must not change during the allocation
        entry_style_idle = Idle.add (() => {
          entry_style_idle = 0;
          update_entry_style ();
          return Source.REMOVE;
        });
      }
    }

    [GtkCallback]
    private bool on_canvas_button_press (Widget widget, Gdk.EventButton event) {
      if (event.type != Gdk.EventType.BUTTON_PRESS) {
        return true;
      }

      commit_text ();
      canvas.grab_focus ();

      double x, y;
      to_image (event.x, event.y, out x, out y);
      if (event.button != Gdk.BUTTON_PRIMARY
          || x < 0 || y < 0 || x >= image.width || y >= image.height) {
        return true;
      }

      if (tool.tool == Tool.TEXT) {
        start_text (x, y);
      } else {
        draft = create_annotation (x, y);
      }

      return true;
    }

    [GtkCallback]
    private bool on_canvas_motion (Widget widget, Gdk.EventMotion event) {
      if (draft == null) {
        return false;
      }

      if ((event.state & Gdk.ModifierType.BUTTON1_MASK) == 0) {
        // The button was released while another window had a grab
        drop_draft ();
        return false;
      }

      drag_to (event.x, event.y, event.state);
      return true;
    }

    [GtkCallback]
    private bool on_canvas_button_release (Widget widget, Gdk.EventButton event) {
      if (draft == null || event.button != Gdk.BUTTON_PRIMARY) {
        return false;
      }

      drag_to (event.x, event.y, event.state);
      var annotation = draft;
      drop_draft ();

      if (is_long_enough (annotation)) {
        image.add (annotation);
      }

      return true;
    }

    private void start_text (double x, double y) {
      text_x = x;
      text_y = y;
      text_entry.text = "";
      text_entry.show ();
      update_entry_style ();
      text_entry.grab_focus ();
    }

    private bool has_pending_text () {
      return text_entry.visible && text_entry.text.strip () != "";
    }

    private void commit_text () {
      if (!text_entry.visible) {
        return;
      }

      var pending = has_pending_text ();
      var annotation = create_annotation (text_x, text_y);
      annotation.tool = Tool.TEXT;
      annotation.text = text_entry.text;
      discard_text ();

      if (pending) {
        image.add (annotation);
      }
    }

    private void discard_text () {
      if (get_focus () == text_entry) {
        canvas.grab_focus ();
      }

      text_entry.hide ();
      text_entry.text = "";
    }

    private void update_entry_style () {
      double view_scale;
      get_view (null, null, out view_scale);

      // Same size as in AnnotatedImage
      var size = (12 + 3 * line_width) * capture_scale * view_scale;
      var css = "entry { color: %s; caret-color: %s; font-size: %spx; }".printf (
        to_hex (color), to_hex (color), size.to_string ());

      try {
        entry_style.load_from_data (css);
      } catch (Error e) {
        stderr.printf ("Setting style of text failed: %s\n", e.message);
      }

      overlay.queue_resize ();
    }

    private bool on_get_child_position (Widget widget, out Gdk.Rectangle allocation) {
      double left, top, view_scale;
      get_view (out left, out top, out view_scale);

      int height, text_width;
      text_entry.get_preferred_height (null, out height);
      text_entry.get_layout ().get_pixel_size (out text_width, null);

      // Leave space for the next character
      var width = int.max (text_width + height, MIN_ENTRY_WIDTH);
      var x = (int) Math.round (left + text_x * view_scale) - ENTRY_BORDER;
      var y = (int) Math.round (top + text_y * view_scale) - ENTRY_BORDER;

      // Keep the cursor visible close to the edges
      var view_width = overlay.get_allocated_width ();
      var view_height = overlay.get_allocated_height ();
      x = int.max (0, int.min (x, view_width - height * 2));
      y = int.max (0, int.min (y, view_height - height));
      allocation = Gdk.Rectangle () {
        x = x,
        y = y,
        width = int.max (1, int.min (width, view_width - x)),
        height = height
      };
      return true;
    }

    [GtkCallback]
    private void on_text_entry_activate () {
      commit_text ();
    }

    [GtkCallback]
    private void on_text_entry_changed () {
      overlay.queue_resize ();
    }

    [GtkCallback]
    private bool on_text_entry_key_press (Widget widget, Gdk.EventKey event) {
      if (event.keyval == Gdk.Key.Escape) {
        discard_text ();
        return true;
      }

      return false;
    }

    private void undo () {
      commit_text ();
      image.undo ();
    }

    private void redo () {
      commit_text ();
      image.redo ();
    }

    private void copy () {
      var clipboard = Clipboard.get_for_display (get_display (), Gdk.SELECTION_CLIPBOARD);
      clipboard.set_image (render ());
      clipboard.set_can_store (null);
      image.mark_copied ();
      show_copied_message ();

      // Runs a main loop, in which the window might change or get destroyed, so
      // this must come last and not use the window.
      if (!storing_clipboard) {
        storing_clipboard = true;
        clipboard.store ();
        storing_clipboard = false;
      }
    }

    private void show_hint () {
      stop_copied_message ();
      status_label.label = _ (tool.hint);
    }

    private void show_copied_message () {
      stop_copied_message ();
      status_label.label = _ ("Image copied to the clipboard.");
      copied_message_timeout = Timeout.add_seconds (COPIED_MESSAGE_TIME, () => {
        copied_message_timeout = 0;
        show_hint ();
        return Source.REMOVE;
      });
    }

    private void stop_copied_message () {
      if (copied_message_timeout != 0) {
        Source.remove (copied_message_timeout);
        copied_message_timeout = 0;
      }
    }

    private void update_undo_buttons () {
      undo_button.sensitive = !busy && image.can_undo;
      redo_button.sensitive = !busy && image.can_redo;
    }

    private void on_image_changed () {
      update_undo_buttons ();
      show_hint ();
      canvas.queue_draw ();
    }

    [GtkCallback]
    private void on_cancel_button_clicked (Button source) {
      if (busy) {
        encode_cancel_requested ();
      } else {
        request_cancel ();
      }
    }

    [GtkCallback]
    private void on_undo_button_clicked (Button source) {
      undo ();
    }

    [GtkCallback]
    private void on_redo_button_clicked (Button source) {
      redo ();
    }

    [GtkCallback]
    private void on_copy_button_clicked (Button source) {
      copy ();
    }

    [GtkCallback]
    private void on_save_button_clicked (Button source) {
      save_requested ();
    }

    [GtkCallback]
    private void on_custom_color_set (ColorButton source) {
      select_color (source.rgba);
    }
  }
}
