/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Annotations {

  /**
  * A recording and the items drawn on it, each visible on a range of frames.
  * The source is the frame shown, which is set by the user of this class.
  */
  public class AnnotatedRecording : AnnotatedImage {
    private const double DEFAULT_SECONDS = 3;

    private double[] times;
    private int _current_frame = 0;

    // The items before the current range change
    private GenericArray<Annotation>? range_base = null;

    public int n_frames {
      get { return times.length; }
    }

    public int current_frame {
      get { return _current_frame; }
      set {
        var frame = value.clamp (0, n_frames - 1);
        if (frame != _current_frame) {
          _current_frame = frame;
          changed ();
        }
      }
    }

    public double duration {
      get {
        var last = n_frames - 1;
        return last < 1 ? 0 : times[last] + (times[last] - times[last - 1]);
      }
    }

    public bool has_items {
      get { return items.length > 0; }
    }

    /**
    * The times are those of all frames in seconds, in ascending order.
    */
    public AnnotatedRecording (Gdk.Pixbuf first_frame, int scale, double[] times)
      requires (times.length > 0) {
      base (first_frame, scale);
      this.times = times;
    }

    public double get_time (int frame) {
      return times[frame.clamp (0, n_frames - 1)];
    }

    /**
    * The last frame whose time is not after the given one.
    */
    public int frame_at (double time) {
      int frame = 0;
      while (frame + 1 < n_frames && times[frame + 1] <= time) {
        frame++;
      }

      return frame;
    }

    public Annotation[] get_items () {
      Annotation[] result = {};
      for (int i = 0; i < items.length; i++) {
        result += items[i];
      }

      return result;
    }

    public Annotation? find (int id) {
      var index = index_of (id);
      return index < 0 ? null : items[index];
    }

    /**
    * Adds the item at the current frame, blurs to the whole recording.
    */
    public override void add (Annotation a) {
      end_range_change ();

      var item = a;
      if (a.id != 0) {
        item = a.copy ();
        item.id = 0;
      }

      if (item.tool == Tool.BLUR) {
        item.first_frame = 0;
        item.last_frame = n_frames - 1;
      } else {
        item.first_frame = current_frame;
        item.last_frame = current_frame;
        var end = get_time (current_frame) + DEFAULT_SECONDS;
        while (item.last_frame + 1 < n_frames && times[item.last_frame + 1] < end) {
          item.last_frame++;
        }
      }

      base.add (item);
    }

    public override void undo () {
      end_range_change ();
      base.undo ();
    }

    public override void redo () {
      end_range_change ();
      base.redo ();
    }

    public void remove (int id) {
      end_range_change ();

      var index = index_of (id);
      if (index >= 0) {
        var new_items = copy_items ();
        new_items.remove_index (index);
        push_undo (items);
        items = new_items;
        changed ();
      }
    }

    /**
    * All changes until the end are one undo step.
    */
    public void begin_range_change () {
      end_range_change ();
      range_base = items;
    }

    /**
    * Moves the start or the end of an item. It stops at the other one.
    */
    public void change_range (int id, bool start, int frame) {
      var index = index_of (id);
      if (index < 0) {
        return;
      }

      var item = items[index].copy ();
      var limited = frame.clamp (0, n_frames - 1);
      if (start) {
        item.first_frame = int.min (limited, item.last_frame);
      } else {
        item.last_frame = int.max (limited, item.first_frame);
      }

      if (has_same_range (item, items[index])) {
        return;
      }

      item.blur_cache = items[index].blur_cache;
      item.blur_source_id = items[index].blur_source_id;

      var new_items = copy_items ();
      new_items[index] = item;
      if (range_base == null) {
        push_undo (items);
      }

      items = new_items;
      changed ();
    }

    public void end_range_change () {
      if (range_base == null) {
        return;
      }

      var old_items = range_base;
      if (!is_range_changed (old_items)) {
        cancel_range_change ();
        return;
      }

      range_base = null;
      push_undo (old_items);
      changed ();
    }

    public void cancel_range_change () {
      if (range_base == null) {
        return;
      }

      var old_items = range_base;
      range_base = null;
      if (items != old_items) {
        items = old_items;
        changed ();
      }
    }

    protected override bool is_visible (Annotation a) {
      return a.first_frame <= current_frame && current_frame <= a.last_frame;
    }

    private int index_of (int id) {
      for (int i = 0; i < items.length; i++) {
        if (items[i].id == id) {
          return i;
        }
      }

      return -1;
    }

    private bool is_range_changed (GenericArray<Annotation> old_items) {
      for (int i = 0; i < items.length; i++) {
        if (!has_same_range (items[i], old_items[i])) {
          return true;
        }
      }

      return false;
    }

    private static bool has_same_range (Annotation a, Annotation b) {
      return a.first_frame == b.first_frame && a.last_frame == b.last_frame;
    }
  }
}
