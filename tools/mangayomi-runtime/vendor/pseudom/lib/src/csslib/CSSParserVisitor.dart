// Generated from csslib/CSSParser.g4 by ANTLR 4.13.1
// ignore_for_file: unused_import, unused_local_variable, prefer_single_quotes
import 'package:antlr4/antlr4.dart';

import 'CSSParser.dart';

/// This abstract class defines a complete generic visitor for a parse tree
/// produced by [CSSParser].
///
/// [T] is the eturn type of the visit operation. Use `void` for
/// operations with no return type.
abstract class CSSParserVisitor<T> extends ParseTreeVisitor<T> {
  /// Visit a parse tree produced by [CSSParser.stylesheet].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitStylesheet(StylesheetContext ctx);

  /// Visit a parse tree produced by the {@code goodCharset}
  /// labeled alternative in {@link CSSParser#charset}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGoodCharset(GoodCharsetContext ctx);

  /// Visit a parse tree produced by the {@code badCharset}
  /// labeled alternative in {@link CSSParser#charset}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadCharset(BadCharsetContext ctx);

  /// Visit a parse tree produced by the {@code goodImport}
  /// labeled alternative in {@link CSSParser#imports}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGoodImport(GoodImportContext ctx);

  /// Visit a parse tree produced by the {@code badImport}
  /// labeled alternative in {@link CSSParser#imports}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadImport(BadImportContext ctx);

  /// Visit a parse tree produced by the {@code goodNamespace}
  /// labeled alternative in {@link CSSParser#namespace_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGoodNamespace(GoodNamespaceContext ctx);

  /// Visit a parse tree produced by the {@code badNamespace}
  /// labeled alternative in {@link CSSParser#namespace_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadNamespace(BadNamespaceContext ctx);

  /// Visit a parse tree produced by [CSSParser.namespacePrefix].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitNamespacePrefix(NamespacePrefixContext ctx);

  /// Visit a parse tree produced by [CSSParser.media].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMedia(MediaContext ctx);

  /// Visit a parse tree produced by [CSSParser.mediaQueryList].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMediaQueryList(MediaQueryListContext ctx);

  /// Visit a parse tree produced by [CSSParser.mediaQuery].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMediaQuery(MediaQueryContext ctx);

  /// Visit a parse tree produced by [CSSParser.mediaType].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMediaType(MediaTypeContext ctx);

  /// Visit a parse tree produced by [CSSParser.mediaExpression].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMediaExpression(MediaExpressionContext ctx);

  /// Visit a parse tree produced by [CSSParser.mediaFeature].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitMediaFeature(MediaFeatureContext ctx);

  /// Visit a parse tree produced by [CSSParser.page].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitPage(PageContext ctx);

  /// Visit a parse tree produced by [CSSParser.pseudoPage].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitPseudoPage(PseudoPageContext ctx);

  /// Visit a parse tree produced by [CSSParser.selectorGroup].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSelectorGroup(SelectorGroupContext ctx);

  /// Visit a parse tree produced by [CSSParser.selector].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSelector(SelectorContext ctx);

  /// Visit a parse tree produced by [CSSParser.combinator].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCombinator(CombinatorContext ctx);

  /// Visit a parse tree produced by [CSSParser.simpleSelectorSequence].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSimpleSelectorSequence(SimpleSelectorSequenceContext ctx);

  /// Visit a parse tree produced by [CSSParser.typeSelector].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitTypeSelector(TypeSelectorContext ctx);

  /// Visit a parse tree produced by [CSSParser.typeNamespacePrefix].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitTypeNamespacePrefix(TypeNamespacePrefixContext ctx);

  /// Visit a parse tree produced by [CSSParser.elementName].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitElementName(ElementNameContext ctx);

  /// Visit a parse tree produced by [CSSParser.universal].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUniversal(UniversalContext ctx);

  /// Visit a parse tree produced by [CSSParser.className].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitClassName(ClassNameContext ctx);

  /// Visit a parse tree produced by [CSSParser.attrib].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitAttrib(AttribContext ctx);

  /// Visit a parse tree produced by [CSSParser.pseudo].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitPseudo(PseudoContext ctx);

  /// Visit a parse tree produced by [CSSParser.functionalPseudo].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFunctionalPseudo(FunctionalPseudoContext ctx);

  /// Visit a parse tree produced by [CSSParser.expression].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitExpression(ExpressionContext ctx);

  /// Visit a parse tree produced by [CSSParser.negation].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitNegation(NegationContext ctx);

  /// Visit a parse tree produced by [CSSParser.negationArg].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitNegationArg(NegationArgContext ctx);

  /// Visit a parse tree produced by the {@code goodOperator}
  /// labeled alternative in {@link CSSParser#operator_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGoodOperator(GoodOperatorContext ctx);

  /// Visit a parse tree produced by the {@code badOperator}
  /// labeled alternative in {@link CSSParser#operator_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadOperator(BadOperatorContext ctx);

  /// Visit a parse tree produced by the {@code goodProperty}
  /// labeled alternative in {@link CSSParser#property_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGoodProperty(GoodPropertyContext ctx);

  /// Visit a parse tree produced by the {@code badProperty}
  /// labeled alternative in {@link CSSParser#property_}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadProperty(BadPropertyContext ctx);

  /// Visit a parse tree produced by the {@code knownRuleset}
  /// labeled alternative in {@link CSSParser#ruleset}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKnownRuleset(KnownRulesetContext ctx);

  /// Visit a parse tree produced by the {@code unknownRuleset}
  /// labeled alternative in {@link CSSParser#ruleset}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownRuleset(UnknownRulesetContext ctx);

  /// Visit a parse tree produced by [CSSParser.declarationList].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitDeclarationList(DeclarationListContext ctx);

  /// Visit a parse tree produced by the {@code knownDeclaration}
  /// labeled alternative in {@link CSSParser#declaration}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKnownDeclaration(KnownDeclarationContext ctx);

  /// Visit a parse tree produced by the {@code unknownDeclaration}
  /// labeled alternative in {@link CSSParser#declaration}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownDeclaration(UnknownDeclarationContext ctx);

  /// Visit a parse tree produced by [CSSParser.prio].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitPrio(PrioContext ctx);

  /// Visit a parse tree produced by [CSSParser.value].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitValue(ValueContext ctx);

  /// Visit a parse tree produced by [CSSParser.expr].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitExpr(ExprContext ctx);

  /// Visit a parse tree produced by the {@code knownTerm}
  /// labeled alternative in {@link CSSParser#term}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKnownTerm(KnownTermContext ctx);

  /// Visit a parse tree produced by the {@code unknownTerm}
  /// labeled alternative in {@link CSSParser#term}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownTerm(UnknownTermContext ctx);

  /// Visit a parse tree produced by the {@code badTerm}
  /// labeled alternative in {@link CSSParser#term}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBadTerm(BadTermContext ctx);

  /// Visit a parse tree produced by [CSSParser.function_].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFunction_(Function_Context ctx);

  /// Visit a parse tree produced by [CSSParser.dxImageTransform].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitDxImageTransform(DxImageTransformContext ctx);

  /// Visit a parse tree produced by [CSSParser.hexcolor].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitHexcolor(HexcolorContext ctx);

  /// Visit a parse tree produced by [CSSParser.number].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitNumber(NumberContext ctx);

  /// Visit a parse tree produced by [CSSParser.percentage].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitPercentage(PercentageContext ctx);

  /// Visit a parse tree produced by [CSSParser.dimension].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitDimension(DimensionContext ctx);

  /// Visit a parse tree produced by [CSSParser.unknownDimension].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownDimension(UnknownDimensionContext ctx);

  /// Visit a parse tree produced by [CSSParser.any_].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitAny_(Any_Context ctx);

  /// Visit a parse tree produced by the {@code unknownAtRule}
  /// labeled alternative in {@link CSSParser#atRule}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownAtRule(UnknownAtRuleContext ctx);

  /// Visit a parse tree produced by [CSSParser.unused].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnused(UnusedContext ctx);

  /// Visit a parse tree produced by [CSSParser.block].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitBlock(BlockContext ctx);

  /// Visit a parse tree produced by [CSSParser.nestedStatement].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitNestedStatement(NestedStatementContext ctx);

  /// Visit a parse tree produced by [CSSParser.groupRuleBody].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGroupRuleBody(GroupRuleBodyContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsRule].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsRule(SupportsRuleContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsCondition].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsCondition(SupportsConditionContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsConditionInParens].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsConditionInParens(SupportsConditionInParensContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsNegation].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsNegation(SupportsNegationContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsConjunction].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsConjunction(SupportsConjunctionContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsDisjunction].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsDisjunction(SupportsDisjunctionContext ctx);

  /// Visit a parse tree produced by [CSSParser.supportsDeclarationCondition].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitSupportsDeclarationCondition(SupportsDeclarationConditionContext ctx);

  /// Visit a parse tree produced by [CSSParser.generalEnclosed].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitGeneralEnclosed(GeneralEnclosedContext ctx);

  /// Visit a parse tree produced by [CSSParser.url].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUrl(UrlContext ctx);

  /// Visit a parse tree produced by [CSSParser.var_].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitVar_(Var_Context ctx);

  /// Visit a parse tree produced by [CSSParser.calc].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCalc(CalcContext ctx);

  /// Visit a parse tree produced by [CSSParser.calcSum].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCalcSum(CalcSumContext ctx);

  /// Visit a parse tree produced by [CSSParser.calcProduct].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCalcProduct(CalcProductContext ctx);

  /// Visit a parse tree produced by [CSSParser.calcValue].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCalcValue(CalcValueContext ctx);

  /// Visit a parse tree produced by [CSSParser.fontFaceRule].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFontFaceRule(FontFaceRuleContext ctx);

  /// Visit a parse tree produced by the {@code knownFontFaceDeclaration}
  /// labeled alternative in {@link CSSParser#fontFaceDeclaration}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKnownFontFaceDeclaration(KnownFontFaceDeclarationContext ctx);

  /// Visit a parse tree produced by the {@code unknownFontFaceDeclaration}
  /// labeled alternative in {@link CSSParser#fontFaceDeclaration}.
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitUnknownFontFaceDeclaration(UnknownFontFaceDeclarationContext ctx);

  /// Visit a parse tree produced by [CSSParser.keyframesRule].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKeyframesRule(KeyframesRuleContext ctx);

  /// Visit a parse tree produced by [CSSParser.keyframeBlock].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKeyframeBlock(KeyframeBlockContext ctx);

  /// Visit a parse tree produced by [CSSParser.keyframeSelector].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitKeyframeSelector(KeyframeSelectorContext ctx);

  /// Visit a parse tree produced by [CSSParser.viewport].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitViewport(ViewportContext ctx);

  /// Visit a parse tree produced by [CSSParser.counterStyle].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitCounterStyle(CounterStyleContext ctx);

  /// Visit a parse tree produced by [CSSParser.fontFeatureValuesRule].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFontFeatureValuesRule(FontFeatureValuesRuleContext ctx);

  /// Visit a parse tree produced by [CSSParser.fontFamilyNameList].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFontFamilyNameList(FontFamilyNameListContext ctx);

  /// Visit a parse tree produced by [CSSParser.fontFamilyName].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFontFamilyName(FontFamilyNameContext ctx);

  /// Visit a parse tree produced by [CSSParser.featureValueBlock].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFeatureValueBlock(FeatureValueBlockContext ctx);

  /// Visit a parse tree produced by [CSSParser.featureType].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFeatureType(FeatureTypeContext ctx);

  /// Visit a parse tree produced by [CSSParser.featureValueDefinition].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitFeatureValueDefinition(FeatureValueDefinitionContext ctx);

  /// Visit a parse tree produced by [CSSParser.ident].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitIdent(IdentContext ctx);

  /// Visit a parse tree produced by [CSSParser.ws].
  /// [ctx] the parse tree.
  /// Return the visitor result.
  T? visitWs(WsContext ctx);
}