import 'package:pseudom/src/selector/attribute_matcher.dart';

class AttributeSelector {
  final String attribute;
  final AttributeMatcher attributeMatcher;
  final String? value;

  AttributeSelector(this.attribute, this.attributeMatcher, this.value);

  @override
  String toString() {
    return "attribute=$attribute,attributeMatcher=$attributeMatcher,value=$value";
  }
}
