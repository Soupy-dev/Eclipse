import 'package:html/dom.dart';
import 'package:pseudom/src/selector/attribute_matcher.dart';
import 'package:pseudom/src/selector/attribute_selector.dart';
import 'package:pseudom/src/selector/pseudo_selector.dart';
import 'package:pseudom/src/selector/selector_combinator.dart';

class Selector {
  String? tagName;
  String? id;
  List<AttributeSelector> attributeSelectors = [];
  List<PseudoSelector> pseudoSelectors = [];
  SelectorCombinator combinator = SelectorCombinator.descendant;

  @override
  String toString() {
    return "com=$combinator,id=$id,tagName=$tagName,attributeSelectors=$attributeSelectors,pseudoSelectors=$pseudoSelectors";
  }

  Set<Element> select(Element node) {
    switch (combinator) {
      case SelectorCombinator.nextSibling:
        return _nextSibling(node);
      case SelectorCombinator.child:
        return _child(node);
      case SelectorCombinator.subsequentSibling:
        return _subsequentSibling(node);
      case SelectorCombinator.descendant:
        return _descendant(node);
    }
  }

  Set<Element> _child(Element node) {
    final filtered = <Element>{};
    for (final element in node.children) {
      if (matches(element)) {
        filtered.add(element);
      }
    }
    return filtered;
  }

  Set<Element> _descendant(Element node) {
    final filtered = <Element>{};
    for (final element in node.children) {
      if (matches(element)) {
        filtered.add(element);
      } else {
        filtered.addAll(_descendant(element));
      }
    }
    return filtered;
  }

  Set<Element> _nextSibling(Element node) {
    final next = node.nextElementSibling;
    if (next != null && matches(next)) {
      return {next};
    }
    return {};
  }

  Set<Element> _subsequentSibling(Element node) {
    final parent = node.parent;
    if (parent == null) {
      return {};
    }

    var children = parent.children;
    final next = node.nextElementSibling;
    if (next == null) {
      return {};
    }

    final index = children.indexOf(next);
    if (index == -1) {
      return {};
    }
    children = children.sublist(index);

    for (final element in children) {
      if (matches(element)) {
        return {element};
      }
    }

    return {};
  }

  bool matches(Element node) {
    if (id != null && node.id != id) {
      return false;
    }

    if (tagName != null && node.localName != tagName) {
      return false;
    }

    final attributes = node.attributes;
    for (final attributeSelector in attributeSelectors) {
      final value = attributes[attributeSelector.attribute];

      if (value == null) {
        return false;
      }
      if (attributeSelector.value == null) {
        continue;
      }

      switch (attributeSelector.attributeMatcher) {
        case AttributeMatcher.exact:
          if (value != attributeSelector.value) {
            return false;
          }
        case AttributeMatcher.includes:
          if (!value
              .contains(RegExp(r'\b' + attributeSelector.value! + r'\b'))) {
            return false;
          }
        case AttributeMatcher.dash:
          if (!value.contains(
              RegExp(r'\b' + attributeSelector.value! + r'(-.*?)?\b'))) {
            return false;
          }
        case AttributeMatcher.prefix:
          if (!value.startsWith(attributeSelector.value!)) {
            return false;
          }
        case AttributeMatcher.suffix:
          if (!value.endsWith(attributeSelector.value!)) {
            return false;
          }
        case AttributeMatcher.substring:
          if (!value.contains(attributeSelector.value!)) {
            return false;
          }
        default: // Do nothing
      }
    }

    for (var pseudoSelector in pseudoSelectors) {
      if (!pseudoSelector.matches(node)) {
        return false;
      }
    }

    return true;
  }
}
