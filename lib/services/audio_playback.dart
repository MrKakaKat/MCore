import 'package:just_audio/just_audio.dart';

/// Plays the timeline's sound (one mixed-down file) and is the clock the
/// preview follows while it plays - see AppState.togglePlay. Behind an
/// interface so tests can drive a fake clock (the real player needs a
/// device).
abstract class AudioPlayback {
  /// Loads a WAV file; it repeats from the start when it reaches its end.
  Future<void> load(String path);

  /// Starts playing at `from` (timeline time) at `speed`.
  Future<void> start(Duration from, {double speed = 1});
  Future<void> pause();

  /// Where playback is now (timeline time), moving smoothly between the
  /// player's own updates.
  Duration get position;

  Future<void> dispose();
}

AudioPlayback createAudioPlayback() => JustAudioPlayback();

class JustAudioPlayback implements AudioPlayback {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> load(String path) async {
    await _player.setFilePath(path);
    await _player.setLoopMode(LoopMode.one);
  }

  @override
  Future<void> start(Duration from, {double speed = 1}) async {
    await _player.setSpeed(speed);
    await _player.seek(from);
    // play() completes only when playback stops - don't wait for it.
    _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Duration get position => _player.position;

  @override
  Future<void> dispose() => _player.dispose();
}
