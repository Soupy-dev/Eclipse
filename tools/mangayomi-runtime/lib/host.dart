import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

@JS('__eclipseMangayomiDartHostAsync')
external JSPromise<JSString> _asyncHost(JSString method, JSString arguments);
@JS('__eclipseMangayomiDartHostSync')
external JSString _syncHost(JSString method, JSString arguments);

const preferencesZoneKey = #mangayomiPreferences;
Future<dynamic> hostAsync(String method, Object? arguments) async {
  final result = await _asyncHost(method.toJS, jsonEncode(arguments).toJS).toDart;
  return jsonDecode(result.toDart);
}
dynamic hostSync(String method, Object? arguments) => jsonDecode(_syncHost(method.toJS, jsonEncode(arguments).toJS).toDart);
dynamic getPreferenceValue(int sourceID, String key) {
  final preferences = Zone.current[preferencesZoneKey] as Map<String, dynamic>?;
  return preferences?[key];
}
String getSourcePreferenceStringValue(int sourceID, String key, String fallback) => getPreferenceValue(sourceID, key)?.toString() ?? fallback;
