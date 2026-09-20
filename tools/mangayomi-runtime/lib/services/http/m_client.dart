import 'dart:convert';
import 'package:http/http.dart';
import '../../host.dart';
import '../../eval/model/m_source.dart';

class MClient {
  static final Map<String, String> _cookies = {};
  static Future<void> setCookie(String host, String userAgent, MSource? source, {String? cookie}) async {
    if (cookie != null) _cookies[host] = cookie;
  }
  static Map<String, String> getCookiesPref(String host) => {'cookie': _cookies[host] ?? ''};
  static HostHttpClient init({MSource? source, Map<String, dynamic>? reqcopyWith}) => HostHttpClient(reqcopyWith ?? {});
}
class HostHttpClient extends BaseClient {
  final Map<String, dynamic> options;
  HostHttpClient(this.options);
  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final raw = await hostAsync('http', {
      'url': request.url.toString(),
      'method': request.method,
      'headers': request.headers,
      'bodyBase64': base64Encode(bytes),
      'followRedirects': options['followRedirects'] ?? request.followRedirects,
      'maxRedirects': request.maxRedirects,
    });
    final response = (raw as Map).cast<String, dynamic>();
    final body = response['bodyBase64'] is String ? base64Decode(response['bodyBase64']) : utf8.encode(response['body']?.toString() ?? '');
    final responseHeaders = (response['headers'] as Map? ?? {}).map((key, value) => MapEntry(key.toString(), value.toString()));
    final deliveredRequest = Request(request.method, Uri.parse(response['url']?.toString() ?? request.url.toString()));
    deliveredRequest.headers.addAll((response['requestHeaders'] as Map? ?? request.headers).map((key, value) => MapEntry(key.toString(), value.toString())));
    return StreamedResponse(Stream.value(body), response['statusCode'] as int, headers: responseHeaders, request: deliveredRequest, isRedirect: response['isRedirect'] == true);
  }
}
