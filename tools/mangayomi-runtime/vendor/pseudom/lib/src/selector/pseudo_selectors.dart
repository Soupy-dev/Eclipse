import 'package:html/dom.dart';
import 'package:pseudom/pseudom.dart';

bool has(Element element, String? args) {
  return parse(args!).selectFirst(element) != null;
}

bool empty(Element element, String? args) {
  return element.nodes.isEmpty;
}

bool first(Element element, String? args) {
  return element.previousElementSibling == null;
}

bool last(Element element, String? args) {
  return element.nextElementSibling == null;
}

bool contains(Element element, String? args) {
  final text = args ?? '';
  return element.nodes.whereType<Text>().any((e) => e.data.contains(text));
}

bool icontains(Element element, String? args) {
  final text = args?.toLowerCase() ?? '';
  return element.nodes
      .whereType<Text>()
      .any((e) => e.data.toLowerCase().contains(text));
}
