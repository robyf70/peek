/*
This file is part of Peek.

This software is licensed under the GNU General Public License
(version 3 or later). See the LICENSE file in this distribution.
*/

namespace Peek.Annotations {

  public enum Tool {
    RECTANGLE,
    CIRCLE,
    LINE,
    ARROW,
    BLUR,
    TEXT
  }

  /**
  * A drawn item. Coordinates are in image pixels, the width is unscaled. Must
  * not be modified once it was added to an image.
  */
  public class Annotation : Object {
    // Set when the item is added to an image, 0 before. Never reused there.
    public int id { get; set; }
    // Only used in recordings, both are included
    public int first_frame { get; set; }
    public int last_frame { get; set; }
    public Tool tool { get; set; default = Tool.RECTANGLE; }
    public double x1 { get; set; }
    public double y1 { get; set; }
    public double x2 { get; set; }
    public double y2 { get; set; }
    public Gdk.RGBA color { get; set; }
    public int width { get; set; default = 4; }
    public string text { get; set; default = ""; }

    internal Cairo.Surface? blur_cache = null;
    internal uint blur_source_id = 0;

    public Annotation copy () {
      return new Annotation () {
        id = id, first_frame = first_frame, last_frame = last_frame, tool = tool,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, color = color, width = width, text = text
      };
    }
  }

  /**
  * Logical pixels per image pixel needed to show the whole image in the view.
  * Images are never enlarged beyond one image pixel per device pixel.
  */
  public double fit_scale (int image_w, int image_h, int view_w, int view_h, int device_scale) {
    var scale = double.min ((double) view_w / image_w, (double) view_h / image_h);
    return double.min (1.0 / device_scale, scale);
  }

  /**
  * A captured image and the items drawn on it. Does not need a display.
  */
  public class AnnotatedImage : Object {
    public const int BLUR_SIZE = 16;
    private const double ARROW_ANGLE = 2.6;

    private Gdk.Pixbuf source;
    private Cairo.Surface source_surface;
    // Unique for each source of all images
    private uint source_id;
    private static uint last_source_id = 0;
    private int last_item_id = 0;

    // Item arrays must not be modified, as they are part of the history
    private GenericArray<GenericArray<Annotation>> undo_stack =
      new GenericArray<GenericArray<Annotation>> ();
    private GenericArray<GenericArray<Annotation>> redo_stack =
      new GenericArray<GenericArray<Annotation>> ();
    private GenericArray<Annotation>? copied_items = null;

    protected GenericArray<Annotation> items = new GenericArray<Annotation> ();

    public int scale { get; private set; }

    public signal void changed ();

    public int width {
      get { return source.width; }
    }

    public int height {
      get { return source.height; }
    }

    public bool can_undo {
      get { return undo_stack.length > 0; }
    }

    public bool can_redo {
      get { return redo_stack.length > 0; }
    }

    public bool has_unsaved_changes {
      get { return items.length > 0 && items != copied_items; }
    }

    public AnnotatedImage (Gdk.Pixbuf source, int scale) {
      this.scale = scale;
      load_source (source);
    }

    /**
    * Replaces the captured image by one of the same size.
    */
    public void set_source (Gdk.Pixbuf source)
      requires (source.width == width && source.height == height) {
      load_source (source);
      changed ();
    }

    /**
    * An item which was added before is copied, as it may be in the history.
    */
    public virtual void add (Annotation a) {
      var item = a.id == 0 ? a : a.copy ();
      item.id = ++last_item_id;
      var new_items = copy_items ();
      new_items.add (item);
      push_undo (items);
      items = new_items;
      changed ();
    }

    public virtual void undo () {
      move_last (undo_stack, redo_stack);
    }

    public virtual void redo () {
      move_last (redo_stack, undo_stack);
    }

    public void mark_copied () {
      copied_items = items;
    }

    /**
    * Draws in image pixels. The preview is an item which was not added yet.
    */
    public void draw (Cairo.Context cr, Annotation? preview = null) {
      cr.save ();
      cr.set_source_surface (source_surface, 0, 0);
      cr.paint ();

      // Blurs are always below all other items
      for (int i = 0; i < items.length; i++) {
        if (items[i].tool == Tool.BLUR && is_visible (items[i])) {
          draw_blur (cr, get_blur (items[i]));
        }
      }

      if (preview != null && preview.tool == Tool.BLUR) {
        draw_blur (cr, create_blur (preview));
      }

      for (int i = 0; i < items.length; i++) {
        if (is_visible (items[i])) {
          draw_item (cr, items[i]);
        }
      }

      if (preview != null) {
        draw_item (cr, preview);
      }

      cr.restore ();
    }

    public Gdk.Pixbuf render () {
      var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, width, height);
      draw (new Cairo.Context (surface));
      return Gdk.pixbuf_get_from_surface (surface, 0, 0, width, height);
    }

    /**
    * The item alone on a transparent image. Empty for blurs.
    */
    public Gdk.Pixbuf render_item (Annotation a) {
      var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, width, height);
      draw_item (new Cairo.Context (surface), a);
      return Gdk.pixbuf_get_from_surface (surface, 0, 0, width, height);
    }

    /**
    * The part of the image hidden by a blur, null if it is empty.
    */
    public Gdk.Rectangle? get_blur_region (Annotation a) {
      var left = (int) Math.floor (double.min (a.x1, a.x2));
      var top = (int) Math.floor (double.min (a.y1, a.y2));
      var right = (int) Math.ceil (double.max (a.x1, a.x2));
      var bottom = (int) Math.ceil (double.max (a.y1, a.y2));
      Gdk.Rectangle image = { 0, 0, width, height };
      Gdk.Rectangle region = { left, top, right - left, bottom - top };
      if (!image.intersect (region, out region)) {
        return null;
      }

      return region;
    }

    /**
    * The area the item is drawn in, which can exceed the image.
    */
    public Gdk.Rectangle get_bounds (Annotation a) {
      double left, top, right, bottom;
      var cr = new Cairo.Context (new Cairo.ImageSurface (Cairo.Format.ARGB32, 1, 1));

      switch (a.tool) {
        case Tool.BLUR:
          return get_blur_region (a) ?? Gdk.Rectangle () { x = (int) a.x1, y = (int) a.y1 };
        case Tool.TEXT:
          Pango.Rectangle ink, logical;
          create_layout (cr, a).get_pixel_extents (out ink, out logical);
          left = a.x1 + int.min (ink.x, logical.x);
          top = a.y1 + int.min (ink.y, logical.y);
          right = a.x1 + int.max (ink.x + ink.width, logical.x + logical.width);
          bottom = a.y1 + int.max (ink.y + ink.height, logical.y + logical.height);
          break;
        default:
          add_path (cr, a);
          cr.stroke_extents (out left, out top, out right, out bottom);
          break;
      }

      Gdk.Rectangle bounds = { (int) Math.floor (left), (int) Math.floor (top), 0, 0 };
      bounds.width = (int) Math.ceil (right) - bounds.x;
      bounds.height = (int) Math.ceil (bottom) - bounds.y;
      return bounds;
    }

    /**
    * Keeps the item inside the image. With shift also makes boxes square and
    * snaps lines to 45° steps.
    */
    public void constrain (Annotation a, bool shift) {
      a.x1 = a.x1.clamp (0, width);
      a.y1 = a.y1.clamp (0, height);

      if (shift) {
        snap (a);
      }

      a.x2 = a.x2.clamp (0, width);
      a.y2 = a.y2.clamp (0, height);
    }

    private void snap (Annotation a) {
      var dx = a.x2 - a.x1;
      var dy = a.y2 - a.y1;

      // Direction, each -1, 0 or 1, and length along each axis
      double sx, sy, length;

      switch (a.tool) {
        case Tool.RECTANGLE:
        case Tool.CIRCLE:
          sx = dx < 0 ? -1 : 1;
          sy = dy < 0 ? -1 : 1;
          length = double.max (dx.abs (), dy.abs ());
          break;
        case Tool.LINE:
        case Tool.ARROW:
          var angle = Math.round (Math.atan2 (dy, dx) / Math.PI_4) * Math.PI_4;
          sx = Math.round (Math.cos (angle));
          sy = Math.round (Math.sin (angle));
          length = (dx * sx + dy * sy) / (sx * sx + sy * sy);
          break;
        default:
          return;
      }

      if (sx != 0) {
        length = double.min (length, sx < 0 ? a.x1 : width - a.x1);
      }

      if (sy != 0) {
        length = double.min (length, sy < 0 ? a.y1 : height - a.y1);
      }

      a.x2 = a.x1 + sx * length;
      a.y2 = a.y1 + sy * length;
    }

    protected virtual bool is_visible (Annotation a) {
      return true;
    }

    protected GenericArray<Annotation> copy_items () {
      var copy = new GenericArray<Annotation> ();
      for (int i = 0; i < items.length; i++) {
        copy.add (items[i]);
      }

      return copy;
    }

    /**
    * Makes the items the state restored by the next undo.
    */
    protected void push_undo (GenericArray<Annotation> old_items) {
      undo_stack.add (old_items);
      redo_stack = new GenericArray<GenericArray<Annotation>> ();
    }

    private void move_last (GenericArray<GenericArray<Annotation>> from,
                            GenericArray<GenericArray<Annotation>> to) {
      if (from.length > 0) {
        to.add (items);
        items = from[from.length - 1];
        from.remove_index (from.length - 1);
        changed ();
      }
    }

    private void load_source (Gdk.Pixbuf source) {
      this.source = source;
      source_surface = create_surface (source);
      source_id = ++last_source_id;
    }

    // The surface is opaque, so a blur always hides what is below it.
    private static Cairo.Surface create_surface (Gdk.Pixbuf pixbuf) {
      var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, pixbuf.width, pixbuf.height);
      var cr = new Cairo.Context (surface);
      Gdk.cairo_set_source_pixbuf (cr, pixbuf, 0, 0);
      cr.paint ();
      return surface;
    }

    // Returns null if the region is empty. The surface is placed at the region.
    private Cairo.Surface? create_blur (Annotation a) {
      var region = get_blur_region (a);
      if (region == null) {
        return null;
      }

      var part = new Gdk.Pixbuf.subpixbuf (
        source, region.x, region.y, region.width, region.height);
      var small = part.scale_simple (
        int.max (1, region.width / (BLUR_SIZE * scale)),
        int.max (1, region.height / (BLUR_SIZE * scale)),
        Gdk.InterpType.BILINEAR);
      var surface = create_surface (small.scale_simple (
        region.width, region.height, Gdk.InterpType.BILINEAR));
      surface.set_device_offset (-region.x, -region.y);
      return surface;
    }

    private Cairo.Surface? get_blur (Annotation a) {
      if (a.blur_source_id != source_id) {
        a.blur_cache = create_blur (a);
        a.blur_source_id = source_id;
      }

      return a.blur_cache;
    }

    private static void draw_blur (Cairo.Context cr, Cairo.Surface? blur) {
      if (blur != null) {
        cr.set_source_surface (blur, 0, 0);
        cr.paint ();
      }
    }

    private void draw_item (Cairo.Context cr, Annotation a) {
      if (a.tool == Tool.BLUR) {
        return;
      }

      Gdk.cairo_set_source_rgba (cr, a.color);

      if (a.tool == Tool.TEXT) {
        draw_text (cr, a);
        return;
      }

      add_path (cr, a);
      cr.stroke ();
    }

    private void add_path (Cairo.Context cr, Annotation a) {
      cr.set_line_width (a.width * scale);
      cr.set_line_cap (Cairo.LineCap.ROUND);
      cr.set_line_join (Cairo.LineJoin.ROUND);
      cr.new_path ();

      switch (a.tool) {
        case Tool.RECTANGLE:
          cr.rectangle (a.x1, a.y1, a.x2 - a.x1, a.y2 - a.y1);
          break;
        case Tool.CIRCLE:
          add_ellipse (cr, a);
          break;
        case Tool.LINE:
          add_line (cr, a);
          break;
        case Tool.ARROW:
          add_line (cr, a);
          add_arrow_head (cr, a);
          break;
        default:
          break;
      }
    }

    private static void add_line (Cairo.Context cr, Annotation a) {
      cr.move_to (a.x1, a.y1);
      cr.line_to (a.x2, a.y2);
    }

    private static void add_ellipse (Cairo.Context cr, Annotation a) {
      // Cairo cannot scale by zero
      if (a.x1 == a.x2 || a.y1 == a.y2) {
        add_line (cr, a);
        return;
      }

      cr.save ();
      cr.translate ((a.x1 + a.x2) / 2, (a.y1 + a.y2) / 2);
      cr.scale ((a.x2 - a.x1) / 2, (a.y2 - a.y1) / 2);
      cr.arc (0, 0, 1, 0, 2 * Math.PI);
      cr.close_path ();
      cr.restore ();
    }

    private void add_arrow_head (Cairo.Context cr, Annotation a) {
      var angle = Math.atan2 (a.y2 - a.y1, a.x2 - a.x1);
      var length = (8 + 3 * a.width) * scale;
      cr.move_to (a.x2 + length * Math.cos (angle - ARROW_ANGLE),
                  a.y2 + length * Math.sin (angle - ARROW_ANGLE));
      cr.line_to (a.x2, a.y2);
      cr.line_to (a.x2 + length * Math.cos (angle + ARROW_ANGLE),
                  a.y2 + length * Math.sin (angle + ARROW_ANGLE));
    }

    private Pango.Layout create_layout (Cairo.Context cr, Annotation a) {
      var font = Pango.FontDescription.from_string ("sans bold");
      font.set_absolute_size ((12 + 3 * a.width) * scale * Pango.SCALE);
      var layout = Pango.cairo_create_layout (cr);
      layout.set_font_description (font);
      layout.set_text (a.text, -1);
      return layout;
    }

    private void draw_text (Cairo.Context cr, Annotation a) {
      cr.move_to (a.x1, a.y1);
      Pango.cairo_show_layout (cr, create_layout (cr, a));
      cr.new_path ();
    }
  }
}
