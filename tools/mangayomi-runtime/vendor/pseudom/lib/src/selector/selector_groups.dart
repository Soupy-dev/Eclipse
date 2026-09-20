import 'package:html/dom.dart';
import 'package:pseudom/src/selector/selector_group.dart';

class SelectorGroups {
  final List<SelectorGroup> groups;
  final String rawSelector;

  SelectorGroups(this.groups, this.rawSelector);

  Set<Element> select(Element node) {
    return _select(node, [...groups]);
  }

  Set<Element> _select(Element node, List<SelectorGroup> groups) {
    final nodes = <Element>{};

    for (final group in groups) {
      nodes.addAll(group.select(node));
    }

    return nodes;
  }

  Element? selectFirst(Element node) {
    for (final group in groups) {
      final element = group.selectFirst(node);
      if (element != null) {
        return element;
      }
    }

    return null;
  }
}
