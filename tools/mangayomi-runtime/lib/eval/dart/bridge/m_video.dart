import 'package:d4rt/d4rt.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/dart/bridge/bridge_cast.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';

class MVideoBridge {
  final mVideoBridgedClass = BridgedClass(
    nativeType: Video,
    name: 'MVideo',
    constructors: {
      '': (visitor, positionalArgs, namedArgs) {
        return Video(
          positionalArgs.get<String?>(0) ?? '',
          positionalArgs.get<String?>(1) ?? '',
          positionalArgs.get<String?>(2) ?? '',
          headers: namedArgs.get<Map?>('headers')?.cast(),
          subtitles: asBridgedList<Track>(namedArgs['subtitles'], 'MVideo.subtitles'),
          audios: asBridgedList<Track>(namedArgs['audios'], 'MVideo.audios'),
        );
      },
    },
    getters: {
      'url': (visitor, target) => (target as Video).url,
      'quality': (visitor, target) => (target as Video).quality,
      'originalUrl': (visitor, target) => (target as Video).originalUrl,
      'headers': (visitor, target) => (target as Video).headers,
      'subtitles': (visitor, target) => (target as Video).subtitles,
      'audios': (visitor, target) => (target as Video).audios,
    },
    setters: {
      'url': (visitor, target, value) =>
          (target as Video).url = value as String,
      'quality': (visitor, target, value) =>
          (target as Video).quality = value as String,
      'originalUrl': (visitor, target, value) =>
          (target as Video).originalUrl = value as String,
      'headers': (visitor, target, value) => (target as Video).headers =
          asBridgedMap<String, String>(value, 'Video.headers'),
      'subtitles': (visitor, target, value) => (target as Video).subtitles =
          asBridgedList<Track>(value, 'Video.subtitles'),
      'audios': (visitor, target, value) => (target as Video).audios =
          asBridgedList<Track>(value, 'Video.audios'),
    },
  );
  void registerBridgedClasses(D4rt interpreter) {
    interpreter.registerBridgedClass(
      mVideoBridgedClass,
      'package:mangayomi/bridge_lib.dart',
    );
  }
}
