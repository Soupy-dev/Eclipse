import 'package:html/dom.dart';
import 'package:pseudom/src/selector/pseudo_selectors.dart';

typedef PseudoHandler = bool Function(Element element, String? args);

class PseudoSelector {
  static final Map<String, PseudoHandler> handlers = {
    'has': has,
    'empty': has,
    'first': first,
    'last': last,
    'contains': contains,
    'icontains': icontains,
  };

  late final PseudoHandler handler;
  final String type;
  final String? args;

  PseudoSelector(this.type, this.args) {
    final exists = handlers[type];
    if (exists == null) {
      throw Exception('Missing handler for pseudo: "$type"');
    }
    handler = exists;
  }

  @override
  String toString() {
    return "type=$type,args=$args";
  }

  bool matches(Element element) {
    return handler(element, args);
  }
}
