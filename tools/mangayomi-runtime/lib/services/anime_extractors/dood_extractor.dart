import 'dart:math';

import 'package:http/http.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/http/m_client.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/extensions/string_extensions.dart';

class DoodExtractor {
  Future<List<Video>> videosFromUrl(
    String url, {
    String? quality,
    bool redirect = true,
  }) async {
    final HostHttpClient client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );
    final newQuality = quality ?? ('Doodstream ${redirect ? ' mirror' : ''}');

    try {
      final response = await client.get(Uri.parse(url));
      final newUrl = redirect ? response.request!.url.toString() : url;

      final doodHost = RegExp('https://(.*?)/').firstMatch(newUrl)!.group(1)!;
      final content = response.body;
      if (!content.contains("'/pass_md5/")) return [];
      final md5 = content.substringAfter("'/pass_md5/").substringBefore("',");
      final token = md5.substring(md5.lastIndexOf('/') + 1);
      final randomString = getRandomString();
      final expiry = DateTime.now().millisecondsSinceEpoch;
      final videoUrlStart = await client.get(
        Uri.parse('https://$doodHost/pass_md5/$md5'),
        headers: {'referer': newUrl},
      );

      final videoUrl =
          '${videoUrlStart.body}$randomString?token=$token&expiry=$expiry';
      return [
        Video(
          newUrl,
          newQuality,
          videoUrl,
          headers: {'User-Agent': 'Mangayomi', 'Referer': 'https://$doodHost/'},
        ),
      ];
    } catch (_) {
      return [];
    }
  }

  String getRandomString({int length = 10}) {
    const allowedChars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (index) =>
          allowedChars.runes.elementAt(Random().nextInt(allowedChars.length)),
    ).join();
  }
}
