import 'package:antlr4/antlr4.dart';
import 'package:pseudom/src/csslib/CSSParser.dart';
import 'package:pseudom/src/csslib/CSSParserBaseVisitor.dart';
import 'package:pseudom/src/selector/attribute_matcher.dart';
import 'package:pseudom/src/selector/attribute_selector.dart';
import 'package:pseudom/src/selector/pseudo_selector.dart';
import 'package:pseudom/src/selector/selector.dart';
import 'package:pseudom/src/selector/selector_combinator.dart';
import 'package:pseudom/src/util/trim.dart';

class CSSSelectorVisitor extends CSSParserBaseVisitor {
  final List<Selector> selectors = [];
  Selector selector = Selector();

  @override
  visitSimpleSelectorSequence(SimpleSelectorSequenceContext ctx) {
    final id = ctx.Hash(0);
    if (id != null) {
      selector.id = trimLeft(id.text!, '#');
    }
    final res = super.visitSimpleSelectorSequence(ctx);
    selectors.add(selector);
    return res;
  }

  @override
  visitCombinator(CombinatorContext ctx) {
    selector = Selector();

    if (ctx.Plus() != null) {
      selector.combinator = SelectorCombinator.nextSibling;
    } else if (ctx.Greater() != null) {
      selector.combinator = SelectorCombinator.child;
    } else if (ctx.Tilde() != null) {
      selector.combinator = SelectorCombinator.subsequentSibling;
    } else {
      selector.combinator = SelectorCombinator.descendant;
    }

    return super.visitCombinator(ctx);
  }

  @override
  visitTypeSelector(TypeSelectorContext ctx) {
    selector.tagName = ctx.text;
  }

  @override
  visitClassName(ClassNameContext ctx) {
    selector.attributeSelectors.add(AttributeSelector(
        "class", AttributeMatcher.includes, ctx.ident()!.text));
  }

  @override
  visitAttrib(AttribContext ctx) {
    final attr = ctx.ident(0)!.text;
    final value = ctx.ident(1)?.text ?? ctx.String_()?.text;
    AttributeMatcher am = AttributeMatcher.exists;
    if (value != null) {
      if (ctx.PrefixMatch() != null) {
        am = AttributeMatcher.prefix;
      } else if (ctx.SuffixMatch() != null) {
        am = AttributeMatcher.suffix;
      } else if (ctx.SubstringMatch() != null) {
        am = AttributeMatcher.substring;
      } else if (ctx.Includes() != null) {
        am = AttributeMatcher.includes;
      } else if (ctx.DashMatch() != null) {
        am = AttributeMatcher.dash;
      } else {
        am = AttributeMatcher.exact;
      }
    }
    selector.attributeSelectors
        .add(AttributeSelector(attr, am, trim(trim(value, '"'), "'")));
  }

  @override
  visitPseudo(PseudoContext ctx) {
    final fnPseudoCtx = ctx.functionalPseudo();
    if (fnPseudoCtx != null) {
      return super.visitPseudo(ctx);
    } else {
      selector.pseudoSelectors.add(PseudoSelector(ctx.ident()!.text, null));
    }
  }

  @override
  visitFunctionalPseudo(FunctionalPseudoContext ctx) {
    String type = ctx.Function_()!.text!;
    type = type.substring(0, type.length - 1);
    selector.pseudoSelectors.add(PseudoSelector(
      type,
      trim(trim((ctx.expression() ?? ctx.selector())?.text, '"'), "'"),
    ));
  }

  @override
  visit(ParseTree tree) {
    super.visit(tree);
    return selector;
  }
}
