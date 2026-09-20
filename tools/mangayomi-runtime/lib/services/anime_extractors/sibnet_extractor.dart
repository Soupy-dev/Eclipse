import 'package:http/http.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/http/m_client.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/extensions/string_extensions.dart';

class SibnetExtractor {
  final HostHttpClient client = MClient.init(
    reqcopyWith: {'useDartHttpClient': true},
  );

  Future<List<Video>> videosFromUrl(String url, {String prefix = ""}) async {
    List<Video> videoList = [];
    try {
      final response = await client.get(Uri.parse(url));
      if (response.statusCode != 200) {
        return [];
      }

      String script = response.body;
      String slug = script
          .substringAfter("player.src")
          .substringAfter("src:")
          .substringAfter("\"")
          .substringBefore("\"");

      String videoUrl = slug.contains("http")
          ? slug
          : "https://${Uri.parse(url).host}$slug";

      Map<String, String> videoHeaders = {"Referer": url};

      videoList.add(
        Video(videoUrl, "$prefix - Sibnet", videoUrl, headers: videoHeaders),
      );

      return videoList;
    } catch (_) {
      return [];
    }
  }
}
