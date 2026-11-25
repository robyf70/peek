if get_option('build-tests')
  # /desktop-integration/
  test_desktop_integration = executable('test-desktop-integration',
    'test-desktop-integration.vala',
    join_paths(meson.source_root(), 'src/desktop-integration.vala'),
    join_paths(meson.source_root(), 'src/dbus/freedesktop-filemanager.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
    ],
  )
  test('Testing desktop-integration', test_desktop_integration)

  # /utils/
  test_utils = executable('test-utils',
    'test-utils.vala',
    join_paths(meson.source_root(), 'src/defaults.vala'),
    join_paths(meson.source_root(), 'src/utils.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
    ],
  )
  test('Testing utils', test_utils)

  # /screen-recorder/recording-area/
  test_utils = executable('test-cli-screen-recorder',
    'screen-recorder/test-cli-screen-recorder.vala',
    join_paths(meson.source_root(), 'src/post-processing/cli-post-processor.vala'),
    join_paths(meson.source_root(), 'src/post-processing/extract-frames-post-processor.vala'),
    join_paths(meson.source_root(), 'src/post-processing/ffmpeg-post-processor.vala'),
    join_paths(meson.source_root(), 'src/post-processing/gifski-post-processor.vala'),
    join_paths(meson.source_root(), 'src/post-processing/post-processing-pipeline.vala'),
    join_paths(meson.source_root(), 'src/post-processing/post-processor.vala'),
    join_paths(meson.source_root(), 'src/recording/recording-area.vala'),
    join_paths(meson.source_root(), 'src/recording/recording-config.vala'),
    join_paths(meson.source_root(), 'src/recording/screen-recorder.vala'),
    join_paths(meson.source_root(), 'src/recording/base-screen-recorder.vala'),
    join_paths(meson.source_root(), 'src/recording/cli-screen-recorder.vala'),
    join_paths(meson.source_root(), 'src/defaults.vala'),
    join_paths(meson.source_root(), 'src/errordomain.vala'),
    join_paths(meson.source_root(), 'src/utils.vala'),
    vala_args: ['--pkg', 'posix'],
    dependencies: [
      dependency('gtk+-3.0'),
    ],
  )
  test('Testing cli-screen-recorder', test_utils)

  test_recording_area = executable('test-recording-area',
    'screen-recorder/test-recording-area.vala',
    join_paths(meson.source_root(), 'src/recording/recording-area.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
    ],
  )
  test('Testing recording-area', test_recording_area)

  # /snapshot/
  test_snapshot = executable('test-snapshot',
    'test-snapshot.vala',
    join_paths(meson.source_root(), 'src/dbus/freedesktop-filemanager.vala'),
    join_paths(meson.source_root(), 'src/desktop-integration.vala'),
    join_paths(meson.source_root(), 'src/defaults.vala'),
    join_paths(meson.source_root(), 'src/errordomain.vala'),
    join_paths(meson.source_root(), 'src/utils.vala'),
    join_paths(meson.source_root(), 'src/post-processing/cli-post-processor.vala'),
    join_paths(meson.source_root(), 'src/post-processing/post-processor.vala'),
    join_paths(meson.source_root(), 'src/recording/recording-area.vala'),
    join_paths(meson.source_root(), 'src/recording/snapshot.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
    ],
  )
  test('Testing snapshot', test_snapshot)

  # /annotated-image/
  test_annotated_image = executable('test-annotated-image',
    'test-annotated-image.vala',
    join_paths(meson.source_root(), 'src/annotation/annotated-image.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
      meson.get_compiler('c').find_library('m', required: false),
    ],
  )
  test('Testing annotated-image', test_annotated_image)

  # /annotated-recording/
  test_annotated_recording = executable('test-annotated-recording',
    'test-annotated-recording.vala',
    join_paths(meson.source_root(), 'src/annotation/annotated-image.vala'),
    join_paths(meson.source_root(), 'src/annotation/annotated-recording.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
      meson.get_compiler('c').find_library('m', required: false),
    ],
  )
  test('Testing annotated-recording', test_annotated_recording)

  # /recording-reader/
  test_recording_reader = executable('test-recording-reader',
    'test-recording-reader.vala',
    join_paths(meson.source_root(), 'src/defaults.vala'),
    join_paths(meson.source_root(), 'src/errordomain.vala'),
    join_paths(meson.source_root(), 'src/utils.vala'),
    join_paths(meson.source_root(), 'src/recording/recording-reader.vala'),
    dependencies: [
      dependency('gtk+-3.0'),
      meson.get_compiler('c').find_library('m', required: false),
    ],
  )
  test('Testing recording-reader', test_recording_reader)
endif
