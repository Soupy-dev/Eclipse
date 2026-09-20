import 'package:html/parser.dart' show parse;
import 'package:http/http.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/http/m_client.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/extensions/string_extensions.dart';

class MytvExtractor {
  final HostHttpClient client = MClient.init(
    reqcopyWith: {'useDartHttpClient': true},
  );

  Future<List<Video>> videosFromUrl(String url) async {
    try {
      final response = await client.get(Uri.parse(url));
      final document = parse(response.body);
      final videoList = <Video>[];

      document.querySelectorAll("script").forEach((script) {
        if (script.text.contains("CreatePlayer(\"v")) {
          final videosString = script.text;
          final videoUrl = videosString
              .substringAfter("\"v=")
              .substringBefore("\\u0026tp=video")
              .replaceAll("%26", "&")
              .replaceAll("%3a", ":")
              .replaceAll("%2f", "/")
              .replaceAll("%3f", "?")
              .replaceAll("%3d", "=");

          if (!videoUrl.contains("https:")) {
            videoList.add(Video(videoUrl, "Stream", videoUrl));
          } else {
            videoList.add(Video(videoUrl, "Mytv", videoUrl));
          }
        }
      });

      return videoList;
    } catch (_) {
      return [];
    }
  }
}
