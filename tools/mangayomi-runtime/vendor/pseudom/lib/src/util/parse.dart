import 'package:antlr4/antlr4.dart';
import 'package:pseudom/src/csslib/CSSLexer.dart';
import 'package:pseudom/src/csslib/CSSParser.dart';
import 'package:pseudom/src/selector/css_selector_group_visitor.dart';
import 'package:pseudom/src/selector/selector_groups.dart';

SelectorGroups parse(String selector) {
  CSSLexer.checkVersion();
  CSSParser.checkVersion();
  final input = InputStream.fromString(selector);
  final tree = CSSParser(CommonTokenStream(CSSLexer(input))).selectorGroup();
  return SelectorGroups(CSSSelectorGroupVisitor().visit(tree), selector);
}
