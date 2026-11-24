using Peek.Recording;

void test_equals () {
  var area = RecordingArea () {
    left = 100,
    top = 200,
    width = 300,
    height = 400
  };

  assert (area.equals (area));
  assert (!area.equals (null));
  assert (!area.equals (RecordingArea ()));
  assert (area.equals (RecordingArea () {
    left = 100,
    top = 200,
    width = 300,
    height = 400
    })
  );
  assert (!area.equals (RecordingArea () {
    left = 101,
    top = 200,
    width = 300,
    height = 400
    })
  );
  assert (!area.equals (RecordingArea () {
    left = 100,
    top = 201,
    width = 300,
    height = 400
    })
  );
  assert (!area.equals (RecordingArea () {
    left = 100,
    top = 200,
    width = 301,
    height = 400
    })
  );
  assert (!area.equals (RecordingArea () {
    left = 100,
    top = 200,
    width = 300,
    height = 401
    })
  );
}

void assert_clipped (int left, int top, int width, int height,
  int expected_left, int expected_top, int expected_width, int expected_height) {
  var area = RecordingArea () {
    left = left, top = top, width = width, height = height
  };
  area.clip (1000, 800);
  assert (area.left == expected_left);
  assert (area.top == expected_top);
  assert (area.width == expected_width);
  assert (area.height == expected_height);
}

void test_clip () {
  assert_clipped (100, 200, 300, 400, 100, 200, 300, 400);
  assert_clipped (-50, 200, 300, 400, 0, 200, 250, 400);
  assert_clipped (100, -60, 300, 400, 100, 0, 300, 340);
  assert_clipped (900, 700, 300, 400, 900, 700, 100, 100);
  assert_clipped (-10, -10, 2000, 2000, 0, 0, 1000, 800);
}

void test_clip_outside () {
  var area = RecordingArea () { left = -500, top = 0, width = 300, height = 400 };
  area.clip (1000, 800);
  assert (area.width <= 0);

  area = RecordingArea () { left = 1200, top = 0, width = 300, height = 400 };
  area.clip (1000, 800);
  assert (area.width <= 0);
}

void main (string[] args) {
  Test.init (ref args);

  Test.add_func (
    "/screen-recorder/recording-area/test_equals",
    test_equals);

  Test.add_func (
    "/screen-recorder/recording-area/test_clip",
    test_clip);

  Test.add_func (
    "/screen-recorder/recording-area/test_clip_outside",
    test_clip_outside);

  Test.run ();
}
