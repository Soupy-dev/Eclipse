import 'package:pseudom/src/csslib/CSSParser.dart';
import 'package:pseudom/src/csslib/CSSParserBaseVisitor.dart';
import 'package:pseudom/src/selector/css_selector_visitor.dart';
import 'package:pseudom/src/selector/selector_group.dart';

class CSSSelectorGroupVisitor extends CSSParserBaseVisitor {
  List<SelectorGroup> selectorGroups = [];

  @override
  visitSelector(SelectorContext ctx) {
    final visitor = CSSSelectorVisitor();
    visitor.visitSelector(ctx);

    selectorGroups.add(SelectorGroup(visitor.selectors));

    return selectorGroups;
  }
}
