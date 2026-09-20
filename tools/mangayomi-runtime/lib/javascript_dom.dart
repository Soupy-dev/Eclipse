import 'dart:convert';
import 'eval/model/document.dart';
import 'eval/model/element.dart';
import 'eval/model/m_bridge.dart';

final _nodes = <int, dynamic>{};
var _nextNode = 0;
var _parsedBytes = 0;
var _documentCount = 0;

int storeNode(dynamic node) {
  if (_nodes.length >= 50000) throw StateError('mangayomi-dom-handle-limit');
  final id = ++_nextNode;
  _nodes[id] = node ?? MElement(null);
  return id;
}

String domOperation(String operation, String raw) {
  final args = jsonDecode(raw) as List;
  dynamic result;
  if (operation == 'parse') {
    final html = args[0] as String;
    if (++_documentCount > 128) throw StateError('mangayomi-dom-document-limit');
    _parsedBytes += utf8.encode(html).length;
    if (_parsedBytes > 16 * 1024 * 1024) throw StateError('mangayomi-dom-input-limit');
    result = storeNode(MBridge.parsHtml(html));
  } else {
    final node = _nodes[args[0] as int];
    if (node == null) throw StateError('invalid-mangayomi-dom-handle');
    final parameter = args.length > 1 ? args[1]?.toString() ?? '' : '';
    switch (operation) {
      case 'select': result = ((node.select(parameter) ?? []) as List).map(storeNode).toList();
      case 'selectFirst': result = storeNode(node.selectFirst(parameter));
      case 'attr': result = node.attr(parameter) ?? '';
      case 'hasAttr': result = node.hasAttr(parameter);
      case 'xpath': result = node.xpath(parameter) ?? [];
      case 'xpathFirst': result = node.xpathFirst(parameter) ?? '';
      case 'getElementsByClassName': result = ((node.getElementsByClassName(parameter) ?? []) as List).map(storeNode).toList();
      case 'getElementsByTagName': result = ((node.getElementsByTagName(parameter) ?? []) as List).map(storeNode).toList();
      case 'getElementById':
        result = storeNode(node is MDocument ? node.getElementById(parameter) : node.selectFirst('[id="${parameter.replaceAll('"', '\\"')}"]'));
      case 'children': result = ((node.children ?? []) as List).map(storeNode).toList();
      case 'body': result = storeNode(node is MDocument ? node.body : null);
      case 'documentElement': result = storeNode(node is MDocument ? node.documentElement : null);
      case 'head': result = storeNode(node is MDocument ? node.head : null);
      case 'parent': result = storeNode(node.parent);
      case 'nextElementSibling': result = storeNode(node is MElement ? node.nextElementSibling : null);
      case 'previousElementSibling': result = storeNode(node is MElement ? node.previousElementSibling : null);
      case 'text': result = node.rawText ?? '';
      case 'outerHtml': result = node.outerHtml ?? '';
      case 'innerHtml': result = node is MElement ? node.innerHtml ?? '' : node.outerHtml ?? '';
      case 'className': result = node is MElement ? node.className ?? '' : '';
      case 'localName': result = node is MElement ? node.localName ?? '' : '';
      case 'namespaceUri': result = node is MElement ? node.namespaceUri ?? '' : '';
      case 'getSrc': result = node is MElement ? node.getSrc ?? '' : '';
      case 'getImg': result = node is MElement ? node.getImg ?? '' : '';
      case 'getHref': result = node is MElement ? node.getHref ?? '' : '';
      case 'getDataSrc': result = node is MElement ? node.getDataSrc ?? '' : '';
      default: throw UnsupportedError('unsupported-mangayomi-dom-operation');
    }
  }
  return jsonEncode(result);
}

String utilityOperation(String operation, String raw) {
  final args = jsonDecode(raw) as List;
  String value(int index) => index < args.length ? args[index]?.toString() ?? '' : '';
  dynamic result;
  switch (operation) {
    case 'cryptoHandler': result = MBridge.cryptoHandler(value(0), value(1), value(2), args.length > 3 && args[3] == true);
    case 'encryptAESCryptoJS': result = MBridge.encryptAESCryptoJS(value(0), value(1));
    case 'decryptAESCryptoJS': result = MBridge.decryptAESCryptoJS(value(0), value(1));
    case 'decryptAESGCM': result = MBridge.decryptAESGCM(value(0), value(1), value(2), value(3));
    case 'deobfuscateJsPassword': result = MBridge.deobfuscateJsPassword(value(0));
    case 'unpackJs': result = MBridge.unpackJs(value(0)) ?? '';
    case 'unpackJsAndCombine': result = MBridge.unpackJsAndCombine(value(0)) ?? '';
    case 'parseDates': result = MBridge.parseDates(args[0], value(1), value(2));
    default: throw UnsupportedError('unsupported-mangayomi-utility');
  }
  return jsonEncode(result);
}
