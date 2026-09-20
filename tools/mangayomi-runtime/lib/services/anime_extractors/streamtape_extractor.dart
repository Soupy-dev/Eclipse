import 'package:http/http.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';
import 'package:html/parser.dart' show parse;
import 'package:eclipse_mangayomi_dart_runtime/services/http/m_client.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/extensions/string_extensions.dart';

class StreamTapeExtractor {
  Future<List<Video>> videosFromUrl(
    String url, {
    String quality = "StreamTape",
  }) async {
    final HostHttpClient client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );
    try {
      const baseUrl = "https://streamtape.com/e/";
      final newUrl = !url.startsWith(baseUrl)
          ? "$baseUrl${url.split("/")[4]}"
          : url;

      final response = await client.get(Uri.parse(newUrl));
      final document = parse(response.body);

      const targetLine = "document.getElementById('robotlink')";
      String script = "";
      final scri = document
          .querySelectorAll("script")
          .where((element) => element.innerHtml.contains(targetLine))
          .map((e) => e.innerHtml)
          .toList();
      if (scri.isEmpty) {
        return [];
      }
      script = scri.first.split("$targetLine.innerHTML = '").last;
      final videoUrl =
          "https:${script.substringBefore("'")}${script.substringAfter("+ ('xcd").substringBefore("'")}";

      return [Video(videoUrl, quality, videoUrl)];
    } catch (_) {
      return [];
    }
  }
}
