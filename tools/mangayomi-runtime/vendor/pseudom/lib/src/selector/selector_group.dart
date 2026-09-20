import 'package:html/dom.dart';
import 'package:pseudom/pseudom.dart';

class SelectorGroup {
  final List<Selector> selectors;

  SelectorGroup(this.selectors);

  Set<Element> select(Element node) {
    return _select(node, [...selectors]);
  }

  Set<Element> _select(Element node, List<Selector> selectors) {
    final selector = selectors.removeAt(0);

    final nodes = selector.select(node);
    if (selectors.isEmpty) {
      return nodes;
    }

    final set = <Element>{};

    for (var node in nodes) {
      final subNodes = _select(node, [...selectors]);
      set.addAll(subNodes);
    }

    return set;
  }

  Element? selectFirst(Element node) {
    return select(node).firstOrNull;
  }
}
