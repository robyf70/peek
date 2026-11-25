/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

using Gtk;
using Peek.Annotations;

namespace Peek.Ui {

  /**
  * Shows the position in a recording and the items drawn on it. Changes ranges
  * itself, but only asks for moves of the playhead.
  */
  class RecordingTimeline : Gtk.Box {
    private const int VISIBLE_ROWS = 4;
    private const int NAME_CHARS = 11;
    private const int HANDLE_WIDTH = 6;
    private const int BAR_HEIGHT = 14;

    // Scrollbars must not cover the handles
    private const int END_MARGIN = 14;

    // Frame times can differ by rounding errors
    private const double TIME_TOLERANCE = 0.0005;

    private class Row : ListBoxRow {
      public int id;
      public Widget name_box;
      public DrawingArea bar = new DrawingArea ();

      public Row (Annotation item) {
        id = item.id;

        var info = AnnotationWindow.TOOLS[item.tool];
        var name = item.tool == Tool.TEXT ? item.text : _ (info.name);
        var label = new Label (name);
        label.ellipsize = Pango.EllipsizeMode.END;
        label.single_line_mode = true;
        label.xalign = 0;
        label.width_chars = label.max_width_chars = NAME_CHARS;

        var icon_and_name = new Box (Orientation.HORIZONTAL, 6);
        icon_and_name.add (new Image.from_icon_name (info.icon_name, IconSize.MENU));
        icon_and_name.add (label);
        name_box = icon_and_name;

        bar.set_size_request (2 * HANDLE_WIDTH, BAR_HEIGHT);
        bar.margin_end = END_MARGIN;
        bar.add_events (Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
          | Gdk.EventMask.POINTER_MOTION_MASK);

        var box = new Box (Orientation.HORIZONTAL, 6);
        box.add (name_box);
        box.pack_start (bar);
        add (box);

        tooltip_text = name;
        get_accessible ().set_name (name);
        set_left_to_right (this);
        show_all ();
      }
    }

    private AnnotatedRecording recording;
    private SizeGroup name_group = new SizeGroup (SizeGroupMode.HORIZONTAL);
    private Scale slider;
    private Label time_label;
    private Label frame_label;
    private Button start_button;
    private Button end_button;
    private ListBox list = new ListBox ();
    private ScrolledWindow scrolled_list = new ScrolledWindow (null, null);
    private bool updating_slider = false;
    private bool scroll_to_selected = false;
    private int _selected_id = 0;

    // The item whose range is being dragged, 0 if there is none
    private int drag_id = 0;
    private bool drag_start;
    private double drag_offset;
    // The playhead before the drag
    private int drag_frame;

    /**
    * The user wants to move the playhead.
    */
    public signal void frame_changed (int frame);

    /**
    * The user is about to select an item or to change a range.
    */
    public signal void editing ();

    /**
    * The selected item, 0 if there is none.
    */
    public int selected_id {
      get {
        return _selected_id;
      }
      set {
        var id = recording.find (value) != null ? value : 0;
        if (id != _selected_id) {
          _selected_id = id;
          list.select_row (find_row (id));
          scroll_to_selected = true;
          list.queue_resize ();
          update_buttons ();
        }
      }
    }

    public bool dragging {
      get { return drag_id != 0; }
    }

    public RecordingTimeline (AnnotatedRecording recording) {
      Object (orientation: Orientation.VERTICAL, spacing: 6, border_width: 6);
      this.recording = recording;

      var step_box = new Box (Orientation.HORIZONTAL, 4);
      add_step_button (step_box, "go-previous-symbolic", _ ("Previous frame"), -1);
      add_step_button (step_box, "go-next-symbolic", _ ("Next frame"), 1);
      name_group.add_widget (step_box);

      // Counts from one like the label
      slider = new Scale.with_range (
        Orientation.HORIZONTAL, 1, int.max (2, recording.n_frames), 1);
      slider.draw_value = false;
      slider.margin_end = END_MARGIN;
      slider.sensitive = recording.n_frames > 1;
      slider.get_accessible ().set_name (_ ("Position"));
      slider.value_changed.connect (() => {
        if (!updating_slider) {
          move_to ((int) Math.round (slider.get_value ()) - 1);
        }
      });

      var slider_box = new Box (Orientation.HORIZONTAL, 6);
      slider_box.add (step_box);
      slider_box.pack_start (slider);
      add (slider_box);

      time_label = new Label (null);
      frame_label = new Label (null);
      start_button = add_button (_ ("Start here"), () => set_range_end (true));
      end_button = add_button (_ ("End here"), () => set_range_end (false));

      var info_box = new Box (Orientation.HORIZONTAL, 12);
      info_box.add (time_label);
      info_box.add (frame_label);
      info_box.pack_end (end_button, false);
      info_box.pack_end (start_button, false);
      add (info_box);

      list.get_style_context ().add_class ("peek-timeline-list");
      list.row_selected.connect (on_row_selected);
      list.size_allocate.connect_after (on_list_size_allocate);
      scrolled_list.hscrollbar_policy = PolicyType.NEVER;
      scrolled_list.add (list);
      add (scrolled_list);

      // Always use the same size, so that new items do not resize the image
      int row_height, name_width;
      var sample = new Row (new Annotation ());
      list.add (sample);
      sample.get_preferred_height (null, out row_height);
      sample.name_box.get_preferred_width (null, out name_width);
      sample.destroy ();
      scrolled_list.min_content_height = VISIBLE_ROWS * row_height;
      step_box.set_size_request (name_width, -1);

      var placeholder = new Label (_ ("Items drawn on the recording are listed here."));
      placeholder.ellipsize = Pango.EllipsizeMode.END;
      placeholder.get_style_context ().add_class ("dim-label");
      placeholder.show ();
      list.set_placeholder (placeholder);

      recording.changed.connect (update);
      set_left_to_right (this);
      update ();
      update_buttons ();
      show_all ();
    }

    public void step (int frames) {
      move_to (recording.current_frame + frames);
    }

    /**
    * Moves by at least one frame.
    */
    public void step_seconds (int seconds) {
      var current = recording.current_frame;
      var frame = recording.frame_at (
        recording.get_time (current) + seconds + TIME_TOLERANCE);
      move_to (seconds > 0 ? int.max (frame, current + 1) : int.min (frame, current - 1));
    }

    public void move_to (int frame) {
      frame_changed (frame.clamp (0, recording.n_frames - 1));
      update_position ();
    }

    /**
    * Lets the selected item start or end at the playhead.
    */
    public void set_range_end (bool start) {
      var id = selected_id;
      cancel_drag ();
      editing ();
      selected_id = id;
      recording.change_range (id, start, recording.current_frame);
    }

    public void cancel_drag () {
      if (dragging) {
        drag_id = 0;
        recording.cancel_range_change ();
        move_to (drag_frame);
      }
    }

    private static string format_time (double time) {
      var hundredths = (int) Math.round (time * 100);
      return "%02d:%02d.%02d".printf (
        hundredths / 6000, hundredths / 100 % 60, hundredths % 100);
    }

    // Time runs from left to right in all languages
    private static void set_left_to_right (Widget widget) {
      widget.set_direction (TextDirection.LTR);
      var container = widget as Container;
      if (container != null) {
        container.forall ((child) => set_left_to_right (child));
      }
    }

    private void add_step_button (Box box, string icon_name, string name, int frames) {
      var button = add_button (null, () => step (frames));
      button.image = new Image.from_icon_name (icon_name, IconSize.BUTTON);
      button.tooltip_text = name;
      button.get_accessible ().set_name (name);
      box.add (button);
    }

    private delegate void ClickedFunc ();

    private static Button add_button (string? label, owned ClickedFunc on_clicked) {
      var button = label == null ? new Button () : new Button.with_label (label);
      button.focus_on_click = false;
      button.valign = Align.CENTER;
      button.clicked.connect (() => on_clicked ());
      return button;
    }

    private void update () {
      if (recording.find (selected_id) == null) {
        selected_id = 0;
      }

      update_rows ();
      update_position ();
    }

    private void update_position () {
      var frame = recording.current_frame;

      updating_slider = true;
      slider.set_value (frame + 1);
      updating_slider = false;

      time_label.label = "%s / %s".printf (
        format_time (recording.get_time (frame)), format_time (recording.duration));
      /// Translators: %d is the number of a frame in a recording, from 1
      frame_label.label = _ ("Frame %d").printf (frame + 1);
      list.queue_draw ();
    }

    private void update_buttons () {
      start_button.sensitive = end_button.sensitive = selected_id != 0;
    }

    // Keeps the rows of the items which are still there, as one of them might
    // have the focus.
    private void update_rows () {
      foreach (var child in list.get_children ()) {
        if (recording.find (((Row) child).id) == null) {
          child.destroy ();
        }
      }

      var items = recording.get_items ();
      for (int i = 0; i < items.length; i++) {
        var row = (Row?) list.get_row_at_index (i);
        if (row == null || row.id != items[i].id) {
          list.insert (create_row (items[i]), i);
        }
      }
    }

    private Row create_row (Annotation item) {
      var row = new Row (item);
      name_group.add_widget (row.name_box);
      row.bar.draw.connect ((widget, cr) => {
        draw_bar (widget, cr, row.id);
        return true;
      });
      row.bar.button_press_event.connect ((event) => {
        return on_bar_button_press (row, event);
      });
      row.bar.motion_notify_event.connect ((event) => {
        return on_bar_motion (row, event);
      });
      row.bar.button_release_event.connect (on_bar_button_release);
      row.bar.grab_broken_event.connect (() => {
        cancel_drag ();
        return false;
      });
      row.bar.grab_notify.connect ((was_grabbed) => {
        if (!was_grabbed) {
          cancel_drag ();
        }
      });
      return row;
    }

    private Row? find_row (int id) {
      foreach (var child in list.get_children ()) {
        var row = (Row) child;
        if (row.id == id) {
          return row;
        }
      }

      return null;
    }

    private void on_row_selected (ListBoxRow? row) {
      var id = row == null ? 0 : ((Row) row).id;
      if (id == selected_id) {
        return;
      }

      if (id != 0) {
        editing ();
      }

      selected_id = id;
    }

    private void on_list_size_allocate (Allocation allocation) {
      var row = list.get_selected_row ();
      if (scroll_to_selected && row != null) {
        Allocation area;
        row.get_allocation (out area);
        scrolled_list.vadjustment.clamp_page (area.y, area.y + area.height);
      }

      scroll_to_selected = false;
    }

    /*
    * The position of a bar. Short ones are enlarged to have space for both handles.
    */
    private void get_bar (Widget bar, Annotation item, out double left, out double right) {
      var width = bar.get_allocated_width ();
      left = (double) item.first_frame * width / recording.n_frames;
      right = (double) (item.last_frame + 1) * width / recording.n_frames;

      var min_width = 2 * HANDLE_WIDTH;
      if (right - left < min_width) {
        left = double.max (0, double.min ((left + right - min_width) / 2, width - min_width));
        right = left + min_width;
      }
    }

    private bool find_handle (Widget bar, Annotation item, double x, out bool start) {
      double left, right;
      get_bar (bar, item, out left, out right);
      start = x >= left && x < left + HANDLE_WIDTH;
      return start || (x >= right - HANDLE_WIDTH && x < right);
    }

    private void draw_bar (Widget bar, Cairo.Context cr, int id) {
      var item = recording.find (id);
      if (item == null) {
        return;
      }

      var width = bar.get_allocated_width ();
      var y = (bar.get_allocated_height () - BAR_HEIGHT) / 2;
      var color = bar.get_style_context ().get_color (bar.get_state_flags ());
      double left, right;
      get_bar (bar, item, out left, out right);

      fill (cr, color, 0.1, 0, y, width, BAR_HEIGHT);
      fill (cr, color, 0.35, left, y, right - left, BAR_HEIGHT);
      fill (cr, color, 0.5, left, y, HANDLE_WIDTH, BAR_HEIGHT);
      fill (cr, color, 0.5, right - HANDLE_WIDTH, y, HANDLE_WIDTH, BAR_HEIGHT);

      // The middle of the frame
      var x = Math.floor ((recording.current_frame + 0.5) * width / recording.n_frames);
      fill (cr, color, 1, x, 0, 1, bar.get_allocated_height ());
    }

    private static void fill (Cairo.Context cr, Gdk.RGBA color, double alpha,
      double x, double y, double width, double height) {
      cr.set_source_rgba (color.red, color.green, color.blue, color.alpha * alpha);
      cr.rectangle (x, y, width, height);
      cr.fill ();
    }

    private bool on_bar_button_press (Row row, Gdk.EventButton event) {
      var item = recording.find (row.id);
      bool start = false;
      if (event.button != Gdk.BUTTON_PRIMARY || dragging || item == null
          || !find_handle (row.bar, item, event.x, out start)) {
        // Selects the row
        return false;
      }

      if (event.type != Gdk.EventType.BUTTON_PRESS) {
        return true;
      }

      editing ();
      selected_id = item.id;

      var edge = (start ? item.first_frame : item.last_frame + 1);
      drag_id = item.id;
      drag_start = start;
      drag_offset = event.x - (double) edge * row.bar.get_allocated_width () / recording.n_frames;
      drag_frame = recording.current_frame;
      recording.begin_range_change ();
      return true;
    }

    private bool on_bar_motion (Row row, Gdk.EventMotion event) {
      if (!dragging) {
        update_cursor (row, event.x);
        return false;
      }

      if ((event.state & Gdk.ModifierType.BUTTON1_MASK) == 0) {
        // The button was released while another window had a grab
        cancel_drag ();
        return false;
      }

      var edge = (int) Math.round (
        (event.x - drag_offset) * recording.n_frames / row.bar.get_allocated_width ());
      recording.change_range (drag_id, drag_start, drag_start ? edge : edge - 1);

      var item = recording.find (drag_id);
      move_to (drag_start ? item.first_frame : item.last_frame);
      return true;
    }

    private bool on_bar_button_release (Gdk.EventButton event) {
      if (!dragging || event.button != Gdk.BUTTON_PRIMARY) {
        return false;
      }

      drag_id = 0;
      recording.end_range_change ();
      return true;
    }

    private void update_cursor (Row row, double x) {
      var item = recording.find (row.id);
      var on_handle = item != null && find_handle (row.bar, item, x, null);
      row.bar.get_window ().set_cursor (on_handle
        ? new Gdk.Cursor.from_name (get_display (), "ew-resize") : null);
    }
  }
}
