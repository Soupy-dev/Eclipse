import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:d4rt/d4rt.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/dart/bridge/registrer.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/m_source.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/m_bridge.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/filter.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/source_preference.dart';
import 'package:eclipse_mangayomi_dart_runtime/host.dart';
import 'package:eclipse_mangayomi_dart_runtime/javascript_dom.dart';

@JS('Error')
extension type HostError._(JSObject _) implements JSObject {
  external factory HostError(JSString message);
}
JSPromise<JSString> javascriptPromise(Future<String> future) => JSPromise(((JSFunction resolve, JSFunction reject) {
  future.then((value) { resolve.callAsFunction(null, value.toJS); }, onError: (Object error, StackTrace stack) {
    reject.callAsFunction(null, HostError(error.toString().toJS));
  });
}).toJS);

@JS('__eclipseMangayomiDOM')
external set domExport(JSFunction value);
@JS('__eclipseMangayomiUtility')
external set utilityExport(JSFunction value);

@JS('__eclipseMangayomiDartRun')
external set runExport(JSFunction value);
@JS('__eclipseMangayomiExtract')
external set extractExport(JSFunction value);

Map<String, dynamic> preferenceDefaults(List<dynamic> rows) {
  final values = <String, dynamic>{};
  for (final value in rows) {
    if (value is! SourcePreference || value.key == null) continue;
    final key = value.key ?? '';
    final list = value.listPreference;
    if (list != null) {
      final options = list.entryValues ?? [];
      final index = list.valueIndex ?? 0;
      if (index >= 0 && index < options.length) values[key] = options[index];
    } else if (value.multiSelectListPreference != null) {
      values[key] = value.multiSelectListPreference?.values ?? [];
    } else if (value.editTextPreference != null) {
      values[key] = value.editTextPreference?.value ?? value.editTextPreference?.text ?? '';
    } else if (value.checkBoxPreference != null) {
      values[key] = value.checkBoxPreference?.value ?? false;
    } else if (value.switchPreferenceCompat != null) {
      values[key] = value.switchPreferenceCompat?.value ?? false;
    }
  }
  return values;
}

Future<String> execute(String raw) async {
  if (raw.length > 8 * 1024 * 1024) throw StateError('mangayomi-input-too-large');
  final request = (jsonDecode(raw) as Map).cast<String, dynamic>();
  if ((request['script'] as String).length > 4 * 1024 * 1024) throw StateError('mangayomi-script-too-large');
  final suppliedPreferences = Map<String, dynamic>.from(request['preferences'] as Map? ?? {});
  final values = Map<String, dynamic>.from(suppliedPreferences);
  return runZoned(() async {
    final metadata = request['source'] as Map;
    final source = MSource(
      id: int.tryParse(metadata['id'].toString()),
      name: metadata['name']?.toString(), baseUrl: metadata['baseUrl']?.toString(),
      lang: metadata['lang']?.toString(), apiUrl: metadata['apiUrl']?.toString(),
      dateFormat: metadata['dateFormat']?.toString(), dateFormatLocale: metadata['dateFormatLocale']?.toString(),
      additionalParams: metadata['additionalParams']?.toString(), notes: metadata['notes']?.toString(),
      hasCloudflare: metadata['hasCloudflare'] == true, isFullData: metadata['isFullData'] == true,
    );
    final requestedSteps = request['maxSteps'];
    final maxSteps = requestedSteps is int ? requestedSteps.clamp(1000, 2000000) : 2000000;
    final interpreter = D4rt(onPrint: (_) {});
    RegistrerBridge.registerBridge(interpreter);
    final instance = await interpreter.execute(source: request['script'] as String, positionalArgs: [source], timeout: const Duration(seconds: 55), maxSteps: maxSteps, allowFileSystemImports: false);
    if (instance is! InterpretedInstance) throw StateError('invalid-mangayomi-main');
    final hasPreferences = instance.klass.findInstanceMethod('getSourcePreferences') != null;
    final preferenceRows = hasPreferences ? (await interpreter.invoke('getSourcePreferences', []) as List? ?? []).toList() : <dynamic>[];
    values.addAll(preferenceDefaults(preferenceRows));
    values.addAll(suppliedPreferences);
    final args = (request['arguments'] as Map? ?? {}).cast<String, dynamic>();
    final operation = request['operation'];
    dynamic result;
    switch (operation) {
      case 'validate':
        final exports = instance is InterpretedInstance ? instance.klass.methods.keys.toList() : <String>[];
        result = {'exports': exports, 'preferences': preferenceRows, 'defaults': values};
      case 'preferences': result = preferenceRows;
      case 'filters': result = instance.klass.findInstanceMethod('getFilterList') != null ? await interpreter.invoke('getFilterList', []) ?? [] : [];
      case 'popular': result = await interpreter.invoke('getPopular', [args['page'] ?? 1]);
      case 'latest': result = await interpreter.invoke('getLatestUpdates', [args['page'] ?? 1]);
      case 'search':
        final supplied = args['filters'] as List?;
        final filters = supplied != null && supplied.isNotEmpty ? fromJsonFilterValuesToList(supplied) : instance.klass.findInstanceMethod('getFilterList') != null ? (await interpreter.invoke('getFilterList', []) as List? ?? []).toList() : <dynamic>[];
        result = await interpreter.invoke('search', [args['query'] ?? '', args['page'] ?? 1, FilterList(filters)]);
      case 'detail': result = await interpreter.invoke('getDetail', [args['url'] ?? args['key'] ?? '']);
      case 'videos': result = await interpreter.invoke('getVideoList', [args['url'] ?? args['key'] ?? '']);
      default: throw UnsupportedError('unsupported-mangayomi-operation');
    }
    String encoded;
    try { encoded = jsonEncode(result); }
    on JsonUnsupportedObjectError catch (error) { throw StateError('json-error: ${error.cause}'); }
    if (encoded.length > 4 * 1024 * 1024) throw StateError('mangayomi-result-too-large');
    return encoded;
  }, zoneValues: {preferencesZoneKey: values});
}

Future<String> extract(String name, String raw) async {
  final args = jsonDecode(raw) as List;
  dynamic at(int index, [dynamic fallback]) => index < args.length ? args[index] ?? fallback : fallback;
  final url = at(0, '').toString();
  dynamic result;
  switch (name) {
    case 'sibnetExtractor': result = await MBridge.sibnetExtractor(url, at(1, '').toString());
    case 'myTvExtractor': result = await MBridge.myTvExtractor(url);
    case 'okruExtractor': result = await MBridge.okruExtractor(url);
    case 'voeExtractor': result = await MBridge.voeExtractor(url, at(1)?.toString());
    case 'vidBomExtractor': result = await MBridge.vidBomExtractor(url);
    case 'streamlareExtractor': result = await MBridge.streamlareExtractor(url, at(1, '').toString(), at(2, '').toString());
    case 'sendVidExtractor': result = await MBridge.sendVidExtractor(url, at(1) == null ? null : jsonEncode(at(1)), at(2, '').toString());
    case 'yourUploadExtractor': result = await MBridge.yourUploadExtractor(url, at(1) == null ? null : jsonEncode(at(1)), at(2)?.toString(), at(3, '').toString());
    case 'gogoCdnExtractor': result = await MBridge.gogoCdnExtractor(url);
    case 'doodExtractor': result = await MBridge.doodExtractor(url, at(1)?.toString());
    case 'streamTapeExtractor': result = await MBridge.streamTapeExtractor(url, at(1)?.toString());
    case 'mp4UploadExtractor': result = await MBridge.mp4UploadExtractor(url, at(1) == null ? null : jsonEncode(at(1)), at(2, '').toString(), at(3, '').toString());
    case 'streamWishExtractor': result = await MBridge.streamWishExtractor(url, at(1, '').toString());
    case 'filemoonExtractor': result = await MBridge.filemoonExtractor(url, at(1, '').toString(), at(2, '').toString());
    case 'quarkVideosExtractor': result = await MBridge.quarkVideosExtractor(url, at(1, '').toString());
    case 'ucVideosExtractor': result = await MBridge.ucVideosExtractor(url, at(1, '').toString());
    case 'quarkFilesExtractor': result = await MBridge.quarkFilesExtractor((at(0) as List).cast<String>(), at(1, '').toString());
    case 'ucFilesExtractor': result = await MBridge.ucFilesExtractor((at(0) as List).cast<String>(), at(1, '').toString());
    default: throw UnsupportedError('unsupported-mangayomi-extractor');
  }
  String encoded;
    try { encoded = jsonEncode(result); }
    on JsonUnsupportedObjectError catch (error) { throw StateError('json-error: ${error.cause}'); }
    if (encoded.length > 4 * 1024 * 1024) throw StateError('mangayomi-result-too-large');
    return encoded;
}

void main() {
  domExport = ((JSString name, JSString args) => domOperation(name.toDart, args.toDart).toJS).toJS;
  utilityExport = ((JSString name, JSString args) => utilityOperation(name.toDart, args.toDart).toJS).toJS;
  runExport = ((JSString request) => javascriptPromise(execute(request.toDart))).toJS;
  extractExport = ((JSString name, JSString args) => javascriptPromise(extract(name.toDart, args.toDart))).toJS;
}
