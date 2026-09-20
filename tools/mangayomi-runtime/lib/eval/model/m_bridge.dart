import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:html/dom.dart' hide Text;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:js_packer/js_packer.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/document.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/javascript/http.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/manga.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/dood_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/filemoon.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/gogocdn_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/mp4upload_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/mytv_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/okru_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/sendvid_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/sibnet_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/streamlare_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/streamtape_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/video.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/streamwish_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/vidbom_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/voe_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/your_upload_extractor.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/cryptoaes/crypto_aes.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/cryptoaes/deobfuscator.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/cryptoaes/js_unpacker.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/extensions/string_extensions.dart';
import 'package:eclipse_mangayomi_dart_runtime/utils/reg_exp_matcher.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:convert/convert.dart' show hex;
import 'package:eclipse_mangayomi_dart_runtime/services/anime_extractors/quarkuc_extractor.dart';

class WordSet {
  final List<String> words;

  WordSet(this.words);

  bool anyWordIn(String dateString) {
    return words.any(
      (word) => dateString.toLowerCase().contains(word.toLowerCase()),
    );
  }

  bool startsWith(String dateString) {
    return words.any(
      (word) => dateString.toLowerCase().startsWith(word.toLowerCase()),
    );
  }

  bool endsWith(String dateString) {
    return words.any(
      (word) => dateString.toLowerCase().endsWith(word.toLowerCase()),
    );
  }
}

class MBridge {
  static MDocument parsHtml(String html) {
    return MDocument(Document.html(html));
  }


  static List<String>? xpath(String html, String xpath) {
    List<String> attrs = [];
    try {
      var htmlXPath = HtmlXPath.html(html);
      var query = htmlXPath.query(xpath);
      if (query.nodes.length > 1) {
        for (var element in query.attrs) {
          attrs.add(element!.trim());
        }
      }
      else if (query.nodes.length == 1) {
        String attr = query.attr != null ? query.attr!.trim() : "";
        if (attr.isNotEmpty) {
          attrs = [attr];
        }
      }
      return attrs;
    } catch (_) {
      return [];
    }
  }

  static Status parseStatus(String status, List statusList) {
    for (var element in statusList) {
      Map statusMap = {};
      statusMap = element;
      for (var element in statusMap.entries) {
        if (element.key.toString().toLowerCase().contains(
          status.toLowerCase().trim(),
        )) {
          return switch (element.value as int) {
            0 => Status.ongoing,
            1 => Status.completed,
            2 => Status.onHiatus,
            3 => Status.canceled,
            4 => Status.publishingFinished,
            _ => Status.unknown,
          };
        }
      }
    }
    return Status.unknown;
  }


  static String? unpackJs(String code) {
    try {
      final jsPacker = JSPacker(code);
      return jsPacker.unpack() ?? "";
    } catch (_) {
      return "";
    }
  }

  static String? unpackJsAndCombine(String code) {
    try {
      return JsUnpacker.unpackAndCombine(code) ?? "";
    } catch (_) {
      return "";
    }
  }

  static String getMapValue(String source, String attr, bool encode) {
    try {
      var map = json.decode(source) as Map<String, dynamic>;
      if (!encode) {
        return map[attr] != null ? map[attr].toString() : "";
      }
      return map[attr] != null ? jsonEncode(map[attr]) : "";
    } catch (_) {
      return "";
    }
  }

  static List parseDates(
    List value,
    String dateFormat,
    String dateFormatLocale,
  ) {
    List<dynamic> val = [];
    for (var element in value) {
      element = element.toString().trim();
      if (element.isNotEmpty) {
        val.add(element);
      }
    }
    bool error = false;
    List<dynamic> valD = [];
    for (var date in val) {
      String dateStr = "";
      if (error) {
        dateStr = DateTime.now().millisecondsSinceEpoch.toString();
      } else {
        dateStr = parseChapterDate(date, dateFormat, dateFormatLocale, (val) {
          dateFormat = val.$1;
          dateFormatLocale = val.$2;
          error = val.$3;
        });
      }
      valD.add(dateStr);
    }
    return valD;
  }

  static List sortMapList(List list, String value, int type) {
    if (type == 0) {
      list.sort((a, b) => a[value].compareTo(b[value]));
    } else if (type == 1) {
      list.sort((a, b) => b[value].compareTo(a[value]));
    }

    return list;
  }

  static String regExp(
    String expression,
    String source,
    String replace,
    int type,
    int group,
  ) {
    if (type == 0) {
      return expression.replaceAll(RegExp(source), replace);
    }
    return regCustomMatcher(expression, source, group);
  }

  static Future<List<Video>> gogoCdnExtractor(String url) async {
    return await GogoCdnExtractor().videosFromUrl(url);
  }

  static Future<List<Video>> doodExtractor(String url, String? quality) async {
    return await DoodExtractor().videosFromUrl(url, quality: quality);
  }

  static Future<List<Video>> streamWishExtractor(
    String url,
    String prefix,
  ) async {
    return await StreamWishExtractor().videosFromUrl(url, prefix);
  }

  static Future<List<Video>> filemoonExtractor(
    String url,
    String prefix,
    String suffix,
  ) async {
    return await FilemoonExtractor().videosFromUrl(url, prefix, suffix);
  }

  static Map<String, String> decodeHeaders(String? headers) =>
      headers == null ? {} : (jsonDecode(headers) as Map).toMapStringString!;

  static Future<List<Video>> mp4UploadExtractor(
    String url,
    String? headers,
    String prefix,
    String suffix,
  ) async {
    return await Mp4uploadExtractor().videosFromUrl(
      url,
      decodeHeaders(headers),
      prefix: prefix,
      suffix: suffix,
    );
  }

  static final Map<CloudDriveType, QuarkUcExtractor> _extractorCache = {};
  static final Set<String> _initializedLocales = {};

  static QuarkUcExtractor _getExtractor(String cookie, CloudDriveType type) {
    if (!_extractorCache.containsKey(type)) {
      QuarkUcExtractor extractor = QuarkUcExtractor();
      extractor.initCloudDrive(cookie, type);
      _extractorCache[type] = extractor;
    }
    return _extractorCache[type]!;
  }

  static Future<List<Map<String, String>>> quarkFilesExtractor(
    List<String> url,
    String cookie,
  ) async {
    var quark = _getExtractor(cookie, CloudDriveType.quark);
    return await quark.videoFilesFromUrl(url);
  }

  static Future<List<Video>> quarkVideosExtractor(
    String url,
    String cookie,
  ) async {
    var quark = _getExtractor(cookie, CloudDriveType.quark);
    return await quark.videosFromUrl(url);
  }

  static Future<List<Map<String, String>>> ucFilesExtractor(
    List<String> url,
    String cookie,
  ) async {
    var uc = _getExtractor(cookie, CloudDriveType.uc);
    return await uc.videoFilesFromUrl(url);
  }

  static Future<List<Video>> ucVideosExtractor(
    String url,
    String cookie,
  ) async {
    var uc = _getExtractor(cookie, CloudDriveType.uc);
    return await uc.videosFromUrl(url);
  }

  static Future<List<Video>> streamTapeExtractor(
    String url,
    String? quality,
  ) async {
    return await StreamTapeExtractor().videosFromUrl(
      url,
      quality: quality ?? "StreamTape",
    );
  }

  static String substringAfter(String text, String pattern) {
    return text.substringAfter(pattern);
  }

  static String substringBefore(String text, String pattern) {
    return text.substringBefore(pattern);
  }

  static String substringBeforeLast(String text, String pattern) {
    return text.substringBeforeLast(pattern);
  }

  static String substringAfterLast(String text, String pattern) {
    return text.split(pattern).last;
  }

  static String parseChapterDate(
    String date,
    String dateFormat,
    String dateFormatLocale,
    Function((String, String, bool)) newLocale,
  ) {
    int parseRelativeDate(String date) {
      final number = int.tryParse(RegExp(r"(\d+)").firstMatch(date)!.group(0)!);
      if (number == null) return 0;
      final cal = DateTime.now();

      if (WordSet([
        "hari",
        "gün",
        "jour",
        "día",
        "dia",
        "day",
        "วัน",
        "ngày",
        "giorni",
        "أيام",
        "天",
      ]).anyWordIn(date)) {
        return cal.subtract(Duration(days: number)).millisecondsSinceEpoch;
      } else if (WordSet([
        "jam",
        "saat",
        "heure",
        "hora",
        "hour",
        "ชั่วโมง",
        "giờ",
        "ore",
        "ساعة",
        "小时",
      ]).anyWordIn(date)) {
        return cal.subtract(Duration(hours: number)).millisecondsSinceEpoch;
      } else if (WordSet([
        "menit",
        "dakika",
        "min",
        "minute",
        "minuto",
        "นาที",
        "دقائق",
      ]).anyWordIn(date)) {
        return cal.subtract(Duration(minutes: number)).millisecondsSinceEpoch;
      } else if (WordSet(["detik", "segundo", "second", "วินาที", "sec"])
          .anyWordIn(date)) {
        return cal.subtract(Duration(seconds: number)).millisecondsSinceEpoch;
      } else if (WordSet(["week", "semana"]).anyWordIn(date)) {
        return cal.subtract(Duration(days: number * 7)).millisecondsSinceEpoch;
      } else if (WordSet(["month", "mes"]).anyWordIn(date)) {
        return cal.subtract(Duration(days: number * 30)).millisecondsSinceEpoch;
      } else if (WordSet(["year", "año"]).anyWordIn(date)) {
        return cal
            .subtract(Duration(days: number * 365))
            .millisecondsSinceEpoch;
      } else {
        return 0;
      }
    }

    try {
      if (WordSet(["yesterday", "يوم واحد"]).startsWith(date)) {
        DateTime cal = DateTime.now().subtract(const Duration(days: 1));
        cal = DateTime(cal.year, cal.month, cal.day);
        return cal.millisecondsSinceEpoch.toString();
      } else if (WordSet(["today"]).startsWith(date)) {
        DateTime cal = DateTime.now();
        cal = DateTime(cal.year, cal.month, cal.day);
        return cal.millisecondsSinceEpoch.toString();
      } else if (WordSet(["يومين"]).startsWith(date)) {
        DateTime cal = DateTime.now().subtract(const Duration(days: 2));
        cal = DateTime(cal.year, cal.month, cal.day);
        return cal.millisecondsSinceEpoch.toString();
      } else if (WordSet(["ago", "atrás", "önce", "قبل"]).endsWith(date)) {
        return parseRelativeDate(date).toString();
      } else if (WordSet(["hace"]).startsWith(date)) {
        return parseRelativeDate(date).toString();
      } else if (date.contains(RegExp(r"\d(st|nd|rd|th)"))) {
        final cleanedDate = date
            .split(" ")
            .map(
              (it) => it.contains(RegExp(r"\d\D\D"))
                  ? it.replaceAll(RegExp(r"\D"), "")
                  : it,
            )
            .join(" ");
        return DateFormat(
          dateFormat,
          dateFormatLocale,
        ).parse(cleanedDate).millisecondsSinceEpoch.toString();
      } else {
        return DateFormat(
          dateFormat,
          dateFormatLocale,
        ).parse(date).millisecondsSinceEpoch.toString();
      }
    } catch (e) {
      final supportedLocales = DateFormat.allLocalesWithSymbols();

      for (var locale in supportedLocales) {
        for (var dateFormat in _dateFormats) {
          newLocale((dateFormat, locale, false));
          try {
            if (!_initializedLocales.contains(locale)) {
              initializeDateFormatting(locale);
              _initializedLocales.add(locale);
            }
            if (WordSet(["yesterday", "يوم واحد"]).startsWith(date)) {
              DateTime cal = DateTime.now().subtract(const Duration(days: 1));
              cal = DateTime(cal.year, cal.month, cal.day);
              return cal.millisecondsSinceEpoch.toString();
            } else if (WordSet(["today"]).startsWith(date)) {
              DateTime cal = DateTime.now();
              cal = DateTime(cal.year, cal.month, cal.day);
              return cal.millisecondsSinceEpoch.toString();
            } else if (WordSet(["يومين"]).startsWith(date)) {
              DateTime cal = DateTime.now().subtract(const Duration(days: 2));
              cal = DateTime(cal.year, cal.month, cal.day);
              return cal.millisecondsSinceEpoch.toString();
            } else if (WordSet(["ago", "atrás", "önce", "قبل"])
                .endsWith(date)) {
              return parseRelativeDate(date).toString();
            } else if (WordSet(["hace"]).startsWith(date)) {
              return parseRelativeDate(date).toString();
            } else if (date.contains(RegExp(r"\d(st|nd|rd|th)"))) {
              final cleanedDate = date
                  .split(" ")
                  .map(
                    (it) => it.contains(RegExp(r"\d\D\D"))
                        ? it.replaceAll(RegExp(r"\D"), "")
                        : it,
                  )
                  .join(" ");
              return DateFormat(
                dateFormat,
                locale,
              ).parse(cleanedDate).millisecondsSinceEpoch.toString();
            } else {
              return DateFormat(
                dateFormat,
                locale,
              ).parse(date).millisecondsSinceEpoch.toString();
            }
          } catch (_) {}
        }
      }
      newLocale((dateFormat, dateFormatLocale, true));
      return DateTime.now().millisecondsSinceEpoch.toString();
    }
  }

  static String deobfuscateJsPassword(String inputString) {
    return Deobfuscator.deobfuscateJsPassword(inputString);
  }

  static Future<List<Video>> sibnetExtractor(String url, String prefix) async {
    return await SibnetExtractor().videosFromUrl(url, prefix: prefix);
  }

  static Future<List<Video>> sendVidExtractor(
    String url,
    String? headers,
    String prefix,
  ) async {
    return await SendvidExtractor(decodeHeaders(headers))
        .videosFromUrl(url, prefix: prefix);
  }

  static Future<List<Video>> myTvExtractor(String url) async {
    return await MytvExtractor().videosFromUrl(url);
  }

  static Future<List<Video>> okruExtractor(String url) async {
    return await OkruExtractor().videosFromUrl(url);
  }

  static Future<List<Video>> yourUploadExtractor(
    String url,
    String? headers,
    String? name,
    String prefix,
  ) async {
    return await YourUploadExtractor().videosFromUrl(
      url,
      decodeHeaders(headers),
      prefix: prefix,
      name: name ?? "YourUpload",
    );
  }

  static Future<List<Video>> voeExtractor(String url, String? quality) async {
    return await VoeExtractor().videosFromUrl(url, quality);
  }

  static Future<List<Video>> vidBomExtractor(String url) async {
    return await VidBomExtractor().videosFromUrl(url);
  }

  static Future<List<Video>> streamlareExtractor(
    String url,
    String prefix,
    String suffix,
  ) async {
    return await StreamlareExtractor().videosFromUrl(
      url,
      prefix: prefix,
      suffix: suffix,
    );
  }

  static String encryptAESCryptoJS(String plainText, String passphrase) {
    return CryptoAES.encryptAESCryptoJS(plainText, passphrase);
  }

  static String decryptAESCryptoJS(String encrypted, String passphrase) {
    return CryptoAES.decryptAESCryptoJS(encrypted, passphrase);
  }

  static Video toVideo(
    String url,
    String quality,
    String originalUrl,
    String? headers,
    List<Track>? subtitles,
    List<Track>? audios,
  ) {
    return Video(
      url,
      quality,
      originalUrl,
      headers: decodeHeaders(headers),
      subtitles: subtitles ?? [],
      audios: audios ?? [],
    );
  }

  static String decryptAESGCM(
    String encrypted,
    String keyHex,
    String ivHex,
    String tagHex,
  ) {
    try {
      final key = encrypt.Key(Uint8List.fromList(hex.decode(keyHex)));
      final iv = encrypt.IV(Uint8List.fromList(hex.decode(ivHex)));
      final dataWithTag = Uint8List.fromList([
        ...base64.decode(encrypted),
        ...hex.decode(tagHex),
      ]);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );
      return encrypter.decrypt(encrypt.Encrypted(dataWithTag), iv: iv);
    } catch (_) {
      return encrypted;
    }
  }

  static String cryptoHandler(
    String text,
    String iv,
    String secretKeyString,
    bool encrypt,
  ) {
    try {
      if (encrypt) {
        final encryptt = _encrypt(secretKeyString, iv);
        final en = encryptt.$1.encrypt(text, iv: encryptt.$2);
        return en.base64;
      } else {
        final encryptt = _encrypt(secretKeyString, iv);
        final en = encryptt.$1.decrypt64(text, iv: encryptt.$2);
        return en;
      }
    } catch (_) {
      return text;
    }
  }
}

final List<String> _dateFormats = [
  'dd/MM/yyyy',
  'MM/dd/yyyy',
  'yyyy/MM/dd',
  'dd-MM-yyyy',
  'MM-dd-yyyy',
  'yyyy-MM-dd',
  'dd.MM.yyyy',
  'MM.dd.yyyy',
  'yyyy.MM.dd',
  'dd MMMM yyyy',
  'MMMM dd, yyyy',
  'yyyy MMMM dd',
  'dd MMM yyyy',
  'MMM dd yyyy',
  'yyyy MMM dd',
  'dd MMMM, yyyy',
  'yyyy, MMMM dd',
  'MMMM dd yyyy',
  'MMM dd, yyyy',
  'dd LLLL yyyy',
  'LLLL dd, yyyy',
  'yyyy LLLL dd',
  'LLLL dd yyyy',
  "MMMMM dd, yyyy",
  "MMM d, yyy",
  "MMM d, yyyy",
  "dd/mm/yyyy",
  "d MMMM yyyy",
  "dd 'de' MMMM 'de' yyyy",
  "d MMMM'،' yyyy",
  "yyyy'年'M'月'd",
  "d MMMM, yyyy",
  "dd 'de' MMMMM 'de' yyyy",
  "dd MMMMM, yyyy",
  "MMMM d, yyyy",
  "MMM dd,yyyy",
];

(encrypt.Encrypter, encrypt.IV) _encrypt(String keyy, String ivv) {
  final key = encrypt.Key.fromUtf8(keyy);
  final iv = encrypt.IV.fromUtf8(ivv);
  final encrypter = encrypt.Encrypter(
    encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
  );
  return (encrypter, iv);
}
