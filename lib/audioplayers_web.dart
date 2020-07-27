import 'dart:async';
import 'dart:html';
import 'dart:js';
import 'dart:js_util';

import 'package:audioplayers/audioplayers.dart';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class StereoPanner {
  static final audioCtx = new JsObject(context['AudioContext']);
}

class WrappedPlayer {
  final MethodChannel methodChannel;
  final String playerId;
  var panNode;
  var source;

  WrappedPlayer(this.methodChannel, this.playerId);

  double pausedAt;
  List<double> currentVolume = <double>[1.0];
  ReleaseMode currentReleaseMode = ReleaseMode.RELEASE;
  String currentUrl;
  bool isPlaying = false;

  AudioElement player;

  void setUrl(String url) {
    currentUrl = url;

    stop();
    recreateNode();
    if (isPlaying) {
      resume();
    }
  }

  void setVolume(List<double> volume) {
    currentVolume = volume;
    if (volume[0] >= 0) player?.volume = volume[0];
    if (volume.length == 3 && StereoPanner.audioCtx != null)
      panNode["pan"]["value"] = volume[1] * -1 + volume[2];
  }

  void recreateNode() {
    if (currentUrl == null) {
      return;
    }
    player = AudioElement(currentUrl);
    player.loop = shouldLoop();
    player.volume = currentVolume[0];
    player.crossOrigin = "anonymous";
    if (StereoPanner.audioCtx != null) {
      source = StereoPanner.audioCtx
          .callMethod("createMediaElementSource", [player]);
      panNode =
          StereoPanner.audioCtx.callMethod("createStereoPanner", [player]);
      source.callMethod("connect", [panNode]);
      panNode.callMethod("connect", [StereoPanner.audioCtx["destination"]]);
    }
    onCurrentPosition();
  }

  bool shouldLoop() => currentReleaseMode == ReleaseMode.LOOP;

  void setReleaseMode(ReleaseMode releaseMode) {
    currentReleaseMode = releaseMode;
    player?.loop = shouldLoop();
  }

  void release() {
    _cancel();
    player = null;
    source = null;
    panNode = null;
  }

  onCurrentPosition() {
    if (_onCurrentPosition != null) _onCurrentPosition.cancel();
    _onCurrentPosition = Timer.periodic(Duration(milliseconds: 100), (Timer) {
      if (player.ended) _onCurrentPosition.cancel();
      methodChannel.invokeMethod('audio.onCurrentPosition', {
        'playerId': playerId,
        'value': (player?.currentTime * 1000).round()
      });
    });
  }

  Timer _onCurrentPosition;

  void start(double position) {
    isPlaying = true;
    if (currentUrl == null) {
      return; // nothing to play yet
    }
    if (player == null) {
      recreateNode();
    }
    player.play();
    player.currentTime = position;
    onCurrentPosition();
  }

  void resume() {
    start(pausedAt ?? 0);
  }

  void pause() {
    pausedAt = player.currentTime;
    player?.pause();
    _onCurrentPosition?.cancel();
    //_cancel();
  }

  void stop() {
    pausedAt = 0;
    _cancel();
  }

  void _cancel() {
    isPlaying = false;
    _onCurrentPosition?.cancel();
    player?.pause();
    if (currentReleaseMode == ReleaseMode.RELEASE) {
      player = null;
    }
  }
}

class AudioplayersPlugin {
  // players by playerId
  Map<String, WrappedPlayer> players = {};
  final MethodChannel methodChannel;

  AudioplayersPlugin(this.methodChannel);

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'xyz.luan/audioplayers',
      const StandardMethodCodec(),
      registrar.messenger,
    );

    final AudioplayersPlugin instance = AudioplayersPlugin(channel);
    channel.setMethodCallHandler(instance.handleMethodCall);
  }

  WrappedPlayer getOrCreatePlayer(String playerId) {
    return players.putIfAbsent(
        playerId, () => WrappedPlayer(methodChannel, playerId));
  }

  Future<WrappedPlayer> setUrl(String playerId, String url) async {
    final WrappedPlayer player = getOrCreatePlayer(playerId);

    if (player.currentUrl == url) {
      return player;
    }

    player.setUrl(url);
    return player;
  }

  ReleaseMode parseReleaseMode(String value) {
    return ReleaseMode.values.firstWhere((e) => e.toString() == value);
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    final method = call.method;
    final playerId = call.arguments['playerId'];
    switch (method) {
      case 'setUrl':
        {
          final String url = call.arguments['url'];
          await setUrl(playerId, url);
          return 1;
        }
      case 'play':
        {
          final String url = call.arguments['url'];

          // TODO(luan) think about isLocal (is it needed or not)

          List<double> volume =
              (call.arguments['volume'] as List).cast<double>() ??
                  <double>[1.0];
          final double position = call.arguments['position'] ?? 0;
          // web does not care for the `stayAwake` argument

          final player = await setUrl(playerId, url);
          player.setVolume(volume);
          player.start(position);

          return 1;
        }
      case 'pause':
        {
          getOrCreatePlayer(playerId).pause();
          return 1;
        }
      case 'stop':
        {
          getOrCreatePlayer(playerId).stop();
          return 1;
        }
      case 'resume':
        {
          getOrCreatePlayer(playerId).resume();
          return 1;
        }
      case 'setVolume':
        {
          List<double> volume =
              (call.arguments['volume'] as List).cast<double>() ??
                  <double>[1.0];
          getOrCreatePlayer(playerId).setVolume(volume);
          return 1;
        }
      case 'setReleaseMode':
        {
          ReleaseMode releaseMode =
              parseReleaseMode(call.arguments['releaseMode']);
          getOrCreatePlayer(playerId).setReleaseMode(releaseMode);
          return 1;
        }
      case 'release':
        {
          getOrCreatePlayer(playerId).release();
          return 1;
        }
      case 'seek':
      case 'setPlaybackRate':
      default:
        throw PlatformException(
          code: 'Unimplemented',
          details:
              "The audioplayers plugin for web doesn't implement the method '$method'",
        );
    }
  }
}
