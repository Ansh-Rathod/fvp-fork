// Copyright 2022-2024 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'; //
import 'package:logging/logging.dart';

import '../mdk.dart' as mdk;
import '../mdk.dart';
import 'extensions.dart';
import 'video_player/video_player_platform.dart';

final _log = Logger('fvp');

class MdkVideoPlayer extends mdk.Player {
  final streamCtl = StreamController<VideoEvent>();
  bool _initialized = false;

  @override
  void dispose() {
    onMediaStatus(null);
    onEvent(null);
    onStateChanged(null);
    streamCtl.close();
    _initialized = false;
    super.dispose();
  }

  MdkVideoPlayer() : super() {
    onMediaStatus((oldValue, newValue) {
      _log.fine(
          '$hashCode player$nativeHandle onMediaStatus: $oldValue => $newValue');
      if (!oldValue.test(mdk.MediaStatus.loaded) &&
          newValue.test(mdk.MediaStatus.loaded)) {
        // initialized event must be sent only once. keep_open=1 is another solution
        //if ((textureId.value ?? -1) >= 0) {
        //  return true; // prepared callback is invoked before MediaStatus.loaded, so textureId can be a valid value here
        //}
        if (_initialized) {
          _log.fine('$hashCode player$nativeHandle already initialized');
          return true;
        }
        _initialized = true;
        textureSize.then((size) {
          if (size == null) {
            return;
          }
          streamCtl.add(VideoEvent(
              eventType: VideoEventType.initialized,
              duration: Duration(
                  microseconds: isLive
// int max for live streams, duration.inMicroseconds == 9223372036854775807
                      ? double.maxFinite.toInt()
                      : mediaInfo.duration * 1000),
              size: size));
        });
      } else if (!oldValue.test(mdk.MediaStatus.buffering) &&
          newValue.test(mdk.MediaStatus.buffering)) {
        streamCtl.add(VideoEvent(eventType: VideoEventType.bufferingStart));
      } else if (!oldValue.test(mdk.MediaStatus.buffered) &&
          newValue.test(mdk.MediaStatus.buffered)) {
        streamCtl.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
      }
      return true;
    });

    onEvent((ev) {
      _log.fine(
          '$hashCode player$nativeHandle onEvent: ${ev.category} - ${ev.detail} - ${ev.error}');
      if (ev.category == "reader.buffering") {
        final pos = position;
        final bufLen = buffered();
        streamCtl.add(
            VideoEvent(eventType: VideoEventType.bufferingUpdate, buffered: [
          DurationRange(
              Duration(microseconds: pos), Duration(milliseconds: pos + bufLen))
        ]));
      }
    });

    onStateChanged((oldValue, newValue) {
      _log.fine(
          '$hashCode player$nativeHandle onPlaybackStateChanged: $oldValue => $newValue');
      if (newValue == mdk.PlaybackState.stopped) {
        // FIXME: keep_open no stopped
        streamCtl.add(VideoEvent(eventType: VideoEventType.completed));
        return;
      }
      streamCtl.add(VideoEvent(
          eventType: VideoEventType.isPlayingStateUpdate,
          isPlaying: newValue == mdk.PlaybackState.playing));
    });
  }
}

class MdkVideoPlayerPlatform extends VideoPlayerPlatform {
  static final _players = <int, MdkVideoPlayer>{};
  static Map<String, Object>? _globalOpts;
  static Map<String, String>? _playerOpts;
  static int? _maxWidth;
  static int? _maxHeight;
  static bool? _fitMaxSize;
  static bool? _tunnel;
  static String? _subtitleFontFile;
  static int _lowLatency = 0;
  static int _seekFlags = mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache;
  static List<String>? _decoders;
  static final _mdkLog = Logger('mdk');
  // _prevImpl: required if registerWith() can be invoked multiple times by user
  static VideoPlayerPlatform? _prevImpl;

/*
  Registers this class as the default instance of [VideoPlayerPlatform].

  [options] can be
  "video.decoders": a list of decoder names. supported decoders: https://github.com/wang-bin/mdk-sdk/wiki/Decoders
  "maxWidth", "maxHeight": texture max size. if not set, video frame size is used. a small value can reduce memory cost, but may result in lower image quality.
 */
  static void registerVideoPlayerPlatformsWith({dynamic options}) {
    _log.fine('registerVideoPlayerPlatformsWith: $options');
    if (options is Map<String, dynamic>) {
      final platforms = options['platforms'];
      if (platforms is List<String>) {
        if (!platforms.contains(Platform.operatingSystem)) {
          if (_prevImpl != null) {
            // null if it's the 1st time to call registerWith() including current platform
            VideoPlayerPlatform.instance = _prevImpl!;
          }
          return;
        }
      }

      if ((options['fastSeek'] ?? false) as bool) {
        _seekFlags |= mdk.SeekFlag.keyFrame;
      }
      _lowLatency = (options['lowLatency'] ?? 0) as int;
      _maxWidth = options["maxWidth"];
      _maxHeight = options["maxHeight"];
      _fitMaxSize = options["fitMaxSize"];
      _tunnel = options["tunnel"];
      _playerOpts = options['player'];
      _globalOpts = options['global'];
      _decoders = options['video.decoders'];
      _subtitleFontFile = options['subtitleFontFile'];
    }

    if (_decoders == null && !PlatformEx.isAndroidEmulator()) {
      // prefer hardware decoders
      const vd = {
        'windows': ['MFT:d3d=11', "D3D11", 'CUDA', 'FFmpeg'],
        'macos': ['VT', 'FFmpeg'],
        'ios': ['VT', 'FFmpeg'],
        'linux': ['VAAPI', 'CUDA', 'VDPAU', 'FFmpeg'],
        'android': ['AMediaCodec', 'FFmpeg'],
      };
      _decoders = vd[Platform.operatingSystem];
    }

    mdk.setLogHandler((level, msg) {
      if (msg.endsWith('\n')) {
        msg = msg.substring(0, msg.length - 1);
      }
      switch (level) {
        case mdk.LogLevel.error:
          _mdkLog.severe(msg);
        case mdk.LogLevel.warning:
          _mdkLog.warning(msg);
        case mdk.LogLevel.info:
          _mdkLog.info(msg);
        case mdk.LogLevel.debug:
          _mdkLog.fine(msg);
        case mdk.LogLevel.all:
          _mdkLog.finest(msg);
        default:
          return;
      }
    });
    // mdk.setGlobalOptions('plugins', 'mdk-braw');
    mdk.setGlobalOption('d3d11.sync.cpu', 1);
    mdk.setGlobalOption('subtitle.fonts.file',
        PlatformEx.assetUri(_subtitleFontFile ?? 'assets/subfont.ttf'));
    _globalOpts?.forEach((key, value) {
      mdk.setGlobalOption(key, value);
    });

    // if VideoPlayerPlatform.instance.runtimeType.toString() != '_PlaceholderImplementation' ?
    _prevImpl ??= VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = MdkVideoPlayerPlatform();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    _players.remove(textureId)?.dispose();
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    String? uri;
    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        uri =
            PlatformEx.assetUri(dataSource.asset!, package: dataSource.package);
        break;
      case DataSourceType.network:
        uri = dataSource.uri;
        break;
      case DataSourceType.file:
        uri = Uri.decodeComponent(dataSource.uri!);
        break;
      case DataSourceType.contentUri:
        uri = dataSource.uri;
        break;
    }
    final player = MdkVideoPlayer();
    _log.fine('$hashCode player${player.nativeHandle} create($uri)');

    //player.setProperty("keep_open", "1");
    player.setProperty('video.decoder', 'shader_resource=0');
    player.setProperty('avformat.strict', 'experimental');
    player.setProperty('avio.reconnect', '1');
    player.setProperty('avio.reconnect_delay_max', '7');
    player.setProperty('avio.protocol_whitelist',
        'file,rtmp,http,https,tls,rtp,tcp,udp,crypto,httpproxy,data,concatf,concat,subfile');
    player.setProperty('avformat.rtsp_transport', 'tcp');
    _playerOpts?.forEach((key, value) {
      player.setProperty(key, value);
    });

    if (_decoders != null) {
      player.videoDecoders = _decoders!;
    }
    if (_lowLatency > 0) {
// +nobuffer: the 1st key-frame packet is dropped. -nobuffer: high latency
      player.setProperty('avformat.fflags', '+nobuffer');
      player.setProperty('avformat.fpsprobesize', '0');
      player.setProperty('avformat.analyzeduration', '100000');
      if (_lowLatency > 1) {
        player.setBufferRange(min: 0, max: 1000, drop: true);
      } else {
        player.setBufferRange(min: 0);
      }
    }

    if (dataSource.httpHeaders.isNotEmpty) {
      String headers = '';
      dataSource.httpHeaders.forEach((key, value) {
        headers += '$key: $value\r\n';
      });
      player.setProperty('avio.headers', headers);
    }
    player.media = uri!;
    int ret = await player.prepare(); // required!
    if (ret < 0) {
      // no throw, handle error in controller.addListener
      _players[-hashCode] = player;
      player.streamCtl.addError(PlatformException(
        code: 'media open error',
        message: 'invalid or unsupported media',
      ));
      //player.dispose(); // dispose for throw
      return -hashCode;
    }
// FIXME: pending events will be processed after texture returned, but no events before prepared
// FIXME: set tunnel too late
    final tex = await player.updateTexture(
        width: _maxWidth,
        height: _maxHeight,
        tunnel: _tunnel,
        fit: _fitMaxSize);
    if (tex < 0) {
      _players[-hashCode] = player;
      player.streamCtl.addError(PlatformException(
        code: 'video size error',
        message: 'invalid or unsupported media with invalid video size',
      ));
      //player.dispose();
      return -hashCode;
    }
    _log.fine('$hashCode player${player.nativeHandle} textureId=$tex');
    _players[tex] = player;
    return tex;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final player = _players[textureId];
    if (player != null) {
      player.loop = looping ? -1 : 0;
    }
  }

  @override
  Future<void> play(int textureId) async {
    _players[textureId]?.state = mdk.PlaybackState.playing;
  }

  @override
  Future<void> pause(int textureId) async {
    _players[textureId]?.state = mdk.PlaybackState.paused;
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {
    _players[textureId]?.volume = volume;
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {
    _players[textureId]?.playbackRate = speed;
  }

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    final player = _players[textureId];
    if (player == null) {
      return;
    }
    if (player.isLive) {
      final bufMax = player.buffered();
      final pos = player.position;
      if (position.inMilliseconds <= pos ||
          position.inMilliseconds > pos + bufMax) {
        _log.fine(
            'seekTo: $position out of live stream buffered range [$pos, ${pos + bufMax}]');
        return;
      }
    }
    player.seek(
        position: position.inMilliseconds, flags: mdk.SeekFlag(_seekFlags));
  }

  @override
  Future<Duration> getPosition(int textureId) async {
    final player = _players[textureId];
    if (player == null) {
      return Duration.zero;
    }
    final pos = player.position;
    final bufLen = player.buffered();
    final ranges = player.bufferedTimeRanges();
    player.streamCtl.add(VideoEvent(
        eventType: VideoEventType.bufferingUpdate,
        buffered: ranges +
            [
              DurationRange(Duration(milliseconds: pos),
                  Duration(milliseconds: pos + bufLen))
            ]));
    return Duration(milliseconds: pos);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final player = _players[textureId];
    if (player != null) {
      return player.streamCtl.stream;
    }
    throw Exception('No Stream<VideoEvent> for textureId: $textureId.');
  }

  @override
  Widget buildView(int textureId) {
    return Texture(textureId: textureId);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

/////////// custom apis starts here
  @override
  MediaInfo? getMediaInfo(int textureId) {
    return _players[textureId]?.mediaInfo;
  }

  @override
  void setSubtitleTrack(int textureId, int trackNum) {
    _players[textureId]?.activeSubtitleTracks = [trackNum];
  }

  @override
  Future<Duration?> toNextFrame(int textureId, [int? step]) async {
    final duration = await _players[textureId]?.seek(
      position: step ?? 1,
      flags: const mdk.SeekFlag(mdk.SeekFlag.fromNow | mdk.SeekFlag.frame),
    );
    if (duration == null) {
      return null;
    }
    return Duration(milliseconds: duration);
  }

  @override
  Future<Duration?> toPrevFrame(int textureId, [int? step]) async {
    final duration = await _players[textureId]?.seek(
      position: step ?? -1,
      flags: const mdk.SeekFlag(mdk.SeekFlag.fromNow | mdk.SeekFlag.frame),
    );
    if (duration == null) {
      return null;
    }
    return Duration(milliseconds: duration);
  }

  @override
  void setAudioTrack(int textureId, int trackNum) {
    _players[textureId]?.activeAudioTracks = [trackNum];
  }
}