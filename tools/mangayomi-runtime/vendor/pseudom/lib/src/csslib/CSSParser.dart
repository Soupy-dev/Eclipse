// Generated from csslib/CSSParser.g4 by ANTLR 4.13.1
// ignore_for_file: unused_import, unused_local_variable, prefer_single_quotes
import 'package:antlr4/antlr4.dart';

import 'CSSParserVisitor.dart';
import 'CSSParserBaseVisitor.dart';
const int RULE_stylesheet = 0, RULE_charset = 1, RULE_imports = 2, RULE_namespace_ = 3, 
          RULE_namespacePrefix = 4, RULE_media = 5, RULE_mediaQueryList = 6, 
          RULE_mediaQuery = 7, RULE_mediaType = 8, RULE_mediaExpression = 9, 
          RULE_mediaFeature = 10, RULE_page = 11, RULE_pseudoPage = 12, 
          RULE_selectorGroup = 13, RULE_selector = 14, RULE_combinator = 15, 
          RULE_simpleSelectorSequence = 16, RULE_typeSelector = 17, RULE_typeNamespacePrefix = 18, 
          RULE_elementName = 19, RULE_universal = 20, RULE_className = 21, 
          RULE_attrib = 22, RULE_pseudo = 23, RULE_functionalPseudo = 24, 
          RULE_expression = 25, RULE_negation = 26, RULE_negationArg = 27, 
          RULE_operator_ = 28, RULE_property_ = 29, RULE_ruleset = 30, RULE_declarationList = 31, 
          RULE_declaration = 32, RULE_prio = 33, RULE_value = 34, RULE_expr = 35, 
          RULE_term = 36, RULE_function_ = 37, RULE_dxImageTransform = 38, 
          RULE_hexcolor = 39, RULE_number = 40, RULE_percentage = 41, RULE_dimension = 42, 
          RULE_unknownDimension = 43, RULE_any_ = 44, RULE_atRule = 45, 
          RULE_unused = 46, RULE_block = 47, RULE_nestedStatement = 48, 
          RULE_groupRuleBody = 49, RULE_supportsRule = 50, RULE_supportsCondition = 51, 
          RULE_supportsConditionInParens = 52, RULE_supportsNegation = 53, 
          RULE_supportsConjunction = 54, RULE_supportsDisjunction = 55, 
          RULE_supportsDeclarationCondition = 56, RULE_generalEnclosed = 57, 
          RULE_url = 58, RULE_var_ = 59, RULE_calc = 60, RULE_calcSum = 61, 
          RULE_calcProduct = 62, RULE_calcValue = 63, RULE_fontFaceRule = 64, 
          RULE_fontFaceDeclaration = 65, RULE_keyframesRule = 66, RULE_keyframeBlock = 67, 
          RULE_keyframeSelector = 68, RULE_viewport = 69, RULE_counterStyle = 70, 
          RULE_fontFeatureValuesRule = 71, RULE_fontFamilyNameList = 72, 
          RULE_fontFamilyName = 73, RULE_featureValueBlock = 74, RULE_featureType = 75, 
          RULE_featureValueDefinition = 76, RULE_ident = 77, RULE_ws = 78;
class CSSParser extends Parser {
  static final checkVersion = () => RuntimeMetaData.checkVersion('4.13.1', RuntimeMetaData.VERSION);
  static const int TOKEN_EOF = IntStream.EOF;

  static final List<DFA> _decisionToDFA = List.generate(
      _ATN.numberOfDecisions, (i) => DFA(_ATN.getDecisionState(i), i));
  static final PredictionContextCache _sharedContextCache = PredictionContextCache();
  static const int TOKEN_OpenBracket = 1, TOKEN_CloseBracket = 2, TOKEN_OpenParen = 3, 
                   TOKEN_CloseParen = 4, TOKEN_OpenBrace = 5, TOKEN_CloseBrace = 6, 
                   TOKEN_SemiColon = 7, TOKEN_Equal = 8, TOKEN_Colon = 9, 
                   TOKEN_Dot = 10, TOKEN_Multiply = 11, TOKEN_Divide = 12, 
                   TOKEN_Pipe = 13, TOKEN_Underscore = 14, TOKEN_Comment = 15, 
                   TOKEN_Url = 16, TOKEN_Space = 17, TOKEN_Cdo = 18, TOKEN_Cdc = 19, 
                   TOKEN_Includes = 20, TOKEN_DashMatch = 21, TOKEN_Hash = 22, 
                   TOKEN_Import = 23, TOKEN_Page = 24, TOKEN_Media = 25, 
                   TOKEN_Namespace = 26, TOKEN_Charset = 27, TOKEN_Important = 28, 
                   TOKEN_Percentage = 29, TOKEN_Url_ = 30, TOKEN_UnicodeRange = 31, 
                   TOKEN_MediaOnly = 32, TOKEN_Not = 33, TOKEN_And = 34, 
                   TOKEN_Dimension = 35, TOKEN_UnknownDimension = 36, TOKEN_Plus = 37, 
                   TOKEN_Minus = 38, TOKEN_Greater = 39, TOKEN_Comma = 40, 
                   TOKEN_Tilde = 41, TOKEN_PseudoNot = 42, TOKEN_Number = 43, 
                   TOKEN_String_ = 44, TOKEN_PrefixMatch = 45, TOKEN_SuffixMatch = 46, 
                   TOKEN_SubstringMatch = 47, TOKEN_FontFace = 48, TOKEN_Supports = 49, 
                   TOKEN_Or = 50, TOKEN_Keyframes = 51, TOKEN_From = 52, 
                   TOKEN_To = 53, TOKEN_Calc = 54, TOKEN_Viewport = 55, 
                   TOKEN_CounterStyle = 56, TOKEN_FontFeatureValues = 57, 
                   TOKEN_DxImageTransform = 58, TOKEN_AtKeyword = 59, TOKEN_Variable = 60, 
                   TOKEN_Var = 61, TOKEN_Ident = 62, TOKEN_Function_ = 63, 
                   TOKEN_UnexpectedCharacter = 64;

  @override
  final List<String> ruleNames = [
    'stylesheet', 'charset', 'imports', 'namespace_', 'namespacePrefix', 
    'media', 'mediaQueryList', 'mediaQuery', 'mediaType', 'mediaExpression', 
    'mediaFeature', 'page', 'pseudoPage', 'selectorGroup', 'selector', 'combinator', 
    'simpleSelectorSequence', 'typeSelector', 'typeNamespacePrefix', 'elementName', 
    'universal', 'className', 'attrib', 'pseudo', 'functionalPseudo', 'expression', 
    'negation', 'negationArg', 'operator_', 'property_', 'ruleset', 'declarationList', 
    'declaration', 'prio', 'value', 'expr', 'term', 'function_', 'dxImageTransform', 
    'hexcolor', 'number', 'percentage', 'dimension', 'unknownDimension', 
    'any_', 'atRule', 'unused', 'block', 'nestedStatement', 'groupRuleBody', 
    'supportsRule', 'supportsCondition', 'supportsConditionInParens', 'supportsNegation', 
    'supportsConjunction', 'supportsDisjunction', 'supportsDeclarationCondition', 
    'generalEnclosed', 'url', 'var_', 'calc', 'calcSum', 'calcProduct', 
    'calcValue', 'fontFaceRule', 'fontFaceDeclaration', 'keyframesRule', 
    'keyframeBlock', 'keyframeSelector', 'viewport', 'counterStyle', 'fontFeatureValuesRule', 
    'fontFamilyNameList', 'fontFamilyName', 'featureValueBlock', 'featureType', 
    'featureValueDefinition', 'ident', 'ws'
  ];

  static final List<String?> _LITERAL_NAMES = [
      null, "'['", "']'", "'('", "')'", "'{'", "'}'", "';'", "'='", "':'", 
      "'.'", "'*'", "'/'", "'|'", "'_'", null, null, null, "'<!--'", "'-->'", 
      "'~='", "'|='", null, null, null, null, null, "'@charset '", null, 
      null, "'url('", null, null, null, null, null, null, "'+'", "'-'", 
      "'>'", "','", "'~'", null, null, null, "'^='", "'\$='", "'*='", null, 
      null, null, null, null, null, "'calc('", null, null, null, null, null, 
      null, "'var('"
  ];
  static final List<String?> _SYMBOLIC_NAMES = [
      null, "OpenBracket", "CloseBracket", "OpenParen", "CloseParen", "OpenBrace", 
      "CloseBrace", "SemiColon", "Equal", "Colon", "Dot", "Multiply", "Divide", 
      "Pipe", "Underscore", "Comment", "Url", "Space", "Cdo", "Cdc", "Includes", 
      "DashMatch", "Hash", "Import", "Page", "Media", "Namespace", "Charset", 
      "Important", "Percentage", "Url_", "UnicodeRange", "MediaOnly", "Not", 
      "And", "Dimension", "UnknownDimension", "Plus", "Minus", "Greater", 
      "Comma", "Tilde", "PseudoNot", "Number", "String_", "PrefixMatch", 
      "SuffixMatch", "SubstringMatch", "FontFace", "Supports", "Or", "Keyframes", 
      "From", "To", "Calc", "Viewport", "CounterStyle", "FontFeatureValues", 
      "DxImageTransform", "AtKeyword", "Variable", "Var", "Ident", "Function_", 
      "UnexpectedCharacter"
  ];
  static final Vocabulary VOCABULARY = VocabularyImpl(_LITERAL_NAMES, _SYMBOLIC_NAMES);

  @override
  Vocabulary get vocabulary {
    return VOCABULARY;
  }

  @override
  String get grammarFileName => 'CSSParser.g4';

  @override
  List<int> get serializedATN => _serializedATN;

  @override
  ATN getATN() {
   return _ATN;
  }

  CSSParser(TokenStream input) : super(input) {
    interpreter = ParserATNSimulator(this, _ATN, _decisionToDFA, _sharedContextCache);
  }

  StylesheetContext stylesheet() {
    dynamic _localctx = StylesheetContext(context, state);
    enterRule(_localctx, 0, RULE_stylesheet);
    int _la;
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 158;
      ws();
      state = 168;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Charset) {
        state = 159;
        charset();
        state = 163;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 0, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 160;
            _la = tokenStream.LA(1)!;
            if (!((((_la) & ~0x3f) == 0 && const <int>[15, 17, 18, 19].contains(_la)))) {
            errorHandler.recoverInline(this);
            } else {
              if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
              errorHandler.reportMatch(this);
              consume();
            } 
          }
          state = 165;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 0, context);
        }
        state = 170;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 180;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Import) {
        state = 171;
        imports();
        state = 175;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 2, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 172;
            _la = tokenStream.LA(1)!;
            if (!((((_la) & ~0x3f) == 0 && const <int>[15, 17, 18, 19].contains(_la)))) {
            errorHandler.recoverInline(this);
            } else {
              if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
              errorHandler.reportMatch(this);
              consume();
            } 
          }
          state = 177;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 2, context);
        }
        state = 182;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 192;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Namespace) {
        state = 183;
        namespace_();
        state = 187;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 4, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 184;
            _la = tokenStream.LA(1)!;
            if (!((((_la) & ~0x3f) == 0 && const <int>[15, 17, 18, 19].contains(_la)))) {
            errorHandler.recoverInline(this);
            } else {
              if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
              errorHandler.reportMatch(this);
              consume();
            } 
          }
          state = 189;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 4, context);
        }
        state = 194;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 204;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 9, 10, 11, 13, 15, 16, 17, 20, 21, 22, 24, 25, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 48, 49, 50, 51, 52, 53, 55, 56, 57, 59, 62, 63].contains(_la))) {
        state = 195;
        nestedStatement();
        state = 199;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 6, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 196;
            _la = tokenStream.LA(1)!;
            if (!((((_la) & ~0x3f) == 0 && const <int>[15, 17, 18, 19].contains(_la)))) {
            errorHandler.recoverInline(this);
            } else {
              if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
              errorHandler.reportMatch(this);
              consume();
            } 
          }
          state = 201;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 6, context);
        }
        state = 206;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 207;
      match(TOKEN_EOF);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CharsetContext charset() {
    dynamic _localctx = CharsetContext(context, state);
    enterRule(_localctx, 2, RULE_charset);
    try {
      state = 221;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 8, context)) {
      case 1:
        _localctx = GoodCharsetContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 209;
        match(TOKEN_Charset);
        state = 210;
        ws();
        state = 211;
        match(TOKEN_String_);
        state = 212;
        ws();
        state = 213;
        match(TOKEN_SemiColon);
        state = 214;
        ws();
        break;
      case 2:
        _localctx = BadCharsetContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 216;
        match(TOKEN_Charset);
        state = 217;
        ws();
        state = 218;
        match(TOKEN_String_);
        state = 219;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ImportsContext imports() {
    dynamic _localctx = ImportsContext(context, state);
    enterRule(_localctx, 4, RULE_imports);
    try {
      state = 261;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 13, context)) {
      case 1:
        _localctx = GoodImportContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 223;
        match(TOKEN_Import);
        state = 224;
        ws();
        state = 227;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 225;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 226;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 229;
        ws();
        state = 230;
        mediaQueryList();
        state = 231;
        match(TOKEN_SemiColon);
        state = 232;
        ws();
        break;
      case 2:
        _localctx = GoodImportContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 234;
        match(TOKEN_Import);
        state = 235;
        ws();
        state = 238;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 236;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 237;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 240;
        ws();
        state = 241;
        match(TOKEN_SemiColon);
        state = 242;
        ws();
        break;
      case 3:
        _localctx = BadImportContext(_localctx);
        enterOuterAlt(_localctx, 3);
        state = 244;
        match(TOKEN_Import);
        state = 245;
        ws();
        state = 248;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 246;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 247;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 250;
        ws();
        state = 251;
        mediaQueryList();
        break;
      case 4:
        _localctx = BadImportContext(_localctx);
        enterOuterAlt(_localctx, 4);
        state = 253;
        match(TOKEN_Import);
        state = 254;
        ws();
        state = 257;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 255;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 256;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 259;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Namespace_Context namespace_() {
    dynamic _localctx = Namespace_Context(context, state);
    enterRule(_localctx, 6, RULE_namespace_);
    int _la;
    try {
      state = 291;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 18, context)) {
      case 1:
        _localctx = GoodNamespaceContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 263;
        match(TOKEN_Namespace);
        state = 264;
        ws();
        state = 268;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 50, 52, 53, 62].contains(_la))) {
          state = 265;
          namespacePrefix();
          state = 266;
          ws();
        }

        state = 272;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 270;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 271;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 274;
        ws();
        state = 275;
        match(TOKEN_SemiColon);
        state = 276;
        ws();
        break;
      case 2:
        _localctx = BadNamespaceContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 278;
        match(TOKEN_Namespace);
        state = 279;
        ws();
        state = 283;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 50, 52, 53, 62].contains(_la))) {
          state = 280;
          namespacePrefix();
          state = 281;
          ws();
        }

        state = 287;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_String_:
          state = 285;
          match(TOKEN_String_);
          break;
        case TOKEN_Url:
        case TOKEN_Url_:
          state = 286;
          url();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 289;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  NamespacePrefixContext namespacePrefix() {
    dynamic _localctx = NamespacePrefixContext(context, state);
    enterRule(_localctx, 8, RULE_namespacePrefix);
    try {
      enterOuterAlt(_localctx, 1);
      state = 293;
      ident();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaContext media() {
    dynamic _localctx = MediaContext(context, state);
    enterRule(_localctx, 10, RULE_media);
    try {
      enterOuterAlt(_localctx, 1);
      state = 295;
      match(TOKEN_Media);
      state = 296;
      ws();
      state = 297;
      mediaQueryList();
      state = 298;
      groupRuleBody();
      state = 299;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaQueryListContext mediaQueryList() {
    dynamic _localctx = MediaQueryListContext(context, state);
    enterRule(_localctx, 12, RULE_mediaQueryList);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 311;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 20, context)) {
      case 1:
        state = 301;
        mediaQuery();
        state = 308;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        while (_la == TOKEN_Comma) {
          state = 302;
          match(TOKEN_Comma);
          state = 303;
          ws();
          state = 304;
          mediaQuery();
          state = 310;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
        }
        break;
      }
      state = 313;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaQueryContext mediaQuery() {
    dynamic _localctx = MediaQueryContext(context, state);
    enterRule(_localctx, 14, RULE_mediaQuery);
    int _la;
    try {
      int _alt;
      state = 340;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_Comment:
      case TOKEN_Space:
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        enterOuterAlt(_localctx, 1);
        state = 316;
        errorHandler.sync(this);
        switch (interpreter!.adaptivePredict(tokenStream, 21, context)) {
        case 1:
          state = 315;
          _la = tokenStream.LA(1)!;
          if (!(_la == TOKEN_MediaOnly || _la == TOKEN_Not)) {
          errorHandler.recoverInline(this);
          } else {
            if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
            errorHandler.reportMatch(this);
            consume();
          }
          break;
        }
        state = 318;
        ws();
        state = 319;
        mediaType();
        state = 320;
        ws();
        state = 327;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 22, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 321;
            match(TOKEN_And);
            state = 322;
            ws();
            state = 323;
            mediaExpression(); 
          }
          state = 329;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 22, context);
        }
        break;
      case TOKEN_OpenParen:
        enterOuterAlt(_localctx, 2);
        state = 330;
        mediaExpression();
        state = 337;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 23, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 331;
            match(TOKEN_And);
            state = 332;
            ws();
            state = 333;
            mediaExpression(); 
          }
          state = 339;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 23, context);
        }
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaTypeContext mediaType() {
    dynamic _localctx = MediaTypeContext(context, state);
    enterRule(_localctx, 16, RULE_mediaType);
    try {
      enterOuterAlt(_localctx, 1);
      state = 342;
      ident();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaExpressionContext mediaExpression() {
    dynamic _localctx = MediaExpressionContext(context, state);
    enterRule(_localctx, 18, RULE_mediaExpression);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 344;
      match(TOKEN_OpenParen);
      state = 345;
      ws();
      state = 346;
      mediaFeature();
      state = 351;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Colon) {
        state = 347;
        match(TOKEN_Colon);
        state = 348;
        ws();
        state = 349;
        expr();
      }

      state = 353;
      match(TOKEN_CloseParen);
      state = 354;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  MediaFeatureContext mediaFeature() {
    dynamic _localctx = MediaFeatureContext(context, state);
    enterRule(_localctx, 20, RULE_mediaFeature);
    try {
      enterOuterAlt(_localctx, 1);
      state = 356;
      ident();
      state = 357;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  PageContext page() {
    dynamic _localctx = PageContext(context, state);
    enterRule(_localctx, 22, RULE_page);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 359;
      match(TOKEN_Page);
      state = 360;
      ws();
      state = 362;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Colon) {
        state = 361;
        pseudoPage();
      }

      state = 364;
      match(TOKEN_OpenBrace);
      state = 365;
      ws();
      state = 367;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
        state = 366;
        declaration();
      }

      state = 376;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_SemiColon) {
        state = 369;
        match(TOKEN_SemiColon);
        state = 370;
        ws();
        state = 372;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
          state = 371;
          declaration();
        }

        state = 378;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 379;
      match(TOKEN_CloseBrace);
      state = 380;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  PseudoPageContext pseudoPage() {
    dynamic _localctx = PseudoPageContext(context, state);
    enterRule(_localctx, 24, RULE_pseudoPage);
    try {
      enterOuterAlt(_localctx, 1);
      state = 382;
      match(TOKEN_Colon);
      state = 383;
      ident();
      state = 384;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SelectorGroupContext selectorGroup() {
    dynamic _localctx = SelectorGroupContext(context, state);
    enterRule(_localctx, 26, RULE_selectorGroup);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 386;
      selector();
      state = 393;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Comma) {
        state = 387;
        match(TOKEN_Comma);
        state = 388;
        ws();
        state = 389;
        selector();
        state = 395;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SelectorContext selector() {
    dynamic _localctx = SelectorContext(context, state);
    enterRule(_localctx, 28, RULE_selector);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 398;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 31, context)) {
      case 1:
        state = 396;
        combinator();
        break;
      case 2:
        state = 397;
        ws();
        break;
      }
      state = 400;
      simpleSelectorSequence();
      state = 401;
      ws();
      state = 408;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 9, 10, 11, 13, 15, 17, 22, 32, 33, 34, 37, 39, 41, 42, 50, 52, 53, 62].contains(_la))) {
        state = 402;
        combinator();
        state = 403;
        simpleSelectorSequence();
        state = 404;
        ws();
        state = 410;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CombinatorContext combinator() {
    dynamic _localctx = CombinatorContext(context, state);
    enterRule(_localctx, 30, RULE_combinator);
    try {
      state = 418;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_Plus:
        enterOuterAlt(_localctx, 1);
        state = 411;
        match(TOKEN_Plus);
        state = 412;
        ws();
        break;
      case TOKEN_Greater:
        enterOuterAlt(_localctx, 2);
        state = 413;
        match(TOKEN_Greater);
        state = 414;
        ws();
        break;
      case TOKEN_Tilde:
        enterOuterAlt(_localctx, 3);
        state = 415;
        match(TOKEN_Tilde);
        state = 416;
        ws();
        break;
      case TOKEN_OpenBracket:
      case TOKEN_Colon:
      case TOKEN_Dot:
      case TOKEN_Multiply:
      case TOKEN_Pipe:
      case TOKEN_Comment:
      case TOKEN_Space:
      case TOKEN_Hash:
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_PseudoNot:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        enterOuterAlt(_localctx, 4);
        state = 417;
        ws();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SimpleSelectorSequenceContext simpleSelectorSequence() {
    dynamic _localctx = SimpleSelectorSequenceContext(context, state);
    enterRule(_localctx, 32, RULE_simpleSelectorSequence);
    try {
      int _alt;
      state = 443;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_Multiply:
      case TOKEN_Pipe:
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        enterOuterAlt(_localctx, 1);
        state = 422;
        errorHandler.sync(this);
        switch (interpreter!.adaptivePredict(tokenStream, 34, context)) {
        case 1:
          state = 420;
          typeSelector();
          break;
        case 2:
          state = 421;
          universal();
          break;
        }
        state = 431;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 36, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 429;
            errorHandler.sync(this);
            switch (tokenStream.LA(1)!) {
            case TOKEN_Hash:
              state = 424;
              match(TOKEN_Hash);
              break;
            case TOKEN_Dot:
              state = 425;
              className();
              break;
            case TOKEN_OpenBracket:
              state = 426;
              attrib();
              break;
            case TOKEN_Colon:
              state = 427;
              pseudo();
              break;
            case TOKEN_PseudoNot:
              state = 428;
              negation();
              break;
            default:
              throw NoViableAltException(this);
            } 
          }
          state = 433;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 36, context);
        }
        break;
      case TOKEN_OpenBracket:
      case TOKEN_Colon:
      case TOKEN_Dot:
      case TOKEN_Hash:
      case TOKEN_PseudoNot:
        enterOuterAlt(_localctx, 2);
        state = 439; 
        errorHandler.sync(this);
        _alt = 1;
        do {
          switch (_alt) {
          case 1:
            state = 439;
            errorHandler.sync(this);
            switch (tokenStream.LA(1)!) {
            case TOKEN_Hash:
              state = 434;
              match(TOKEN_Hash);
              break;
            case TOKEN_Dot:
              state = 435;
              className();
              break;
            case TOKEN_OpenBracket:
              state = 436;
              attrib();
              break;
            case TOKEN_Colon:
              state = 437;
              pseudo();
              break;
            case TOKEN_PseudoNot:
              state = 438;
              negation();
              break;
            default:
              throw NoViableAltException(this);
            }
            break;
          default:
            throw NoViableAltException(this);
          }
          state = 441; 
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 38, context);
        } while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER);
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  TypeSelectorContext typeSelector() {
    dynamic _localctx = TypeSelectorContext(context, state);
    enterRule(_localctx, 34, RULE_typeSelector);
    try {
      enterOuterAlt(_localctx, 1);
      state = 446;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 40, context)) {
      case 1:
        state = 445;
        typeNamespacePrefix();
        break;
      }
      state = 448;
      elementName();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  TypeNamespacePrefixContext typeNamespacePrefix() {
    dynamic _localctx = TypeNamespacePrefixContext(context, state);
    enterRule(_localctx, 36, RULE_typeNamespacePrefix);
    try {
      enterOuterAlt(_localctx, 1);
      state = 452;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        state = 450;
        ident();
        break;
      case TOKEN_Multiply:
        state = 451;
        match(TOKEN_Multiply);
        break;
      case TOKEN_Pipe:
        break;
      default:
        break;
      }
      state = 454;
      match(TOKEN_Pipe);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ElementNameContext elementName() {
    dynamic _localctx = ElementNameContext(context, state);
    enterRule(_localctx, 38, RULE_elementName);
    try {
      enterOuterAlt(_localctx, 1);
      state = 456;
      ident();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  UniversalContext universal() {
    dynamic _localctx = UniversalContext(context, state);
    enterRule(_localctx, 40, RULE_universal);
    try {
      enterOuterAlt(_localctx, 1);
      state = 459;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 42, context)) {
      case 1:
        state = 458;
        typeNamespacePrefix();
        break;
      }
      state = 461;
      match(TOKEN_Multiply);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ClassNameContext className() {
    dynamic _localctx = ClassNameContext(context, state);
    enterRule(_localctx, 42, RULE_className);
    try {
      enterOuterAlt(_localctx, 1);
      state = 463;
      match(TOKEN_Dot);
      state = 464;
      ident();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  AttribContext attrib() {
    dynamic _localctx = AttribContext(context, state);
    enterRule(_localctx, 44, RULE_attrib);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 466;
      match(TOKEN_OpenBracket);
      state = 467;
      ws();
      state = 469;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 43, context)) {
      case 1:
        state = 468;
        typeNamespacePrefix();
        break;
      }
      state = 471;
      ident();
      state = 472;
      ws();
      state = 481;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[8, 20, 21, 45, 46, 47].contains(_la))) {
        state = 473;
        _la = tokenStream.LA(1)!;
        if (!((((_la) & ~0x3f) == 0 && const <int>[8, 20, 21, 45, 46, 47].contains(_la)))) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
        state = 474;
        ws();
        state = 477;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_MediaOnly:
        case TOKEN_Not:
        case TOKEN_And:
        case TOKEN_Or:
        case TOKEN_From:
        case TOKEN_To:
        case TOKEN_Ident:
          state = 475;
          ident();
          break;
        case TOKEN_String_:
          state = 476;
          match(TOKEN_String_);
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 479;
        ws();
      }

      state = 483;
      match(TOKEN_CloseBracket);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  PseudoContext pseudo() {
    dynamic _localctx = PseudoContext(context, state);
    enterRule(_localctx, 46, RULE_pseudo);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 485;
      match(TOKEN_Colon);
      state = 487;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Colon) {
        state = 486;
        match(TOKEN_Colon);
      }

      state = 491;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        state = 489;
        ident();
        break;
      case TOKEN_Function_:
        state = 490;
        functionalPseudo();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FunctionalPseudoContext functionalPseudo() {
    dynamic _localctx = FunctionalPseudoContext(context, state);
    enterRule(_localctx, 48, RULE_functionalPseudo);
    try {
      enterOuterAlt(_localctx, 1);
      state = 493;
      match(TOKEN_Function_);
      state = 494;
      ws();
      state = 497;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 48, context)) {
      case 1:
        state = 495;
        expression();
        break;
      case 2:
        state = 496;
        selector();
        break;
      }
      state = 499;
      match(TOKEN_CloseParen);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ExpressionContext expression() {
    dynamic _localctx = ExpressionContext(context, state);
    enterRule(_localctx, 50, RULE_expression);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 511; 
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      do {
        state = 508;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_Plus:
          state = 501;
          match(TOKEN_Plus);
          break;
        case TOKEN_Minus:
          state = 502;
          match(TOKEN_Minus);
          break;
        case TOKEN_Dimension:
          state = 503;
          match(TOKEN_Dimension);
          break;
        case TOKEN_UnknownDimension:
          state = 504;
          match(TOKEN_UnknownDimension);
          break;
        case TOKEN_Number:
          state = 505;
          match(TOKEN_Number);
          break;
        case TOKEN_String_:
          state = 506;
          match(TOKEN_String_);
          break;
        case TOKEN_MediaOnly:
        case TOKEN_Not:
        case TOKEN_And:
        case TOKEN_Or:
        case TOKEN_From:
        case TOKEN_To:
        case TOKEN_Ident:
          state = 507;
          ident();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 510;
        ws();
        state = 513; 
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      } while ((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 62].contains(_la)));
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  NegationContext negation() {
    dynamic _localctx = NegationContext(context, state);
    enterRule(_localctx, 52, RULE_negation);
    try {
      enterOuterAlt(_localctx, 1);
      state = 515;
      match(TOKEN_PseudoNot);
      state = 516;
      ws();
      state = 517;
      negationArg();
      state = 518;
      ws();
      state = 519;
      match(TOKEN_CloseParen);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  NegationArgContext negationArg() {
    dynamic _localctx = NegationArgContext(context, state);
    enterRule(_localctx, 54, RULE_negationArg);
    try {
      state = 527;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 51, context)) {
      case 1:
        enterOuterAlt(_localctx, 1);
        state = 521;
        typeSelector();
        break;
      case 2:
        enterOuterAlt(_localctx, 2);
        state = 522;
        universal();
        break;
      case 3:
        enterOuterAlt(_localctx, 3);
        state = 523;
        match(TOKEN_Hash);
        break;
      case 4:
        enterOuterAlt(_localctx, 4);
        state = 524;
        className();
        break;
      case 5:
        enterOuterAlt(_localctx, 5);
        state = 525;
        attrib();
        break;
      case 6:
        enterOuterAlt(_localctx, 6);
        state = 526;
        pseudo();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Operator_Context operator_() {
    dynamic _localctx = Operator_Context(context, state);
    enterRule(_localctx, 56, RULE_operator_);
    try {
      state = 537;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_Divide:
        _localctx = GoodOperatorContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 529;
        match(TOKEN_Divide);
        state = 530;
        ws();
        break;
      case TOKEN_Comma:
        _localctx = GoodOperatorContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 531;
        match(TOKEN_Comma);
        state = 532;
        ws();
        break;
      case TOKEN_Space:
        _localctx = GoodOperatorContext(_localctx);
        enterOuterAlt(_localctx, 3);
        state = 533;
        match(TOKEN_Space);
        state = 534;
        ws();
        break;
      case TOKEN_Equal:
        _localctx = BadOperatorContext(_localctx);
        enterOuterAlt(_localctx, 4);
        state = 535;
        match(TOKEN_Equal);
        state = 536;
        ws();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Property_Context property_() {
    dynamic _localctx = Property_Context(context, state);
    enterRule(_localctx, 58, RULE_property_);
    try {
      state = 548;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        _localctx = GoodPropertyContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 539;
        ident();
        state = 540;
        ws();
        break;
      case TOKEN_Variable:
        _localctx = GoodPropertyContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 542;
        match(TOKEN_Variable);
        state = 543;
        ws();
        break;
      case TOKEN_Multiply:
        _localctx = BadPropertyContext(_localctx);
        enterOuterAlt(_localctx, 3);
        state = 544;
        match(TOKEN_Multiply);
        state = 545;
        ident();
        break;
      case TOKEN_Underscore:
        _localctx = BadPropertyContext(_localctx);
        enterOuterAlt(_localctx, 4);
        state = 546;
        match(TOKEN_Underscore);
        state = 547;
        ident();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  RulesetContext ruleset() {
    dynamic _localctx = RulesetContext(context, state);
    enterRule(_localctx, 60, RULE_ruleset);
    int _la;
    try {
      state = 573;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 57, context)) {
      case 1:
        _localctx = KnownRulesetContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 550;
        selectorGroup();
        state = 551;
        match(TOKEN_OpenBrace);
        state = 552;
        ws();
        state = 554;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[7, 11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
          state = 553;
          declarationList();
        }

        state = 556;
        match(TOKEN_CloseBrace);
        state = 557;
        ws();
        break;
      case 2:
        _localctx = UnknownRulesetContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 562;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 9, 16, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 62, 63].contains(_la))) {
          state = 559;
          any_();
          state = 564;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
        }
        state = 565;
        match(TOKEN_OpenBrace);
        state = 566;
        ws();
        state = 568;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[7, 11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
          state = 567;
          declarationList();
        }

        state = 570;
        match(TOKEN_CloseBrace);
        state = 571;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  DeclarationListContext declarationList() {
    dynamic _localctx = DeclarationListContext(context, state);
    enterRule(_localctx, 62, RULE_declarationList);
    int _la;
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 579;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_SemiColon) {
        state = 575;
        match(TOKEN_SemiColon);
        state = 576;
        ws();
        state = 581;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 582;
      declaration();
      state = 583;
      ws();
      state = 591;
      errorHandler.sync(this);
      _alt = interpreter!.adaptivePredict(tokenStream, 60, context);
      while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
        if (_alt == 1) {
          state = 584;
          match(TOKEN_SemiColon);
          state = 585;
          ws();
          state = 587;
          errorHandler.sync(this);
          switch (interpreter!.adaptivePredict(tokenStream, 59, context)) {
          case 1:
            state = 586;
            declaration();
            break;
          } 
        }
        state = 593;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 60, context);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  DeclarationContext declaration() {
    dynamic _localctx = DeclarationContext(context, state);
    enterRule(_localctx, 64, RULE_declaration);
    int _la;
    try {
      state = 606;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 62, context)) {
      case 1:
        _localctx = KnownDeclarationContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 594;
        property_();
        state = 595;
        match(TOKEN_Colon);
        state = 596;
        ws();
        state = 597;
        expr();
        state = 599;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if (_la == TOKEN_Important) {
          state = 598;
          prio();
        }

        break;
      case 2:
        _localctx = UnknownDeclarationContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 601;
        property_();
        state = 602;
        match(TOKEN_Colon);
        state = 603;
        ws();
        state = 604;
        value();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  PrioContext prio() {
    dynamic _localctx = PrioContext(context, state);
    enterRule(_localctx, 66, RULE_prio);
    try {
      enterOuterAlt(_localctx, 1);
      state = 608;
      match(TOKEN_Important);
      state = 609;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ValueContext value() {
    dynamic _localctx = ValueContext(context, state);
    enterRule(_localctx, 68, RULE_value);
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 615; 
      errorHandler.sync(this);
      _alt = 1;
      do {
        switch (_alt) {
        case 1:
          state = 615;
          errorHandler.sync(this);
          switch (tokenStream.LA(1)!) {
          case TOKEN_OpenBracket:
          case TOKEN_OpenParen:
          case TOKEN_Colon:
          case TOKEN_Url:
          case TOKEN_Includes:
          case TOKEN_DashMatch:
          case TOKEN_Hash:
          case TOKEN_Percentage:
          case TOKEN_Url_:
          case TOKEN_UnicodeRange:
          case TOKEN_MediaOnly:
          case TOKEN_Not:
          case TOKEN_And:
          case TOKEN_Dimension:
          case TOKEN_UnknownDimension:
          case TOKEN_Plus:
          case TOKEN_Minus:
          case TOKEN_Number:
          case TOKEN_String_:
          case TOKEN_Or:
          case TOKEN_From:
          case TOKEN_To:
          case TOKEN_Ident:
          case TOKEN_Function_:
            state = 611;
            any_();
            break;
          case TOKEN_OpenBrace:
            state = 612;
            block();
            break;
          case TOKEN_AtKeyword:
            state = 613;
            match(TOKEN_AtKeyword);
            state = 614;
            ws();
            break;
          default:
            throw NoViableAltException(this);
          }
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 617; 
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 64, context);
      } while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ExprContext expr() {
    dynamic _localctx = ExprContext(context, state);
    enterRule(_localctx, 70, RULE_expr);
    int _la;
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 619;
      term();
      state = 626;
      errorHandler.sync(this);
      _alt = interpreter!.adaptivePredict(tokenStream, 66, context);
      while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
        if (_alt == 1) {
          state = 621;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
          if ((((_la) & ~0x3f) == 0 && const <int>[8, 12, 17, 40].contains(_la))) {
            state = 620;
            operator_();
          }

          state = 623;
          term(); 
        }
        state = 628;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 66, context);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  TermContext term() {
    dynamic _localctx = TermContext(context, state);
    enterRule(_localctx, 72, RULE_term);
    try {
      state = 656;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 67, context)) {
      case 1:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 629;
        number();
        state = 630;
        ws();
        break;
      case 2:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 632;
        percentage();
        state = 633;
        ws();
        break;
      case 3:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 3);
        state = 635;
        dimension();
        state = 636;
        ws();
        break;
      case 4:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 4);
        state = 638;
        match(TOKEN_String_);
        state = 639;
        ws();
        break;
      case 5:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 5);
        state = 640;
        match(TOKEN_UnicodeRange);
        state = 641;
        ws();
        break;
      case 6:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 6);
        state = 642;
        ident();
        state = 643;
        ws();
        break;
      case 7:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 7);
        state = 645;
        var_();
        break;
      case 8:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 8);
        state = 646;
        url();
        state = 647;
        ws();
        break;
      case 9:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 9);
        state = 649;
        hexcolor();
        break;
      case 10:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 10);
        state = 650;
        calc();
        break;
      case 11:
        _localctx = KnownTermContext(_localctx);
        enterOuterAlt(_localctx, 11);
        state = 651;
        function_();
        break;
      case 12:
        _localctx = UnknownTermContext(_localctx);
        enterOuterAlt(_localctx, 12);
        state = 652;
        unknownDimension();
        state = 653;
        ws();
        break;
      case 13:
        _localctx = BadTermContext(_localctx);
        enterOuterAlt(_localctx, 13);
        state = 655;
        dxImageTransform();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Function_Context function_() {
    dynamic _localctx = Function_Context(context, state);
    enterRule(_localctx, 74, RULE_function_);
    try {
      enterOuterAlt(_localctx, 1);
      state = 658;
      match(TOKEN_Function_);
      state = 659;
      ws();
      state = 660;
      expr();
      state = 661;
      match(TOKEN_CloseParen);
      state = 662;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  DxImageTransformContext dxImageTransform() {
    dynamic _localctx = DxImageTransformContext(context, state);
    enterRule(_localctx, 76, RULE_dxImageTransform);
    try {
      enterOuterAlt(_localctx, 1);
      state = 664;
      match(TOKEN_DxImageTransform);
      state = 665;
      ws();
      state = 666;
      expr();
      state = 667;
      match(TOKEN_CloseParen);
      state = 668;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  HexcolorContext hexcolor() {
    dynamic _localctx = HexcolorContext(context, state);
    enterRule(_localctx, 78, RULE_hexcolor);
    try {
      enterOuterAlt(_localctx, 1);
      state = 670;
      match(TOKEN_Hash);
      state = 671;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  NumberContext number() {
    dynamic _localctx = NumberContext(context, state);
    enterRule(_localctx, 80, RULE_number);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 674;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Plus || _la == TOKEN_Minus) {
        state = 673;
        _la = tokenStream.LA(1)!;
        if (!(_la == TOKEN_Plus || _la == TOKEN_Minus)) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
      }

      state = 676;
      match(TOKEN_Number);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  PercentageContext percentage() {
    dynamic _localctx = PercentageContext(context, state);
    enterRule(_localctx, 82, RULE_percentage);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 679;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Plus || _la == TOKEN_Minus) {
        state = 678;
        _la = tokenStream.LA(1)!;
        if (!(_la == TOKEN_Plus || _la == TOKEN_Minus)) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
      }

      state = 681;
      match(TOKEN_Percentage);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  DimensionContext dimension() {
    dynamic _localctx = DimensionContext(context, state);
    enterRule(_localctx, 84, RULE_dimension);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 684;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Plus || _la == TOKEN_Minus) {
        state = 683;
        _la = tokenStream.LA(1)!;
        if (!(_la == TOKEN_Plus || _la == TOKEN_Minus)) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
      }

      state = 686;
      match(TOKEN_Dimension);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  UnknownDimensionContext unknownDimension() {
    dynamic _localctx = UnknownDimensionContext(context, state);
    enterRule(_localctx, 86, RULE_unknownDimension);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 689;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if (_la == TOKEN_Plus || _la == TOKEN_Minus) {
        state = 688;
        _la = tokenStream.LA(1)!;
        if (!(_la == TOKEN_Plus || _la == TOKEN_Minus)) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
      }

      state = 691;
      match(TOKEN_UnknownDimension);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Any_Context any_() {
    dynamic _localctx = Any_Context(context, state);
    enterRule(_localctx, 88, RULE_any_);
    int _la;
    try {
      state = 759;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 78, context)) {
      case 1:
        enterOuterAlt(_localctx, 1);
        state = 693;
        ident();
        state = 694;
        ws();
        break;
      case 2:
        enterOuterAlt(_localctx, 2);
        state = 696;
        number();
        state = 697;
        ws();
        break;
      case 3:
        enterOuterAlt(_localctx, 3);
        state = 699;
        percentage();
        state = 700;
        ws();
        break;
      case 4:
        enterOuterAlt(_localctx, 4);
        state = 702;
        dimension();
        state = 703;
        ws();
        break;
      case 5:
        enterOuterAlt(_localctx, 5);
        state = 705;
        unknownDimension();
        state = 706;
        ws();
        break;
      case 6:
        enterOuterAlt(_localctx, 6);
        state = 708;
        match(TOKEN_String_);
        state = 709;
        ws();
        break;
      case 7:
        enterOuterAlt(_localctx, 7);
        state = 710;
        url();
        state = 711;
        ws();
        break;
      case 8:
        enterOuterAlt(_localctx, 8);
        state = 713;
        match(TOKEN_Hash);
        state = 714;
        ws();
        break;
      case 9:
        enterOuterAlt(_localctx, 9);
        state = 715;
        match(TOKEN_UnicodeRange);
        state = 716;
        ws();
        break;
      case 10:
        enterOuterAlt(_localctx, 10);
        state = 717;
        match(TOKEN_Includes);
        state = 718;
        ws();
        break;
      case 11:
        enterOuterAlt(_localctx, 11);
        state = 719;
        match(TOKEN_DashMatch);
        state = 720;
        ws();
        break;
      case 12:
        enterOuterAlt(_localctx, 12);
        state = 721;
        match(TOKEN_Colon);
        state = 722;
        ws();
        break;
      case 13:
        enterOuterAlt(_localctx, 13);
        state = 723;
        match(TOKEN_Function_);
        state = 724;
        ws();
        state = 729;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 7, 9, 16, 18, 19, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 59, 62, 63].contains(_la))) {
          state = 727;
          errorHandler.sync(this);
          switch (tokenStream.LA(1)!) {
          case TOKEN_OpenBracket:
          case TOKEN_OpenParen:
          case TOKEN_Colon:
          case TOKEN_Url:
          case TOKEN_Includes:
          case TOKEN_DashMatch:
          case TOKEN_Hash:
          case TOKEN_Percentage:
          case TOKEN_Url_:
          case TOKEN_UnicodeRange:
          case TOKEN_MediaOnly:
          case TOKEN_Not:
          case TOKEN_And:
          case TOKEN_Dimension:
          case TOKEN_UnknownDimension:
          case TOKEN_Plus:
          case TOKEN_Minus:
          case TOKEN_Number:
          case TOKEN_String_:
          case TOKEN_Or:
          case TOKEN_From:
          case TOKEN_To:
          case TOKEN_Ident:
          case TOKEN_Function_:
            state = 725;
            any_();
            break;
          case TOKEN_OpenBrace:
          case TOKEN_SemiColon:
          case TOKEN_Cdo:
          case TOKEN_Cdc:
          case TOKEN_AtKeyword:
            state = 726;
            unused();
            break;
          default:
            throw NoViableAltException(this);
          }
          state = 731;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
        }
        state = 732;
        match(TOKEN_CloseParen);
        state = 733;
        ws();
        break;
      case 14:
        enterOuterAlt(_localctx, 14);
        state = 735;
        match(TOKEN_OpenParen);
        state = 736;
        ws();
        state = 741;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 7, 9, 16, 18, 19, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 59, 62, 63].contains(_la))) {
          state = 739;
          errorHandler.sync(this);
          switch (tokenStream.LA(1)!) {
          case TOKEN_OpenBracket:
          case TOKEN_OpenParen:
          case TOKEN_Colon:
          case TOKEN_Url:
          case TOKEN_Includes:
          case TOKEN_DashMatch:
          case TOKEN_Hash:
          case TOKEN_Percentage:
          case TOKEN_Url_:
          case TOKEN_UnicodeRange:
          case TOKEN_MediaOnly:
          case TOKEN_Not:
          case TOKEN_And:
          case TOKEN_Dimension:
          case TOKEN_UnknownDimension:
          case TOKEN_Plus:
          case TOKEN_Minus:
          case TOKEN_Number:
          case TOKEN_String_:
          case TOKEN_Or:
          case TOKEN_From:
          case TOKEN_To:
          case TOKEN_Ident:
          case TOKEN_Function_:
            state = 737;
            any_();
            break;
          case TOKEN_OpenBrace:
          case TOKEN_SemiColon:
          case TOKEN_Cdo:
          case TOKEN_Cdc:
          case TOKEN_AtKeyword:
            state = 738;
            unused();
            break;
          default:
            throw NoViableAltException(this);
          }
          state = 743;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
        }
        state = 744;
        match(TOKEN_CloseParen);
        state = 745;
        ws();
        break;
      case 15:
        enterOuterAlt(_localctx, 15);
        state = 747;
        match(TOKEN_OpenBracket);
        state = 748;
        ws();
        state = 753;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 7, 9, 16, 18, 19, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 59, 62, 63].contains(_la))) {
          state = 751;
          errorHandler.sync(this);
          switch (tokenStream.LA(1)!) {
          case TOKEN_OpenBracket:
          case TOKEN_OpenParen:
          case TOKEN_Colon:
          case TOKEN_Url:
          case TOKEN_Includes:
          case TOKEN_DashMatch:
          case TOKEN_Hash:
          case TOKEN_Percentage:
          case TOKEN_Url_:
          case TOKEN_UnicodeRange:
          case TOKEN_MediaOnly:
          case TOKEN_Not:
          case TOKEN_And:
          case TOKEN_Dimension:
          case TOKEN_UnknownDimension:
          case TOKEN_Plus:
          case TOKEN_Minus:
          case TOKEN_Number:
          case TOKEN_String_:
          case TOKEN_Or:
          case TOKEN_From:
          case TOKEN_To:
          case TOKEN_Ident:
          case TOKEN_Function_:
            state = 749;
            any_();
            break;
          case TOKEN_OpenBrace:
          case TOKEN_SemiColon:
          case TOKEN_Cdo:
          case TOKEN_Cdc:
          case TOKEN_AtKeyword:
            state = 750;
            unused();
            break;
          default:
            throw NoViableAltException(this);
          }
          state = 755;
          errorHandler.sync(this);
          _la = tokenStream.LA(1)!;
        }
        state = 756;
        match(TOKEN_CloseBracket);
        state = 757;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  AtRuleContext atRule() {
    dynamic _localctx = AtRuleContext(context, state);
    enterRule(_localctx, 90, RULE_atRule);
    int _la;
    try {
      _localctx = UnknownAtRuleContext(_localctx);
      enterOuterAlt(_localctx, 1);
      state = 761;
      match(TOKEN_AtKeyword);
      state = 762;
      ws();
      state = 766;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 9, 16, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 62, 63].contains(_la))) {
        state = 763;
        any_();
        state = 768;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 772;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_OpenBrace:
        state = 769;
        block();
        break;
      case TOKEN_SemiColon:
        state = 770;
        match(TOKEN_SemiColon);
        state = 771;
        ws();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  UnusedContext unused() {
    dynamic _localctx = UnusedContext(context, state);
    enterRule(_localctx, 92, RULE_unused);
    try {
      state = 783;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_OpenBrace:
        enterOuterAlt(_localctx, 1);
        state = 774;
        block();
        break;
      case TOKEN_AtKeyword:
        enterOuterAlt(_localctx, 2);
        state = 775;
        match(TOKEN_AtKeyword);
        state = 776;
        ws();
        break;
      case TOKEN_SemiColon:
        enterOuterAlt(_localctx, 3);
        state = 777;
        match(TOKEN_SemiColon);
        state = 778;
        ws();
        break;
      case TOKEN_Cdo:
        enterOuterAlt(_localctx, 4);
        state = 779;
        match(TOKEN_Cdo);
        state = 780;
        ws();
        break;
      case TOKEN_Cdc:
        enterOuterAlt(_localctx, 5);
        state = 781;
        match(TOKEN_Cdc);
        state = 782;
        ws();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  BlockContext block() {
    dynamic _localctx = BlockContext(context, state);
    enterRule(_localctx, 94, RULE_block);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 785;
      match(TOKEN_OpenBrace);
      state = 786;
      ws();
      state = 797;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 7, 9, 10, 11, 13, 14, 15, 16, 17, 20, 21, 22, 24, 25, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 48, 49, 50, 51, 52, 53, 55, 56, 57, 59, 60, 62, 63].contains(_la))) {
        state = 795;
        errorHandler.sync(this);
        switch (interpreter!.adaptivePredict(tokenStream, 82, context)) {
        case 1:
          state = 787;
          declarationList();
          break;
        case 2:
          state = 788;
          nestedStatement();
          break;
        case 3:
          state = 789;
          any_();
          break;
        case 4:
          state = 790;
          block();
          break;
        case 5:
          state = 791;
          match(TOKEN_AtKeyword);
          state = 792;
          ws();
          break;
        case 6:
          state = 793;
          match(TOKEN_SemiColon);
          state = 794;
          ws();
          break;
        }
        state = 799;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 800;
      match(TOKEN_CloseBrace);
      state = 801;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  NestedStatementContext nestedStatement() {
    dynamic _localctx = NestedStatementContext(context, state);
    enterRule(_localctx, 96, RULE_nestedStatement);
    try {
      state = 813;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_OpenBracket:
      case TOKEN_OpenParen:
      case TOKEN_OpenBrace:
      case TOKEN_Colon:
      case TOKEN_Dot:
      case TOKEN_Multiply:
      case TOKEN_Pipe:
      case TOKEN_Comment:
      case TOKEN_Url:
      case TOKEN_Space:
      case TOKEN_Includes:
      case TOKEN_DashMatch:
      case TOKEN_Hash:
      case TOKEN_Percentage:
      case TOKEN_Url_:
      case TOKEN_UnicodeRange:
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Dimension:
      case TOKEN_UnknownDimension:
      case TOKEN_Plus:
      case TOKEN_Minus:
      case TOKEN_Greater:
      case TOKEN_Tilde:
      case TOKEN_PseudoNot:
      case TOKEN_Number:
      case TOKEN_String_:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
      case TOKEN_Function_:
        enterOuterAlt(_localctx, 1);
        state = 803;
        ruleset();
        break;
      case TOKEN_Media:
        enterOuterAlt(_localctx, 2);
        state = 804;
        media();
        break;
      case TOKEN_Page:
        enterOuterAlt(_localctx, 3);
        state = 805;
        page();
        break;
      case TOKEN_FontFace:
        enterOuterAlt(_localctx, 4);
        state = 806;
        fontFaceRule();
        break;
      case TOKEN_Keyframes:
        enterOuterAlt(_localctx, 5);
        state = 807;
        keyframesRule();
        break;
      case TOKEN_Supports:
        enterOuterAlt(_localctx, 6);
        state = 808;
        supportsRule();
        break;
      case TOKEN_Viewport:
        enterOuterAlt(_localctx, 7);
        state = 809;
        viewport();
        break;
      case TOKEN_CounterStyle:
        enterOuterAlt(_localctx, 8);
        state = 810;
        counterStyle();
        break;
      case TOKEN_FontFeatureValues:
        enterOuterAlt(_localctx, 9);
        state = 811;
        fontFeatureValuesRule();
        break;
      case TOKEN_AtKeyword:
        enterOuterAlt(_localctx, 10);
        state = 812;
        atRule();
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  GroupRuleBodyContext groupRuleBody() {
    dynamic _localctx = GroupRuleBodyContext(context, state);
    enterRule(_localctx, 98, RULE_groupRuleBody);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 815;
      match(TOKEN_OpenBrace);
      state = 816;
      ws();
      state = 820;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 9, 10, 11, 13, 15, 16, 17, 20, 21, 22, 24, 25, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 48, 49, 50, 51, 52, 53, 55, 56, 57, 59, 62, 63].contains(_la))) {
        state = 817;
        nestedStatement();
        state = 822;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 823;
      match(TOKEN_CloseBrace);
      state = 824;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsRuleContext supportsRule() {
    dynamic _localctx = SupportsRuleContext(context, state);
    enterRule(_localctx, 100, RULE_supportsRule);
    try {
      enterOuterAlt(_localctx, 1);
      state = 826;
      match(TOKEN_Supports);
      state = 827;
      ws();
      state = 828;
      supportsCondition();
      state = 829;
      ws();
      state = 830;
      groupRuleBody();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsConditionContext supportsCondition() {
    dynamic _localctx = SupportsConditionContext(context, state);
    enterRule(_localctx, 102, RULE_supportsCondition);
    try {
      state = 836;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 86, context)) {
      case 1:
        enterOuterAlt(_localctx, 1);
        state = 832;
        supportsNegation();
        break;
      case 2:
        enterOuterAlt(_localctx, 2);
        state = 833;
        supportsConjunction();
        break;
      case 3:
        enterOuterAlt(_localctx, 3);
        state = 834;
        supportsDisjunction();
        break;
      case 4:
        enterOuterAlt(_localctx, 4);
        state = 835;
        supportsConditionInParens();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsConditionInParensContext supportsConditionInParens() {
    dynamic _localctx = SupportsConditionInParensContext(context, state);
    enterRule(_localctx, 104, RULE_supportsConditionInParens);
    try {
      state = 846;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 87, context)) {
      case 1:
        enterOuterAlt(_localctx, 1);
        state = 838;
        match(TOKEN_OpenParen);
        state = 839;
        ws();
        state = 840;
        supportsCondition();
        state = 841;
        ws();
        state = 842;
        match(TOKEN_CloseParen);
        break;
      case 2:
        enterOuterAlt(_localctx, 2);
        state = 844;
        supportsDeclarationCondition();
        break;
      case 3:
        enterOuterAlt(_localctx, 3);
        state = 845;
        generalEnclosed();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsNegationContext supportsNegation() {
    dynamic _localctx = SupportsNegationContext(context, state);
    enterRule(_localctx, 106, RULE_supportsNegation);
    try {
      enterOuterAlt(_localctx, 1);
      state = 848;
      match(TOKEN_Not);
      state = 849;
      ws();
      state = 850;
      match(TOKEN_Space);
      state = 851;
      ws();
      state = 852;
      supportsConditionInParens();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsConjunctionContext supportsConjunction() {
    dynamic _localctx = SupportsConjunctionContext(context, state);
    enterRule(_localctx, 108, RULE_supportsConjunction);
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 854;
      supportsConditionInParens();
      state = 864; 
      errorHandler.sync(this);
      _alt = 1;
      do {
        switch (_alt) {
        case 1:
          state = 855;
          ws();
          state = 856;
          match(TOKEN_Space);
          state = 857;
          ws();
          state = 858;
          match(TOKEN_And);
          state = 859;
          ws();
          state = 860;
          match(TOKEN_Space);
          state = 861;
          ws();
          state = 862;
          supportsConditionInParens();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 866; 
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 88, context);
      } while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsDisjunctionContext supportsDisjunction() {
    dynamic _localctx = SupportsDisjunctionContext(context, state);
    enterRule(_localctx, 110, RULE_supportsDisjunction);
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 868;
      supportsConditionInParens();
      state = 878; 
      errorHandler.sync(this);
      _alt = 1;
      do {
        switch (_alt) {
        case 1:
          state = 869;
          ws();
          state = 870;
          match(TOKEN_Space);
          state = 871;
          ws();
          state = 872;
          match(TOKEN_Or);
          state = 873;
          ws();
          state = 874;
          match(TOKEN_Space);
          state = 875;
          ws();
          state = 876;
          supportsConditionInParens();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 880; 
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 89, context);
      } while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  SupportsDeclarationConditionContext supportsDeclarationCondition() {
    dynamic _localctx = SupportsDeclarationConditionContext(context, state);
    enterRule(_localctx, 112, RULE_supportsDeclarationCondition);
    try {
      enterOuterAlt(_localctx, 1);
      state = 882;
      match(TOKEN_OpenParen);
      state = 883;
      ws();
      state = 884;
      declaration();
      state = 885;
      match(TOKEN_CloseParen);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  GeneralEnclosedContext generalEnclosed() {
    dynamic _localctx = GeneralEnclosedContext(context, state);
    enterRule(_localctx, 114, RULE_generalEnclosed);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 887;
      _la = tokenStream.LA(1)!;
      if (!(_la == TOKEN_OpenParen || _la == TOKEN_Function_)) {
      errorHandler.recoverInline(this);
      } else {
        if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
        errorHandler.reportMatch(this);
        consume();
      }
      state = 892;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[1, 3, 5, 7, 9, 16, 18, 19, 20, 21, 22, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 44, 50, 52, 53, 59, 62, 63].contains(_la))) {
        state = 890;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_OpenBracket:
        case TOKEN_OpenParen:
        case TOKEN_Colon:
        case TOKEN_Url:
        case TOKEN_Includes:
        case TOKEN_DashMatch:
        case TOKEN_Hash:
        case TOKEN_Percentage:
        case TOKEN_Url_:
        case TOKEN_UnicodeRange:
        case TOKEN_MediaOnly:
        case TOKEN_Not:
        case TOKEN_And:
        case TOKEN_Dimension:
        case TOKEN_UnknownDimension:
        case TOKEN_Plus:
        case TOKEN_Minus:
        case TOKEN_Number:
        case TOKEN_String_:
        case TOKEN_Or:
        case TOKEN_From:
        case TOKEN_To:
        case TOKEN_Ident:
        case TOKEN_Function_:
          state = 888;
          any_();
          break;
        case TOKEN_OpenBrace:
        case TOKEN_SemiColon:
        case TOKEN_Cdo:
        case TOKEN_Cdc:
        case TOKEN_AtKeyword:
          state = 889;
          unused();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 894;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 895;
      match(TOKEN_CloseParen);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  UrlContext url() {
    dynamic _localctx = UrlContext(context, state);
    enterRule(_localctx, 116, RULE_url);
    try {
      state = 904;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_Url_:
        enterOuterAlt(_localctx, 1);
        state = 897;
        match(TOKEN_Url_);
        state = 898;
        ws();
        state = 899;
        match(TOKEN_String_);
        state = 900;
        ws();
        state = 901;
        match(TOKEN_CloseParen);
        break;
      case TOKEN_Url:
        enterOuterAlt(_localctx, 2);
        state = 903;
        match(TOKEN_Url);
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  Var_Context var_() {
    dynamic _localctx = Var_Context(context, state);
    enterRule(_localctx, 118, RULE_var_);
    try {
      enterOuterAlt(_localctx, 1);
      state = 906;
      match(TOKEN_Var);
      state = 907;
      ws();
      state = 908;
      match(TOKEN_Variable);
      state = 909;
      ws();
      state = 910;
      match(TOKEN_CloseParen);
      state = 911;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CalcContext calc() {
    dynamic _localctx = CalcContext(context, state);
    enterRule(_localctx, 120, RULE_calc);
    try {
      enterOuterAlt(_localctx, 1);
      state = 913;
      match(TOKEN_Calc);
      state = 914;
      ws();
      state = 915;
      calcSum();
      state = 916;
      match(TOKEN_CloseParen);
      state = 917;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CalcSumContext calcSum() {
    dynamic _localctx = CalcSumContext(context, state);
    enterRule(_localctx, 122, RULE_calcSum);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 919;
      calcProduct();
      state = 930;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Space) {
        state = 920;
        match(TOKEN_Space);
        state = 921;
        ws();
        state = 922;
        _la = tokenStream.LA(1)!;
        if (!(_la == TOKEN_Plus || _la == TOKEN_Minus)) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
        state = 923;
        ws();
        state = 924;
        match(TOKEN_Space);
        state = 925;
        ws();
        state = 926;
        calcProduct();
        state = 932;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CalcProductContext calcProduct() {
    dynamic _localctx = CalcProductContext(context, state);
    enterRule(_localctx, 124, RULE_calcProduct);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 933;
      calcValue();
      state = 945;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Multiply || _la == TOKEN_Divide) {
        state = 943;
        errorHandler.sync(this);
        switch (tokenStream.LA(1)!) {
        case TOKEN_Multiply:
          state = 934;
          match(TOKEN_Multiply);
          state = 935;
          ws();
          state = 936;
          calcValue();
          break;
        case TOKEN_Divide:
          state = 938;
          match(TOKEN_Divide);
          state = 939;
          ws();
          state = 940;
          number();
          state = 941;
          ws();
          break;
        default:
          throw NoViableAltException(this);
        }
        state = 947;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CalcValueContext calcValue() {
    dynamic _localctx = CalcValueContext(context, state);
    enterRule(_localctx, 126, RULE_calcValue);
    try {
      state = 966;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 96, context)) {
      case 1:
        enterOuterAlt(_localctx, 1);
        state = 948;
        number();
        state = 949;
        ws();
        break;
      case 2:
        enterOuterAlt(_localctx, 2);
        state = 951;
        dimension();
        state = 952;
        ws();
        break;
      case 3:
        enterOuterAlt(_localctx, 3);
        state = 954;
        unknownDimension();
        state = 955;
        ws();
        break;
      case 4:
        enterOuterAlt(_localctx, 4);
        state = 957;
        percentage();
        state = 958;
        ws();
        break;
      case 5:
        enterOuterAlt(_localctx, 5);
        state = 960;
        match(TOKEN_OpenParen);
        state = 961;
        ws();
        state = 962;
        calcSum();
        state = 963;
        match(TOKEN_CloseParen);
        state = 964;
        ws();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FontFaceRuleContext fontFaceRule() {
    dynamic _localctx = FontFaceRuleContext(context, state);
    enterRule(_localctx, 128, RULE_fontFaceRule);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 968;
      match(TOKEN_FontFace);
      state = 969;
      ws();
      state = 970;
      match(TOKEN_OpenBrace);
      state = 971;
      ws();
      state = 973;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
        state = 972;
        fontFaceDeclaration();
      }

      state = 982;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_SemiColon) {
        state = 975;
        match(TOKEN_SemiColon);
        state = 976;
        ws();
        state = 978;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
          state = 977;
          fontFaceDeclaration();
        }

        state = 984;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 985;
      match(TOKEN_CloseBrace);
      state = 986;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FontFaceDeclarationContext fontFaceDeclaration() {
    dynamic _localctx = FontFaceDeclarationContext(context, state);
    enterRule(_localctx, 130, RULE_fontFaceDeclaration);
    try {
      state = 998;
      errorHandler.sync(this);
      switch (interpreter!.adaptivePredict(tokenStream, 100, context)) {
      case 1:
        _localctx = KnownFontFaceDeclarationContext(_localctx);
        enterOuterAlt(_localctx, 1);
        state = 988;
        property_();
        state = 989;
        match(TOKEN_Colon);
        state = 990;
        ws();
        state = 991;
        expr();
        break;
      case 2:
        _localctx = UnknownFontFaceDeclarationContext(_localctx);
        enterOuterAlt(_localctx, 2);
        state = 993;
        property_();
        state = 994;
        match(TOKEN_Colon);
        state = 995;
        ws();
        state = 996;
        value();
        break;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  KeyframesRuleContext keyframesRule() {
    dynamic _localctx = KeyframesRuleContext(context, state);
    enterRule(_localctx, 132, RULE_keyframesRule);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1000;
      match(TOKEN_Keyframes);
      state = 1001;
      ws();
      state = 1002;
      match(TOKEN_Space);
      state = 1003;
      ws();
      state = 1004;
      ident();
      state = 1005;
      ws();
      state = 1006;
      match(TOKEN_OpenBrace);
      state = 1007;
      ws();
      state = 1011;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[29, 52, 53].contains(_la))) {
        state = 1008;
        keyframeBlock();
        state = 1013;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 1014;
      match(TOKEN_CloseBrace);
      state = 1015;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  KeyframeBlockContext keyframeBlock() {
    dynamic _localctx = KeyframeBlockContext(context, state);
    enterRule(_localctx, 134, RULE_keyframeBlock);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1017;
      keyframeSelector();
      state = 1018;
      match(TOKEN_OpenBrace);
      state = 1019;
      ws();
      state = 1021;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[7, 11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
        state = 1020;
        declarationList();
      }

      state = 1023;
      match(TOKEN_CloseBrace);
      state = 1024;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  KeyframeSelectorContext keyframeSelector() {
    dynamic _localctx = KeyframeSelectorContext(context, state);
    enterRule(_localctx, 136, RULE_keyframeSelector);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1026;
      _la = tokenStream.LA(1)!;
      if (!((((_la) & ~0x3f) == 0 && const <int>[29, 52, 53].contains(_la)))) {
      errorHandler.recoverInline(this);
      } else {
        if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
        errorHandler.reportMatch(this);
        consume();
      }
      state = 1027;
      ws();
      state = 1035;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_Comma) {
        state = 1028;
        match(TOKEN_Comma);
        state = 1029;
        ws();
        state = 1030;
        _la = tokenStream.LA(1)!;
        if (!((((_la) & ~0x3f) == 0 && const <int>[29, 52, 53].contains(_la)))) {
        errorHandler.recoverInline(this);
        } else {
          if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
          errorHandler.reportMatch(this);
          consume();
        }
        state = 1031;
        ws();
        state = 1037;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  ViewportContext viewport() {
    dynamic _localctx = ViewportContext(context, state);
    enterRule(_localctx, 138, RULE_viewport);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1038;
      match(TOKEN_Viewport);
      state = 1039;
      ws();
      state = 1040;
      match(TOKEN_OpenBrace);
      state = 1041;
      ws();
      state = 1043;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[7, 11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
        state = 1042;
        declarationList();
      }

      state = 1045;
      match(TOKEN_CloseBrace);
      state = 1046;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  CounterStyleContext counterStyle() {
    dynamic _localctx = CounterStyleContext(context, state);
    enterRule(_localctx, 140, RULE_counterStyle);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1048;
      match(TOKEN_CounterStyle);
      state = 1049;
      ws();
      state = 1050;
      ident();
      state = 1051;
      ws();
      state = 1052;
      match(TOKEN_OpenBrace);
      state = 1053;
      ws();
      state = 1055;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[7, 11, 14, 32, 33, 34, 50, 52, 53, 60, 62].contains(_la))) {
        state = 1054;
        declarationList();
      }

      state = 1057;
      match(TOKEN_CloseBrace);
      state = 1058;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FontFeatureValuesRuleContext fontFeatureValuesRule() {
    dynamic _localctx = FontFeatureValuesRuleContext(context, state);
    enterRule(_localctx, 142, RULE_fontFeatureValuesRule);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1060;
      match(TOKEN_FontFeatureValues);
      state = 1061;
      ws();
      state = 1062;
      fontFamilyNameList();
      state = 1063;
      ws();
      state = 1064;
      match(TOKEN_OpenBrace);
      state = 1065;
      ws();
      state = 1069;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while (_la == TOKEN_AtKeyword) {
        state = 1066;
        featureValueBlock();
        state = 1071;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 1072;
      match(TOKEN_CloseBrace);
      state = 1073;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FontFamilyNameListContext fontFamilyNameList() {
    dynamic _localctx = FontFamilyNameListContext(context, state);
    enterRule(_localctx, 144, RULE_fontFamilyNameList);
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 1075;
      fontFamilyName();
      state = 1083;
      errorHandler.sync(this);
      _alt = interpreter!.adaptivePredict(tokenStream, 107, context);
      while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
        if (_alt == 1) {
          state = 1076;
          ws();
          state = 1077;
          match(TOKEN_Comma);
          state = 1078;
          ws();
          state = 1079;
          fontFamilyName(); 
        }
        state = 1085;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 107, context);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FontFamilyNameContext fontFamilyName() {
    dynamic _localctx = FontFamilyNameContext(context, state);
    enterRule(_localctx, 146, RULE_fontFamilyName);
    try {
      int _alt;
      state = 1096;
      errorHandler.sync(this);
      switch (tokenStream.LA(1)!) {
      case TOKEN_String_:
        enterOuterAlt(_localctx, 1);
        state = 1086;
        match(TOKEN_String_);
        break;
      case TOKEN_MediaOnly:
      case TOKEN_Not:
      case TOKEN_And:
      case TOKEN_Or:
      case TOKEN_From:
      case TOKEN_To:
      case TOKEN_Ident:
        enterOuterAlt(_localctx, 2);
        state = 1087;
        ident();
        state = 1093;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 108, context);
        while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
          if (_alt == 1) {
            state = 1088;
            ws();
            state = 1089;
            ident(); 
          }
          state = 1095;
          errorHandler.sync(this);
          _alt = interpreter!.adaptivePredict(tokenStream, 108, context);
        }
        break;
      default:
        throw NoViableAltException(this);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FeatureValueBlockContext featureValueBlock() {
    dynamic _localctx = FeatureValueBlockContext(context, state);
    enterRule(_localctx, 148, RULE_featureValueBlock);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1098;
      featureType();
      state = 1099;
      ws();
      state = 1100;
      match(TOKEN_OpenBrace);
      state = 1101;
      ws();
      state = 1103;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      if ((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 50, 52, 53, 62].contains(_la))) {
        state = 1102;
        featureValueDefinition();
      }

      state = 1113;
      errorHandler.sync(this);
      _la = tokenStream.LA(1)!;
      while ((((_la) & ~0x3f) == 0 && const <int>[7, 15, 17].contains(_la))) {
        state = 1105;
        ws();
        state = 1106;
        match(TOKEN_SemiColon);
        state = 1107;
        ws();
        state = 1109;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
        if ((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 50, 52, 53, 62].contains(_la))) {
          state = 1108;
          featureValueDefinition();
        }

        state = 1115;
        errorHandler.sync(this);
        _la = tokenStream.LA(1)!;
      }
      state = 1116;
      match(TOKEN_CloseBrace);
      state = 1117;
      ws();
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FeatureTypeContext featureType() {
    dynamic _localctx = FeatureTypeContext(context, state);
    enterRule(_localctx, 150, RULE_featureType);
    try {
      enterOuterAlt(_localctx, 1);
      state = 1119;
      match(TOKEN_AtKeyword);
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  FeatureValueDefinitionContext featureValueDefinition() {
    dynamic _localctx = FeatureValueDefinitionContext(context, state);
    enterRule(_localctx, 152, RULE_featureValueDefinition);
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 1121;
      ident();
      state = 1122;
      ws();
      state = 1123;
      match(TOKEN_Colon);
      state = 1124;
      ws();
      state = 1125;
      number();
      state = 1131;
      errorHandler.sync(this);
      _alt = interpreter!.adaptivePredict(tokenStream, 113, context);
      while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
        if (_alt == 1) {
          state = 1126;
          ws();
          state = 1127;
          number(); 
        }
        state = 1133;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 113, context);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  IdentContext ident() {
    dynamic _localctx = IdentContext(context, state);
    enterRule(_localctx, 154, RULE_ident);
    int _la;
    try {
      enterOuterAlt(_localctx, 1);
      state = 1134;
      _la = tokenStream.LA(1)!;
      if (!((((_la) & ~0x3f) == 0 && const <int>[32, 33, 34, 50, 52, 53, 62].contains(_la)))) {
      errorHandler.recoverInline(this);
      } else {
        if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
        errorHandler.reportMatch(this);
        consume();
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  WsContext ws() {
    dynamic _localctx = WsContext(context, state);
    enterRule(_localctx, 156, RULE_ws);
    int _la;
    try {
      int _alt;
      enterOuterAlt(_localctx, 1);
      state = 1139;
      errorHandler.sync(this);
      _alt = interpreter!.adaptivePredict(tokenStream, 114, context);
      while (_alt != 2 && _alt != ATN.INVALID_ALT_NUMBER) {
        if (_alt == 1) {
          state = 1136;
          _la = tokenStream.LA(1)!;
          if (!(_la == TOKEN_Comment || _la == TOKEN_Space)) {
          errorHandler.recoverInline(this);
          } else {
            if ( tokenStream.LA(1)! == IntStream.EOF ) matchedEOF = true;
            errorHandler.reportMatch(this);
            consume();
          } 
        }
        state = 1141;
        errorHandler.sync(this);
        _alt = interpreter!.adaptivePredict(tokenStream, 114, context);
      }
    } on RecognitionException catch (re) {
      _localctx.exception = re;
      errorHandler.reportError(this, re);
      errorHandler.recover(this, re);
    } finally {
      exitRule();
    }
    return _localctx;
  }

  static const List<int> _serializedATN = [
      4,1,64,1143,2,0,7,0,2,1,7,1,2,2,7,2,2,3,7,3,2,4,7,4,2,5,7,5,2,6,7,
      6,2,7,7,7,2,8,7,8,2,9,7,9,2,10,7,10,2,11,7,11,2,12,7,12,2,13,7,13,
      2,14,7,14,2,15,7,15,2,16,7,16,2,17,7,17,2,18,7,18,2,19,7,19,2,20,7,
      20,2,21,7,21,2,22,7,22,2,23,7,23,2,24,7,24,2,25,7,25,2,26,7,26,2,27,
      7,27,2,28,7,28,2,29,7,29,2,30,7,30,2,31,7,31,2,32,7,32,2,33,7,33,2,
      34,7,34,2,35,7,35,2,36,7,36,2,37,7,37,2,38,7,38,2,39,7,39,2,40,7,40,
      2,41,7,41,2,42,7,42,2,43,7,43,2,44,7,44,2,45,7,45,2,46,7,46,2,47,7,
      47,2,48,7,48,2,49,7,49,2,50,7,50,2,51,7,51,2,52,7,52,2,53,7,53,2,54,
      7,54,2,55,7,55,2,56,7,56,2,57,7,57,2,58,7,58,2,59,7,59,2,60,7,60,2,
      61,7,61,2,62,7,62,2,63,7,63,2,64,7,64,2,65,7,65,2,66,7,66,2,67,7,67,
      2,68,7,68,2,69,7,69,2,70,7,70,2,71,7,71,2,72,7,72,2,73,7,73,2,74,7,
      74,2,75,7,75,2,76,7,76,2,77,7,77,2,78,7,78,1,0,1,0,1,0,5,0,162,8,0,
      10,0,12,0,165,9,0,5,0,167,8,0,10,0,12,0,170,9,0,1,0,1,0,5,0,174,8,
      0,10,0,12,0,177,9,0,5,0,179,8,0,10,0,12,0,182,9,0,1,0,1,0,5,0,186,
      8,0,10,0,12,0,189,9,0,5,0,191,8,0,10,0,12,0,194,9,0,1,0,1,0,5,0,198,
      8,0,10,0,12,0,201,9,0,5,0,203,8,0,10,0,12,0,206,9,0,1,0,1,0,1,1,1,
      1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,3,1,222,8,1,1,2,1,2,1,2,
      1,2,3,2,228,8,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,3,2,239,8,2,1,
      2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,3,2,249,8,2,1,2,1,2,1,2,1,2,1,2,1,2,
      1,2,3,2,258,8,2,1,2,1,2,3,2,262,8,2,1,3,1,3,1,3,1,3,1,3,3,3,269,8,
      3,1,3,1,3,3,3,273,8,3,1,3,1,3,1,3,1,3,1,3,1,3,1,3,1,3,1,3,3,3,284,
      8,3,1,3,1,3,3,3,288,8,3,1,3,1,3,3,3,292,8,3,1,4,1,4,1,5,1,5,1,5,1,
      5,1,5,1,5,1,6,1,6,1,6,1,6,1,6,5,6,307,8,6,10,6,12,6,310,9,6,3,6,312,
      8,6,1,6,1,6,1,7,3,7,317,8,7,1,7,1,7,1,7,1,7,1,7,1,7,1,7,5,7,326,8,
      7,10,7,12,7,329,9,7,1,7,1,7,1,7,1,7,1,7,5,7,336,8,7,10,7,12,7,339,
      9,7,3,7,341,8,7,1,8,1,8,1,9,1,9,1,9,1,9,1,9,1,9,1,9,3,9,352,8,9,1,
      9,1,9,1,9,1,10,1,10,1,10,1,11,1,11,1,11,3,11,363,8,11,1,11,1,11,1,
      11,3,11,368,8,11,1,11,1,11,1,11,3,11,373,8,11,5,11,375,8,11,10,11,
      12,11,378,9,11,1,11,1,11,1,11,1,12,1,12,1,12,1,12,1,13,1,13,1,13,1,
      13,1,13,5,13,392,8,13,10,13,12,13,395,9,13,1,14,1,14,3,14,399,8,14,
      1,14,1,14,1,14,1,14,1,14,1,14,5,14,407,8,14,10,14,12,14,410,9,14,1,
      15,1,15,1,15,1,15,1,15,1,15,1,15,3,15,419,8,15,1,16,1,16,3,16,423,
      8,16,1,16,1,16,1,16,1,16,1,16,5,16,430,8,16,10,16,12,16,433,9,16,1,
      16,1,16,1,16,1,16,1,16,4,16,440,8,16,11,16,12,16,441,3,16,444,8,16,
      1,17,3,17,447,8,17,1,17,1,17,1,18,1,18,3,18,453,8,18,1,18,1,18,1,19,
      1,19,1,20,3,20,460,8,20,1,20,1,20,1,21,1,21,1,21,1,22,1,22,1,22,3,
      22,470,8,22,1,22,1,22,1,22,1,22,1,22,1,22,3,22,478,8,22,1,22,1,22,
      3,22,482,8,22,1,22,1,22,1,23,1,23,3,23,488,8,23,1,23,1,23,3,23,492,
      8,23,1,24,1,24,1,24,1,24,3,24,498,8,24,1,24,1,24,1,25,1,25,1,25,1,
      25,1,25,1,25,1,25,3,25,509,8,25,1,25,4,25,512,8,25,11,25,12,25,513,
      1,26,1,26,1,26,1,26,1,26,1,26,1,27,1,27,1,27,1,27,1,27,1,27,3,27,528,
      8,27,1,28,1,28,1,28,1,28,1,28,1,28,1,28,1,28,3,28,538,8,28,1,29,1,
      29,1,29,1,29,1,29,1,29,1,29,1,29,1,29,3,29,549,8,29,1,30,1,30,1,30,
      1,30,3,30,555,8,30,1,30,1,30,1,30,1,30,5,30,561,8,30,10,30,12,30,564,
      9,30,1,30,1,30,1,30,3,30,569,8,30,1,30,1,30,1,30,3,30,574,8,30,1,31,
      1,31,5,31,578,8,31,10,31,12,31,581,9,31,1,31,1,31,1,31,1,31,1,31,3,
      31,588,8,31,5,31,590,8,31,10,31,12,31,593,9,31,1,32,1,32,1,32,1,32,
      1,32,3,32,600,8,32,1,32,1,32,1,32,1,32,1,32,3,32,607,8,32,1,33,1,33,
      1,33,1,34,1,34,1,34,1,34,4,34,616,8,34,11,34,12,34,617,1,35,1,35,3,
      35,622,8,35,1,35,5,35,625,8,35,10,35,12,35,628,9,35,1,36,1,36,1,36,
      1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,
      36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,1,36,3,36,657,8,36,
      1,37,1,37,1,37,1,37,1,37,1,37,1,38,1,38,1,38,1,38,1,38,1,38,1,39,1,
      39,1,39,1,40,3,40,675,8,40,1,40,1,40,1,41,3,41,680,8,41,1,41,1,41,
      1,42,3,42,685,8,42,1,42,1,42,1,43,3,43,690,8,43,1,43,1,43,1,44,1,44,
      1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,
      44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,1,44,
      1,44,1,44,1,44,1,44,1,44,5,44,728,8,44,10,44,12,44,731,9,44,1,44,1,
      44,1,44,1,44,1,44,1,44,1,44,5,44,740,8,44,10,44,12,44,743,9,44,1,44,
      1,44,1,44,1,44,1,44,1,44,1,44,5,44,752,8,44,10,44,12,44,755,9,44,1,
      44,1,44,1,44,3,44,760,8,44,1,45,1,45,1,45,5,45,765,8,45,10,45,12,45,
      768,9,45,1,45,1,45,1,45,3,45,773,8,45,1,46,1,46,1,46,1,46,1,46,1,46,
      1,46,1,46,1,46,3,46,784,8,46,1,47,1,47,1,47,1,47,1,47,1,47,1,47,1,
      47,1,47,1,47,5,47,796,8,47,10,47,12,47,799,9,47,1,47,1,47,1,47,1,48,
      1,48,1,48,1,48,1,48,1,48,1,48,1,48,1,48,1,48,3,48,814,8,48,1,49,1,
      49,1,49,5,49,819,8,49,10,49,12,49,822,9,49,1,49,1,49,1,49,1,50,1,50,
      1,50,1,50,1,50,1,50,1,51,1,51,1,51,1,51,3,51,837,8,51,1,52,1,52,1,
      52,1,52,1,52,1,52,1,52,1,52,3,52,847,8,52,1,53,1,53,1,53,1,53,1,53,
      1,53,1,54,1,54,1,54,1,54,1,54,1,54,1,54,1,54,1,54,1,54,4,54,865,8,
      54,11,54,12,54,866,1,55,1,55,1,55,1,55,1,55,1,55,1,55,1,55,1,55,1,
      55,4,55,879,8,55,11,55,12,55,880,1,56,1,56,1,56,1,56,1,56,1,57,1,57,
      1,57,5,57,891,8,57,10,57,12,57,894,9,57,1,57,1,57,1,58,1,58,1,58,1,
      58,1,58,1,58,1,58,3,58,905,8,58,1,59,1,59,1,59,1,59,1,59,1,59,1,59,
      1,60,1,60,1,60,1,60,1,60,1,60,1,61,1,61,1,61,1,61,1,61,1,61,1,61,1,
      61,1,61,5,61,929,8,61,10,61,12,61,932,9,61,1,62,1,62,1,62,1,62,1,62,
      1,62,1,62,1,62,1,62,1,62,5,62,944,8,62,10,62,12,62,947,9,62,1,63,1,
      63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,1,63,
      1,63,1,63,1,63,3,63,967,8,63,1,64,1,64,1,64,1,64,1,64,3,64,974,8,64,
      1,64,1,64,1,64,3,64,979,8,64,5,64,981,8,64,10,64,12,64,984,9,64,1,
      64,1,64,1,64,1,65,1,65,1,65,1,65,1,65,1,65,1,65,1,65,1,65,1,65,3,65,
      999,8,65,1,66,1,66,1,66,1,66,1,66,1,66,1,66,1,66,1,66,5,66,1010,8,
      66,10,66,12,66,1013,9,66,1,66,1,66,1,66,1,67,1,67,1,67,1,67,3,67,1022,
      8,67,1,67,1,67,1,67,1,68,1,68,1,68,1,68,1,68,1,68,1,68,5,68,1034,8,
      68,10,68,12,68,1037,9,68,1,69,1,69,1,69,1,69,1,69,3,69,1044,8,69,1,
      69,1,69,1,69,1,70,1,70,1,70,1,70,1,70,1,70,1,70,3,70,1056,8,70,1,70,
      1,70,1,70,1,71,1,71,1,71,1,71,1,71,1,71,1,71,5,71,1068,8,71,10,71,
      12,71,1071,9,71,1,71,1,71,1,71,1,72,1,72,1,72,1,72,1,72,1,72,5,72,
      1082,8,72,10,72,12,72,1085,9,72,1,73,1,73,1,73,1,73,1,73,5,73,1092,
      8,73,10,73,12,73,1095,9,73,3,73,1097,8,73,1,74,1,74,1,74,1,74,1,74,
      3,74,1104,8,74,1,74,1,74,1,74,1,74,3,74,1110,8,74,5,74,1112,8,74,10,
      74,12,74,1115,9,74,1,74,1,74,1,74,1,75,1,75,1,76,1,76,1,76,1,76,1,
      76,1,76,1,76,1,76,5,76,1130,8,76,10,76,12,76,1133,9,76,1,77,1,77,1,
      78,5,78,1138,8,78,10,78,12,78,1141,9,78,1,78,0,0,79,0,2,4,6,8,10,12,
      14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,
      58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,92,94,96,98,100,
      102,104,106,108,110,112,114,116,118,120,122,124,126,128,130,132,134,
      136,138,140,142,144,146,148,150,152,154,156,0,8,2,0,15,15,17,19,1,
      0,32,33,3,0,8,8,20,21,45,47,1,0,37,38,2,0,3,3,63,63,2,0,29,29,52,53,
      4,0,32,34,50,50,52,53,62,62,2,0,15,15,17,17,1248,0,158,1,0,0,0,2,221,
      1,0,0,0,4,261,1,0,0,0,6,291,1,0,0,0,8,293,1,0,0,0,10,295,1,0,0,0,12,
      311,1,0,0,0,14,340,1,0,0,0,16,342,1,0,0,0,18,344,1,0,0,0,20,356,1,
      0,0,0,22,359,1,0,0,0,24,382,1,0,0,0,26,386,1,0,0,0,28,398,1,0,0,0,
      30,418,1,0,0,0,32,443,1,0,0,0,34,446,1,0,0,0,36,452,1,0,0,0,38,456,
      1,0,0,0,40,459,1,0,0,0,42,463,1,0,0,0,44,466,1,0,0,0,46,485,1,0,0,
      0,48,493,1,0,0,0,50,511,1,0,0,0,52,515,1,0,0,0,54,527,1,0,0,0,56,537,
      1,0,0,0,58,548,1,0,0,0,60,573,1,0,0,0,62,579,1,0,0,0,64,606,1,0,0,
      0,66,608,1,0,0,0,68,615,1,0,0,0,70,619,1,0,0,0,72,656,1,0,0,0,74,658,
      1,0,0,0,76,664,1,0,0,0,78,670,1,0,0,0,80,674,1,0,0,0,82,679,1,0,0,
      0,84,684,1,0,0,0,86,689,1,0,0,0,88,759,1,0,0,0,90,761,1,0,0,0,92,783,
      1,0,0,0,94,785,1,0,0,0,96,813,1,0,0,0,98,815,1,0,0,0,100,826,1,0,0,
      0,102,836,1,0,0,0,104,846,1,0,0,0,106,848,1,0,0,0,108,854,1,0,0,0,
      110,868,1,0,0,0,112,882,1,0,0,0,114,887,1,0,0,0,116,904,1,0,0,0,118,
      906,1,0,0,0,120,913,1,0,0,0,122,919,1,0,0,0,124,933,1,0,0,0,126,966,
      1,0,0,0,128,968,1,0,0,0,130,998,1,0,0,0,132,1000,1,0,0,0,134,1017,
      1,0,0,0,136,1026,1,0,0,0,138,1038,1,0,0,0,140,1048,1,0,0,0,142,1060,
      1,0,0,0,144,1075,1,0,0,0,146,1096,1,0,0,0,148,1098,1,0,0,0,150,1119,
      1,0,0,0,152,1121,1,0,0,0,154,1134,1,0,0,0,156,1139,1,0,0,0,158,168,
      3,156,78,0,159,163,3,2,1,0,160,162,7,0,0,0,161,160,1,0,0,0,162,165,
      1,0,0,0,163,161,1,0,0,0,163,164,1,0,0,0,164,167,1,0,0,0,165,163,1,
      0,0,0,166,159,1,0,0,0,167,170,1,0,0,0,168,166,1,0,0,0,168,169,1,0,
      0,0,169,180,1,0,0,0,170,168,1,0,0,0,171,175,3,4,2,0,172,174,7,0,0,
      0,173,172,1,0,0,0,174,177,1,0,0,0,175,173,1,0,0,0,175,176,1,0,0,0,
      176,179,1,0,0,0,177,175,1,0,0,0,178,171,1,0,0,0,179,182,1,0,0,0,180,
      178,1,0,0,0,180,181,1,0,0,0,181,192,1,0,0,0,182,180,1,0,0,0,183,187,
      3,6,3,0,184,186,7,0,0,0,185,184,1,0,0,0,186,189,1,0,0,0,187,185,1,
      0,0,0,187,188,1,0,0,0,188,191,1,0,0,0,189,187,1,0,0,0,190,183,1,0,
      0,0,191,194,1,0,0,0,192,190,1,0,0,0,192,193,1,0,0,0,193,204,1,0,0,
      0,194,192,1,0,0,0,195,199,3,96,48,0,196,198,7,0,0,0,197,196,1,0,0,
      0,198,201,1,0,0,0,199,197,1,0,0,0,199,200,1,0,0,0,200,203,1,0,0,0,
      201,199,1,0,0,0,202,195,1,0,0,0,203,206,1,0,0,0,204,202,1,0,0,0,204,
      205,1,0,0,0,205,207,1,0,0,0,206,204,1,0,0,0,207,208,5,0,0,1,208,1,
      1,0,0,0,209,210,5,27,0,0,210,211,3,156,78,0,211,212,5,44,0,0,212,213,
      3,156,78,0,213,214,5,7,0,0,214,215,3,156,78,0,215,222,1,0,0,0,216,
      217,5,27,0,0,217,218,3,156,78,0,218,219,5,44,0,0,219,220,3,156,78,
      0,220,222,1,0,0,0,221,209,1,0,0,0,221,216,1,0,0,0,222,3,1,0,0,0,223,
      224,5,23,0,0,224,227,3,156,78,0,225,228,5,44,0,0,226,228,3,116,58,
      0,227,225,1,0,0,0,227,226,1,0,0,0,228,229,1,0,0,0,229,230,3,156,78,
      0,230,231,3,12,6,0,231,232,5,7,0,0,232,233,3,156,78,0,233,262,1,0,
      0,0,234,235,5,23,0,0,235,238,3,156,78,0,236,239,5,44,0,0,237,239,3,
      116,58,0,238,236,1,0,0,0,238,237,1,0,0,0,239,240,1,0,0,0,240,241,3,
      156,78,0,241,242,5,7,0,0,242,243,3,156,78,0,243,262,1,0,0,0,244,245,
      5,23,0,0,245,248,3,156,78,0,246,249,5,44,0,0,247,249,3,116,58,0,248,
      246,1,0,0,0,248,247,1,0,0,0,249,250,1,0,0,0,250,251,3,156,78,0,251,
      252,3,12,6,0,252,262,1,0,0,0,253,254,5,23,0,0,254,257,3,156,78,0,255,
      258,5,44,0,0,256,258,3,116,58,0,257,255,1,0,0,0,257,256,1,0,0,0,258,
      259,1,0,0,0,259,260,3,156,78,0,260,262,1,0,0,0,261,223,1,0,0,0,261,
      234,1,0,0,0,261,244,1,0,0,0,261,253,1,0,0,0,262,5,1,0,0,0,263,264,
      5,26,0,0,264,268,3,156,78,0,265,266,3,8,4,0,266,267,3,156,78,0,267,
      269,1,0,0,0,268,265,1,0,0,0,268,269,1,0,0,0,269,272,1,0,0,0,270,273,
      5,44,0,0,271,273,3,116,58,0,272,270,1,0,0,0,272,271,1,0,0,0,273,274,
      1,0,0,0,274,275,3,156,78,0,275,276,5,7,0,0,276,277,3,156,78,0,277,
      292,1,0,0,0,278,279,5,26,0,0,279,283,3,156,78,0,280,281,3,8,4,0,281,
      282,3,156,78,0,282,284,1,0,0,0,283,280,1,0,0,0,283,284,1,0,0,0,284,
      287,1,0,0,0,285,288,5,44,0,0,286,288,3,116,58,0,287,285,1,0,0,0,287,
      286,1,0,0,0,288,289,1,0,0,0,289,290,3,156,78,0,290,292,1,0,0,0,291,
      263,1,0,0,0,291,278,1,0,0,0,292,7,1,0,0,0,293,294,3,154,77,0,294,9,
      1,0,0,0,295,296,5,25,0,0,296,297,3,156,78,0,297,298,3,12,6,0,298,299,
      3,98,49,0,299,300,3,156,78,0,300,11,1,0,0,0,301,308,3,14,7,0,302,303,
      5,40,0,0,303,304,3,156,78,0,304,305,3,14,7,0,305,307,1,0,0,0,306,302,
      1,0,0,0,307,310,1,0,0,0,308,306,1,0,0,0,308,309,1,0,0,0,309,312,1,
      0,0,0,310,308,1,0,0,0,311,301,1,0,0,0,311,312,1,0,0,0,312,313,1,0,
      0,0,313,314,3,156,78,0,314,13,1,0,0,0,315,317,7,1,0,0,316,315,1,0,
      0,0,316,317,1,0,0,0,317,318,1,0,0,0,318,319,3,156,78,0,319,320,3,16,
      8,0,320,327,3,156,78,0,321,322,5,34,0,0,322,323,3,156,78,0,323,324,
      3,18,9,0,324,326,1,0,0,0,325,321,1,0,0,0,326,329,1,0,0,0,327,325,1,
      0,0,0,327,328,1,0,0,0,328,341,1,0,0,0,329,327,1,0,0,0,330,337,3,18,
      9,0,331,332,5,34,0,0,332,333,3,156,78,0,333,334,3,18,9,0,334,336,1,
      0,0,0,335,331,1,0,0,0,336,339,1,0,0,0,337,335,1,0,0,0,337,338,1,0,
      0,0,338,341,1,0,0,0,339,337,1,0,0,0,340,316,1,0,0,0,340,330,1,0,0,
      0,341,15,1,0,0,0,342,343,3,154,77,0,343,17,1,0,0,0,344,345,5,3,0,0,
      345,346,3,156,78,0,346,351,3,20,10,0,347,348,5,9,0,0,348,349,3,156,
      78,0,349,350,3,70,35,0,350,352,1,0,0,0,351,347,1,0,0,0,351,352,1,0,
      0,0,352,353,1,0,0,0,353,354,5,4,0,0,354,355,3,156,78,0,355,19,1,0,
      0,0,356,357,3,154,77,0,357,358,3,156,78,0,358,21,1,0,0,0,359,360,5,
      24,0,0,360,362,3,156,78,0,361,363,3,24,12,0,362,361,1,0,0,0,362,363,
      1,0,0,0,363,364,1,0,0,0,364,365,5,5,0,0,365,367,3,156,78,0,366,368,
      3,64,32,0,367,366,1,0,0,0,367,368,1,0,0,0,368,376,1,0,0,0,369,370,
      5,7,0,0,370,372,3,156,78,0,371,373,3,64,32,0,372,371,1,0,0,0,372,373,
      1,0,0,0,373,375,1,0,0,0,374,369,1,0,0,0,375,378,1,0,0,0,376,374,1,
      0,0,0,376,377,1,0,0,0,377,379,1,0,0,0,378,376,1,0,0,0,379,380,5,6,
      0,0,380,381,3,156,78,0,381,23,1,0,0,0,382,383,5,9,0,0,383,384,3,154,
      77,0,384,385,3,156,78,0,385,25,1,0,0,0,386,393,3,28,14,0,387,388,5,
      40,0,0,388,389,3,156,78,0,389,390,3,28,14,0,390,392,1,0,0,0,391,387,
      1,0,0,0,392,395,1,0,0,0,393,391,1,0,0,0,393,394,1,0,0,0,394,27,1,0,
      0,0,395,393,1,0,0,0,396,399,3,30,15,0,397,399,3,156,78,0,398,396,1,
      0,0,0,398,397,1,0,0,0,399,400,1,0,0,0,400,401,3,32,16,0,401,408,3,
      156,78,0,402,403,3,30,15,0,403,404,3,32,16,0,404,405,3,156,78,0,405,
      407,1,0,0,0,406,402,1,0,0,0,407,410,1,0,0,0,408,406,1,0,0,0,408,409,
      1,0,0,0,409,29,1,0,0,0,410,408,1,0,0,0,411,412,5,37,0,0,412,419,3,
      156,78,0,413,414,5,39,0,0,414,419,3,156,78,0,415,416,5,41,0,0,416,
      419,3,156,78,0,417,419,3,156,78,0,418,411,1,0,0,0,418,413,1,0,0,0,
      418,415,1,0,0,0,418,417,1,0,0,0,419,31,1,0,0,0,420,423,3,34,17,0,421,
      423,3,40,20,0,422,420,1,0,0,0,422,421,1,0,0,0,423,431,1,0,0,0,424,
      430,5,22,0,0,425,430,3,42,21,0,426,430,3,44,22,0,427,430,3,46,23,0,
      428,430,3,52,26,0,429,424,1,0,0,0,429,425,1,0,0,0,429,426,1,0,0,0,
      429,427,1,0,0,0,429,428,1,0,0,0,430,433,1,0,0,0,431,429,1,0,0,0,431,
      432,1,0,0,0,432,444,1,0,0,0,433,431,1,0,0,0,434,440,5,22,0,0,435,440,
      3,42,21,0,436,440,3,44,22,0,437,440,3,46,23,0,438,440,3,52,26,0,439,
      434,1,0,0,0,439,435,1,0,0,0,439,436,1,0,0,0,439,437,1,0,0,0,439,438,
      1,0,0,0,440,441,1,0,0,0,441,439,1,0,0,0,441,442,1,0,0,0,442,444,1,
      0,0,0,443,422,1,0,0,0,443,439,1,0,0,0,444,33,1,0,0,0,445,447,3,36,
      18,0,446,445,1,0,0,0,446,447,1,0,0,0,447,448,1,0,0,0,448,449,3,38,
      19,0,449,35,1,0,0,0,450,453,3,154,77,0,451,453,5,11,0,0,452,450,1,
      0,0,0,452,451,1,0,0,0,452,453,1,0,0,0,453,454,1,0,0,0,454,455,5,13,
      0,0,455,37,1,0,0,0,456,457,3,154,77,0,457,39,1,0,0,0,458,460,3,36,
      18,0,459,458,1,0,0,0,459,460,1,0,0,0,460,461,1,0,0,0,461,462,5,11,
      0,0,462,41,1,0,0,0,463,464,5,10,0,0,464,465,3,154,77,0,465,43,1,0,
      0,0,466,467,5,1,0,0,467,469,3,156,78,0,468,470,3,36,18,0,469,468,1,
      0,0,0,469,470,1,0,0,0,470,471,1,0,0,0,471,472,3,154,77,0,472,481,3,
      156,78,0,473,474,7,2,0,0,474,477,3,156,78,0,475,478,3,154,77,0,476,
      478,5,44,0,0,477,475,1,0,0,0,477,476,1,0,0,0,478,479,1,0,0,0,479,480,
      3,156,78,0,480,482,1,0,0,0,481,473,1,0,0,0,481,482,1,0,0,0,482,483,
      1,0,0,0,483,484,5,2,0,0,484,45,1,0,0,0,485,487,5,9,0,0,486,488,5,9,
      0,0,487,486,1,0,0,0,487,488,1,0,0,0,488,491,1,0,0,0,489,492,3,154,
      77,0,490,492,3,48,24,0,491,489,1,0,0,0,491,490,1,0,0,0,492,47,1,0,
      0,0,493,494,5,63,0,0,494,497,3,156,78,0,495,498,3,50,25,0,496,498,
      3,28,14,0,497,495,1,0,0,0,497,496,1,0,0,0,498,499,1,0,0,0,499,500,
      5,4,0,0,500,49,1,0,0,0,501,509,5,37,0,0,502,509,5,38,0,0,503,509,5,
      35,0,0,504,509,5,36,0,0,505,509,5,43,0,0,506,509,5,44,0,0,507,509,
      3,154,77,0,508,501,1,0,0,0,508,502,1,0,0,0,508,503,1,0,0,0,508,504,
      1,0,0,0,508,505,1,0,0,0,508,506,1,0,0,0,508,507,1,0,0,0,509,510,1,
      0,0,0,510,512,3,156,78,0,511,508,1,0,0,0,512,513,1,0,0,0,513,511,1,
      0,0,0,513,514,1,0,0,0,514,51,1,0,0,0,515,516,5,42,0,0,516,517,3,156,
      78,0,517,518,3,54,27,0,518,519,3,156,78,0,519,520,5,4,0,0,520,53,1,
      0,0,0,521,528,3,34,17,0,522,528,3,40,20,0,523,528,5,22,0,0,524,528,
      3,42,21,0,525,528,3,44,22,0,526,528,3,46,23,0,527,521,1,0,0,0,527,
      522,1,0,0,0,527,523,1,0,0,0,527,524,1,0,0,0,527,525,1,0,0,0,527,526,
      1,0,0,0,528,55,1,0,0,0,529,530,5,12,0,0,530,538,3,156,78,0,531,532,
      5,40,0,0,532,538,3,156,78,0,533,534,5,17,0,0,534,538,3,156,78,0,535,
      536,5,8,0,0,536,538,3,156,78,0,537,529,1,0,0,0,537,531,1,0,0,0,537,
      533,1,0,0,0,537,535,1,0,0,0,538,57,1,0,0,0,539,540,3,154,77,0,540,
      541,3,156,78,0,541,549,1,0,0,0,542,543,5,60,0,0,543,549,3,156,78,0,
      544,545,5,11,0,0,545,549,3,154,77,0,546,547,5,14,0,0,547,549,3,154,
      77,0,548,539,1,0,0,0,548,542,1,0,0,0,548,544,1,0,0,0,548,546,1,0,0,
      0,549,59,1,0,0,0,550,551,3,26,13,0,551,552,5,5,0,0,552,554,3,156,78,
      0,553,555,3,62,31,0,554,553,1,0,0,0,554,555,1,0,0,0,555,556,1,0,0,
      0,556,557,5,6,0,0,557,558,3,156,78,0,558,574,1,0,0,0,559,561,3,88,
      44,0,560,559,1,0,0,0,561,564,1,0,0,0,562,560,1,0,0,0,562,563,1,0,0,
      0,563,565,1,0,0,0,564,562,1,0,0,0,565,566,5,5,0,0,566,568,3,156,78,
      0,567,569,3,62,31,0,568,567,1,0,0,0,568,569,1,0,0,0,569,570,1,0,0,
      0,570,571,5,6,0,0,571,572,3,156,78,0,572,574,1,0,0,0,573,550,1,0,0,
      0,573,562,1,0,0,0,574,61,1,0,0,0,575,576,5,7,0,0,576,578,3,156,78,
      0,577,575,1,0,0,0,578,581,1,0,0,0,579,577,1,0,0,0,579,580,1,0,0,0,
      580,582,1,0,0,0,581,579,1,0,0,0,582,583,3,64,32,0,583,591,3,156,78,
      0,584,585,5,7,0,0,585,587,3,156,78,0,586,588,3,64,32,0,587,586,1,0,
      0,0,587,588,1,0,0,0,588,590,1,0,0,0,589,584,1,0,0,0,590,593,1,0,0,
      0,591,589,1,0,0,0,591,592,1,0,0,0,592,63,1,0,0,0,593,591,1,0,0,0,594,
      595,3,58,29,0,595,596,5,9,0,0,596,597,3,156,78,0,597,599,3,70,35,0,
      598,600,3,66,33,0,599,598,1,0,0,0,599,600,1,0,0,0,600,607,1,0,0,0,
      601,602,3,58,29,0,602,603,5,9,0,0,603,604,3,156,78,0,604,605,3,68,
      34,0,605,607,1,0,0,0,606,594,1,0,0,0,606,601,1,0,0,0,607,65,1,0,0,
      0,608,609,5,28,0,0,609,610,3,156,78,0,610,67,1,0,0,0,611,616,3,88,
      44,0,612,616,3,94,47,0,613,614,5,59,0,0,614,616,3,156,78,0,615,611,
      1,0,0,0,615,612,1,0,0,0,615,613,1,0,0,0,616,617,1,0,0,0,617,615,1,
      0,0,0,617,618,1,0,0,0,618,69,1,0,0,0,619,626,3,72,36,0,620,622,3,56,
      28,0,621,620,1,0,0,0,621,622,1,0,0,0,622,623,1,0,0,0,623,625,3,72,
      36,0,624,621,1,0,0,0,625,628,1,0,0,0,626,624,1,0,0,0,626,627,1,0,0,
      0,627,71,1,0,0,0,628,626,1,0,0,0,629,630,3,80,40,0,630,631,3,156,78,
      0,631,657,1,0,0,0,632,633,3,82,41,0,633,634,3,156,78,0,634,657,1,0,
      0,0,635,636,3,84,42,0,636,637,3,156,78,0,637,657,1,0,0,0,638,639,5,
      44,0,0,639,657,3,156,78,0,640,641,5,31,0,0,641,657,3,156,78,0,642,
      643,3,154,77,0,643,644,3,156,78,0,644,657,1,0,0,0,645,657,3,118,59,
      0,646,647,3,116,58,0,647,648,3,156,78,0,648,657,1,0,0,0,649,657,3,
      78,39,0,650,657,3,120,60,0,651,657,3,74,37,0,652,653,3,86,43,0,653,
      654,3,156,78,0,654,657,1,0,0,0,655,657,3,76,38,0,656,629,1,0,0,0,656,
      632,1,0,0,0,656,635,1,0,0,0,656,638,1,0,0,0,656,640,1,0,0,0,656,642,
      1,0,0,0,656,645,1,0,0,0,656,646,1,0,0,0,656,649,1,0,0,0,656,650,1,
      0,0,0,656,651,1,0,0,0,656,652,1,0,0,0,656,655,1,0,0,0,657,73,1,0,0,
      0,658,659,5,63,0,0,659,660,3,156,78,0,660,661,3,70,35,0,661,662,5,
      4,0,0,662,663,3,156,78,0,663,75,1,0,0,0,664,665,5,58,0,0,665,666,3,
      156,78,0,666,667,3,70,35,0,667,668,5,4,0,0,668,669,3,156,78,0,669,
      77,1,0,0,0,670,671,5,22,0,0,671,672,3,156,78,0,672,79,1,0,0,0,673,
      675,7,3,0,0,674,673,1,0,0,0,674,675,1,0,0,0,675,676,1,0,0,0,676,677,
      5,43,0,0,677,81,1,0,0,0,678,680,7,3,0,0,679,678,1,0,0,0,679,680,1,
      0,0,0,680,681,1,0,0,0,681,682,5,29,0,0,682,83,1,0,0,0,683,685,7,3,
      0,0,684,683,1,0,0,0,684,685,1,0,0,0,685,686,1,0,0,0,686,687,5,35,0,
      0,687,85,1,0,0,0,688,690,7,3,0,0,689,688,1,0,0,0,689,690,1,0,0,0,690,
      691,1,0,0,0,691,692,5,36,0,0,692,87,1,0,0,0,693,694,3,154,77,0,694,
      695,3,156,78,0,695,760,1,0,0,0,696,697,3,80,40,0,697,698,3,156,78,
      0,698,760,1,0,0,0,699,700,3,82,41,0,700,701,3,156,78,0,701,760,1,0,
      0,0,702,703,3,84,42,0,703,704,3,156,78,0,704,760,1,0,0,0,705,706,3,
      86,43,0,706,707,3,156,78,0,707,760,1,0,0,0,708,709,5,44,0,0,709,760,
      3,156,78,0,710,711,3,116,58,0,711,712,3,156,78,0,712,760,1,0,0,0,713,
      714,5,22,0,0,714,760,3,156,78,0,715,716,5,31,0,0,716,760,3,156,78,
      0,717,718,5,20,0,0,718,760,3,156,78,0,719,720,5,21,0,0,720,760,3,156,
      78,0,721,722,5,9,0,0,722,760,3,156,78,0,723,724,5,63,0,0,724,729,3,
      156,78,0,725,728,3,88,44,0,726,728,3,92,46,0,727,725,1,0,0,0,727,726,
      1,0,0,0,728,731,1,0,0,0,729,727,1,0,0,0,729,730,1,0,0,0,730,732,1,
      0,0,0,731,729,1,0,0,0,732,733,5,4,0,0,733,734,3,156,78,0,734,760,1,
      0,0,0,735,736,5,3,0,0,736,741,3,156,78,0,737,740,3,88,44,0,738,740,
      3,92,46,0,739,737,1,0,0,0,739,738,1,0,0,0,740,743,1,0,0,0,741,739,
      1,0,0,0,741,742,1,0,0,0,742,744,1,0,0,0,743,741,1,0,0,0,744,745,5,
      4,0,0,745,746,3,156,78,0,746,760,1,0,0,0,747,748,5,1,0,0,748,753,3,
      156,78,0,749,752,3,88,44,0,750,752,3,92,46,0,751,749,1,0,0,0,751,750,
      1,0,0,0,752,755,1,0,0,0,753,751,1,0,0,0,753,754,1,0,0,0,754,756,1,
      0,0,0,755,753,1,0,0,0,756,757,5,2,0,0,757,758,3,156,78,0,758,760,1,
      0,0,0,759,693,1,0,0,0,759,696,1,0,0,0,759,699,1,0,0,0,759,702,1,0,
      0,0,759,705,1,0,0,0,759,708,1,0,0,0,759,710,1,0,0,0,759,713,1,0,0,
      0,759,715,1,0,0,0,759,717,1,0,0,0,759,719,1,0,0,0,759,721,1,0,0,0,
      759,723,1,0,0,0,759,735,1,0,0,0,759,747,1,0,0,0,760,89,1,0,0,0,761,
      762,5,59,0,0,762,766,3,156,78,0,763,765,3,88,44,0,764,763,1,0,0,0,
      765,768,1,0,0,0,766,764,1,0,0,0,766,767,1,0,0,0,767,772,1,0,0,0,768,
      766,1,0,0,0,769,773,3,94,47,0,770,771,5,7,0,0,771,773,3,156,78,0,772,
      769,1,0,0,0,772,770,1,0,0,0,773,91,1,0,0,0,774,784,3,94,47,0,775,776,
      5,59,0,0,776,784,3,156,78,0,777,778,5,7,0,0,778,784,3,156,78,0,779,
      780,5,18,0,0,780,784,3,156,78,0,781,782,5,19,0,0,782,784,3,156,78,
      0,783,774,1,0,0,0,783,775,1,0,0,0,783,777,1,0,0,0,783,779,1,0,0,0,
      783,781,1,0,0,0,784,93,1,0,0,0,785,786,5,5,0,0,786,797,3,156,78,0,
      787,796,3,62,31,0,788,796,3,96,48,0,789,796,3,88,44,0,790,796,3,94,
      47,0,791,792,5,59,0,0,792,796,3,156,78,0,793,794,5,7,0,0,794,796,3,
      156,78,0,795,787,1,0,0,0,795,788,1,0,0,0,795,789,1,0,0,0,795,790,1,
      0,0,0,795,791,1,0,0,0,795,793,1,0,0,0,796,799,1,0,0,0,797,795,1,0,
      0,0,797,798,1,0,0,0,798,800,1,0,0,0,799,797,1,0,0,0,800,801,5,6,0,
      0,801,802,3,156,78,0,802,95,1,0,0,0,803,814,3,60,30,0,804,814,3,10,
      5,0,805,814,3,22,11,0,806,814,3,128,64,0,807,814,3,132,66,0,808,814,
      3,100,50,0,809,814,3,138,69,0,810,814,3,140,70,0,811,814,3,142,71,
      0,812,814,3,90,45,0,813,803,1,0,0,0,813,804,1,0,0,0,813,805,1,0,0,
      0,813,806,1,0,0,0,813,807,1,0,0,0,813,808,1,0,0,0,813,809,1,0,0,0,
      813,810,1,0,0,0,813,811,1,0,0,0,813,812,1,0,0,0,814,97,1,0,0,0,815,
      816,5,5,0,0,816,820,3,156,78,0,817,819,3,96,48,0,818,817,1,0,0,0,819,
      822,1,0,0,0,820,818,1,0,0,0,820,821,1,0,0,0,821,823,1,0,0,0,822,820,
      1,0,0,0,823,824,5,6,0,0,824,825,3,156,78,0,825,99,1,0,0,0,826,827,
      5,49,0,0,827,828,3,156,78,0,828,829,3,102,51,0,829,830,3,156,78,0,
      830,831,3,98,49,0,831,101,1,0,0,0,832,837,3,106,53,0,833,837,3,108,
      54,0,834,837,3,110,55,0,835,837,3,104,52,0,836,832,1,0,0,0,836,833,
      1,0,0,0,836,834,1,0,0,0,836,835,1,0,0,0,837,103,1,0,0,0,838,839,5,
      3,0,0,839,840,3,156,78,0,840,841,3,102,51,0,841,842,3,156,78,0,842,
      843,5,4,0,0,843,847,1,0,0,0,844,847,3,112,56,0,845,847,3,114,57,0,
      846,838,1,0,0,0,846,844,1,0,0,0,846,845,1,0,0,0,847,105,1,0,0,0,848,
      849,5,33,0,0,849,850,3,156,78,0,850,851,5,17,0,0,851,852,3,156,78,
      0,852,853,3,104,52,0,853,107,1,0,0,0,854,864,3,104,52,0,855,856,3,
      156,78,0,856,857,5,17,0,0,857,858,3,156,78,0,858,859,5,34,0,0,859,
      860,3,156,78,0,860,861,5,17,0,0,861,862,3,156,78,0,862,863,3,104,52,
      0,863,865,1,0,0,0,864,855,1,0,0,0,865,866,1,0,0,0,866,864,1,0,0,0,
      866,867,1,0,0,0,867,109,1,0,0,0,868,878,3,104,52,0,869,870,3,156,78,
      0,870,871,5,17,0,0,871,872,3,156,78,0,872,873,5,50,0,0,873,874,3,156,
      78,0,874,875,5,17,0,0,875,876,3,156,78,0,876,877,3,104,52,0,877,879,
      1,0,0,0,878,869,1,0,0,0,879,880,1,0,0,0,880,878,1,0,0,0,880,881,1,
      0,0,0,881,111,1,0,0,0,882,883,5,3,0,0,883,884,3,156,78,0,884,885,3,
      64,32,0,885,886,5,4,0,0,886,113,1,0,0,0,887,892,7,4,0,0,888,891,3,
      88,44,0,889,891,3,92,46,0,890,888,1,0,0,0,890,889,1,0,0,0,891,894,
      1,0,0,0,892,890,1,0,0,0,892,893,1,0,0,0,893,895,1,0,0,0,894,892,1,
      0,0,0,895,896,5,4,0,0,896,115,1,0,0,0,897,898,5,30,0,0,898,899,3,156,
      78,0,899,900,5,44,0,0,900,901,3,156,78,0,901,902,5,4,0,0,902,905,1,
      0,0,0,903,905,5,16,0,0,904,897,1,0,0,0,904,903,1,0,0,0,905,117,1,0,
      0,0,906,907,5,61,0,0,907,908,3,156,78,0,908,909,5,60,0,0,909,910,3,
      156,78,0,910,911,5,4,0,0,911,912,3,156,78,0,912,119,1,0,0,0,913,914,
      5,54,0,0,914,915,3,156,78,0,915,916,3,122,61,0,916,917,5,4,0,0,917,
      918,3,156,78,0,918,121,1,0,0,0,919,930,3,124,62,0,920,921,5,17,0,0,
      921,922,3,156,78,0,922,923,7,3,0,0,923,924,3,156,78,0,924,925,5,17,
      0,0,925,926,3,156,78,0,926,927,3,124,62,0,927,929,1,0,0,0,928,920,
      1,0,0,0,929,932,1,0,0,0,930,928,1,0,0,0,930,931,1,0,0,0,931,123,1,
      0,0,0,932,930,1,0,0,0,933,945,3,126,63,0,934,935,5,11,0,0,935,936,
      3,156,78,0,936,937,3,126,63,0,937,944,1,0,0,0,938,939,5,12,0,0,939,
      940,3,156,78,0,940,941,3,80,40,0,941,942,3,156,78,0,942,944,1,0,0,
      0,943,934,1,0,0,0,943,938,1,0,0,0,944,947,1,0,0,0,945,943,1,0,0,0,
      945,946,1,0,0,0,946,125,1,0,0,0,947,945,1,0,0,0,948,949,3,80,40,0,
      949,950,3,156,78,0,950,967,1,0,0,0,951,952,3,84,42,0,952,953,3,156,
      78,0,953,967,1,0,0,0,954,955,3,86,43,0,955,956,3,156,78,0,956,967,
      1,0,0,0,957,958,3,82,41,0,958,959,3,156,78,0,959,967,1,0,0,0,960,961,
      5,3,0,0,961,962,3,156,78,0,962,963,3,122,61,0,963,964,5,4,0,0,964,
      965,3,156,78,0,965,967,1,0,0,0,966,948,1,0,0,0,966,951,1,0,0,0,966,
      954,1,0,0,0,966,957,1,0,0,0,966,960,1,0,0,0,967,127,1,0,0,0,968,969,
      5,48,0,0,969,970,3,156,78,0,970,971,5,5,0,0,971,973,3,156,78,0,972,
      974,3,130,65,0,973,972,1,0,0,0,973,974,1,0,0,0,974,982,1,0,0,0,975,
      976,5,7,0,0,976,978,3,156,78,0,977,979,3,130,65,0,978,977,1,0,0,0,
      978,979,1,0,0,0,979,981,1,0,0,0,980,975,1,0,0,0,981,984,1,0,0,0,982,
      980,1,0,0,0,982,983,1,0,0,0,983,985,1,0,0,0,984,982,1,0,0,0,985,986,
      5,6,0,0,986,987,3,156,78,0,987,129,1,0,0,0,988,989,3,58,29,0,989,990,
      5,9,0,0,990,991,3,156,78,0,991,992,3,70,35,0,992,999,1,0,0,0,993,994,
      3,58,29,0,994,995,5,9,0,0,995,996,3,156,78,0,996,997,3,68,34,0,997,
      999,1,0,0,0,998,988,1,0,0,0,998,993,1,0,0,0,999,131,1,0,0,0,1000,1001,
      5,51,0,0,1001,1002,3,156,78,0,1002,1003,5,17,0,0,1003,1004,3,156,78,
      0,1004,1005,3,154,77,0,1005,1006,3,156,78,0,1006,1007,5,5,0,0,1007,
      1011,3,156,78,0,1008,1010,3,134,67,0,1009,1008,1,0,0,0,1010,1013,1,
      0,0,0,1011,1009,1,0,0,0,1011,1012,1,0,0,0,1012,1014,1,0,0,0,1013,1011,
      1,0,0,0,1014,1015,5,6,0,0,1015,1016,3,156,78,0,1016,133,1,0,0,0,1017,
      1018,3,136,68,0,1018,1019,5,5,0,0,1019,1021,3,156,78,0,1020,1022,3,
      62,31,0,1021,1020,1,0,0,0,1021,1022,1,0,0,0,1022,1023,1,0,0,0,1023,
      1024,5,6,0,0,1024,1025,3,156,78,0,1025,135,1,0,0,0,1026,1027,7,5,0,
      0,1027,1035,3,156,78,0,1028,1029,5,40,0,0,1029,1030,3,156,78,0,1030,
      1031,7,5,0,0,1031,1032,3,156,78,0,1032,1034,1,0,0,0,1033,1028,1,0,
      0,0,1034,1037,1,0,0,0,1035,1033,1,0,0,0,1035,1036,1,0,0,0,1036,137,
      1,0,0,0,1037,1035,1,0,0,0,1038,1039,5,55,0,0,1039,1040,3,156,78,0,
      1040,1041,5,5,0,0,1041,1043,3,156,78,0,1042,1044,3,62,31,0,1043,1042,
      1,0,0,0,1043,1044,1,0,0,0,1044,1045,1,0,0,0,1045,1046,5,6,0,0,1046,
      1047,3,156,78,0,1047,139,1,0,0,0,1048,1049,5,56,0,0,1049,1050,3,156,
      78,0,1050,1051,3,154,77,0,1051,1052,3,156,78,0,1052,1053,5,5,0,0,1053,
      1055,3,156,78,0,1054,1056,3,62,31,0,1055,1054,1,0,0,0,1055,1056,1,
      0,0,0,1056,1057,1,0,0,0,1057,1058,5,6,0,0,1058,1059,3,156,78,0,1059,
      141,1,0,0,0,1060,1061,5,57,0,0,1061,1062,3,156,78,0,1062,1063,3,144,
      72,0,1063,1064,3,156,78,0,1064,1065,5,5,0,0,1065,1069,3,156,78,0,1066,
      1068,3,148,74,0,1067,1066,1,0,0,0,1068,1071,1,0,0,0,1069,1067,1,0,
      0,0,1069,1070,1,0,0,0,1070,1072,1,0,0,0,1071,1069,1,0,0,0,1072,1073,
      5,6,0,0,1073,1074,3,156,78,0,1074,143,1,0,0,0,1075,1083,3,146,73,0,
      1076,1077,3,156,78,0,1077,1078,5,40,0,0,1078,1079,3,156,78,0,1079,
      1080,3,146,73,0,1080,1082,1,0,0,0,1081,1076,1,0,0,0,1082,1085,1,0,
      0,0,1083,1081,1,0,0,0,1083,1084,1,0,0,0,1084,145,1,0,0,0,1085,1083,
      1,0,0,0,1086,1097,5,44,0,0,1087,1093,3,154,77,0,1088,1089,3,156,78,
      0,1089,1090,3,154,77,0,1090,1092,1,0,0,0,1091,1088,1,0,0,0,1092,1095,
      1,0,0,0,1093,1091,1,0,0,0,1093,1094,1,0,0,0,1094,1097,1,0,0,0,1095,
      1093,1,0,0,0,1096,1086,1,0,0,0,1096,1087,1,0,0,0,1097,147,1,0,0,0,
      1098,1099,3,150,75,0,1099,1100,3,156,78,0,1100,1101,5,5,0,0,1101,1103,
      3,156,78,0,1102,1104,3,152,76,0,1103,1102,1,0,0,0,1103,1104,1,0,0,
      0,1104,1113,1,0,0,0,1105,1106,3,156,78,0,1106,1107,5,7,0,0,1107,1109,
      3,156,78,0,1108,1110,3,152,76,0,1109,1108,1,0,0,0,1109,1110,1,0,0,
      0,1110,1112,1,0,0,0,1111,1105,1,0,0,0,1112,1115,1,0,0,0,1113,1111,
      1,0,0,0,1113,1114,1,0,0,0,1114,1116,1,0,0,0,1115,1113,1,0,0,0,1116,
      1117,5,6,0,0,1117,1118,3,156,78,0,1118,149,1,0,0,0,1119,1120,5,59,
      0,0,1120,151,1,0,0,0,1121,1122,3,154,77,0,1122,1123,3,156,78,0,1123,
      1124,5,9,0,0,1124,1125,3,156,78,0,1125,1131,3,80,40,0,1126,1127,3,
      156,78,0,1127,1128,3,80,40,0,1128,1130,1,0,0,0,1129,1126,1,0,0,0,1130,
      1133,1,0,0,0,1131,1129,1,0,0,0,1131,1132,1,0,0,0,1132,153,1,0,0,0,
      1133,1131,1,0,0,0,1134,1135,7,6,0,0,1135,155,1,0,0,0,1136,1138,7,7,
      0,0,1137,1136,1,0,0,0,1138,1141,1,0,0,0,1139,1137,1,0,0,0,1139,1140,
      1,0,0,0,1140,157,1,0,0,0,1141,1139,1,0,0,0,115,163,168,175,180,187,
      192,199,204,221,227,238,248,257,261,268,272,283,287,291,308,311,316,
      327,337,340,351,362,367,372,376,393,398,408,418,422,429,431,439,441,
      443,446,452,459,469,477,481,487,491,497,508,513,527,537,548,554,562,
      568,573,579,587,591,599,606,615,617,621,626,656,674,679,684,689,727,
      729,739,741,751,753,759,766,772,783,795,797,813,820,836,846,866,880,
      890,892,904,930,943,945,966,973,978,982,998,1011,1021,1035,1043,1055,
      1069,1083,1093,1096,1103,1109,1113,1131,1139
  ];

  static final ATN _ATN =
      ATNDeserializer().deserialize(_serializedATN);
}
class StylesheetContext extends ParserRuleContext {
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? EOF() => getToken(CSSParser.TOKEN_EOF, 0);
  List<CharsetContext> charsets() => getRuleContexts<CharsetContext>();
  CharsetContext? charset(int i) => getRuleContext<CharsetContext>(i);
  List<ImportsContext> importss() => getRuleContexts<ImportsContext>();
  ImportsContext? imports(int i) => getRuleContext<ImportsContext>(i);
  List<Namespace_Context> namespace_s() => getRuleContexts<Namespace_Context>();
  Namespace_Context? namespace_(int i) => getRuleContext<Namespace_Context>(i);
  List<NestedStatementContext> nestedStatements() => getRuleContexts<NestedStatementContext>();
  NestedStatementContext? nestedStatement(int i) => getRuleContext<NestedStatementContext>(i);
  List<TerminalNode> Comments() => getTokens(CSSParser.TOKEN_Comment);
  TerminalNode? Comment(int i) => getToken(CSSParser.TOKEN_Comment, i);
  List<TerminalNode> Spaces() => getTokens(CSSParser.TOKEN_Space);
  TerminalNode? Space(int i) => getToken(CSSParser.TOKEN_Space, i);
  List<TerminalNode> Cdos() => getTokens(CSSParser.TOKEN_Cdo);
  TerminalNode? Cdo(int i) => getToken(CSSParser.TOKEN_Cdo, i);
  List<TerminalNode> Cdcs() => getTokens(CSSParser.TOKEN_Cdc);
  TerminalNode? Cdc(int i) => getToken(CSSParser.TOKEN_Cdc, i);
  StylesheetContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_stylesheet;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitStylesheet(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CharsetContext extends ParserRuleContext {
  CharsetContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_charset;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class ImportsContext extends ParserRuleContext {
  ImportsContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_imports;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class Namespace_Context extends ParserRuleContext {
  Namespace_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_namespace_;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class NamespacePrefixContext extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  NamespacePrefixContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_namespacePrefix;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitNamespacePrefix(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaContext extends ParserRuleContext {
  TerminalNode? Media() => getToken(CSSParser.TOKEN_Media, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  MediaQueryListContext? mediaQueryList() => getRuleContext<MediaQueryListContext>(0);
  GroupRuleBodyContext? groupRuleBody() => getRuleContext<GroupRuleBodyContext>(0);
  MediaContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_media;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMedia(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaQueryListContext extends ParserRuleContext {
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<MediaQueryContext> mediaQuerys() => getRuleContexts<MediaQueryContext>();
  MediaQueryContext? mediaQuery(int i) => getRuleContext<MediaQueryContext>(i);
  List<TerminalNode> Commas() => getTokens(CSSParser.TOKEN_Comma);
  TerminalNode? Comma(int i) => getToken(CSSParser.TOKEN_Comma, i);
  MediaQueryListContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_mediaQueryList;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMediaQueryList(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaQueryContext extends ParserRuleContext {
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  MediaTypeContext? mediaType() => getRuleContext<MediaTypeContext>(0);
  List<TerminalNode> Ands() => getTokens(CSSParser.TOKEN_And);
  TerminalNode? And(int i) => getToken(CSSParser.TOKEN_And, i);
  List<MediaExpressionContext> mediaExpressions() => getRuleContexts<MediaExpressionContext>();
  MediaExpressionContext? mediaExpression(int i) => getRuleContext<MediaExpressionContext>(i);
  TerminalNode? MediaOnly() => getToken(CSSParser.TOKEN_MediaOnly, 0);
  TerminalNode? Not() => getToken(CSSParser.TOKEN_Not, 0);
  MediaQueryContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_mediaQuery;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMediaQuery(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaTypeContext extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  MediaTypeContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_mediaType;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMediaType(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaExpressionContext extends ParserRuleContext {
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  MediaFeatureContext? mediaFeature() => getRuleContext<MediaFeatureContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  ExprContext? expr() => getRuleContext<ExprContext>(0);
  MediaExpressionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_mediaExpression;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMediaExpression(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class MediaFeatureContext extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  MediaFeatureContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_mediaFeature;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitMediaFeature(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class PageContext extends ParserRuleContext {
  TerminalNode? Page() => getToken(CSSParser.TOKEN_Page, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  PseudoPageContext? pseudoPage() => getRuleContext<PseudoPageContext>(0);
  List<DeclarationContext> declarations() => getRuleContexts<DeclarationContext>();
  DeclarationContext? declaration(int i) => getRuleContext<DeclarationContext>(i);
  List<TerminalNode> SemiColons() => getTokens(CSSParser.TOKEN_SemiColon);
  TerminalNode? SemiColon(int i) => getToken(CSSParser.TOKEN_SemiColon, i);
  PageContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_page;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitPage(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class PseudoPageContext extends ParserRuleContext {
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  PseudoPageContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_pseudoPage;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitPseudoPage(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SelectorGroupContext extends ParserRuleContext {
  List<SelectorContext> selectors() => getRuleContexts<SelectorContext>();
  SelectorContext? selector(int i) => getRuleContext<SelectorContext>(i);
  List<TerminalNode> Commas() => getTokens(CSSParser.TOKEN_Comma);
  TerminalNode? Comma(int i) => getToken(CSSParser.TOKEN_Comma, i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  SelectorGroupContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_selectorGroup;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSelectorGroup(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SelectorContext extends ParserRuleContext {
  List<SimpleSelectorSequenceContext> simpleSelectorSequences() => getRuleContexts<SimpleSelectorSequenceContext>();
  SimpleSelectorSequenceContext? simpleSelectorSequence(int i) => getRuleContext<SimpleSelectorSequenceContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<CombinatorContext> combinators() => getRuleContexts<CombinatorContext>();
  CombinatorContext? combinator(int i) => getRuleContext<CombinatorContext>(i);
  SelectorContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_selector;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSelector(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CombinatorContext extends ParserRuleContext {
  TerminalNode? Plus() => getToken(CSSParser.TOKEN_Plus, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? Greater() => getToken(CSSParser.TOKEN_Greater, 0);
  TerminalNode? Tilde() => getToken(CSSParser.TOKEN_Tilde, 0);
  CombinatorContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_combinator;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCombinator(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SimpleSelectorSequenceContext extends ParserRuleContext {
  TypeSelectorContext? typeSelector() => getRuleContext<TypeSelectorContext>(0);
  UniversalContext? universal() => getRuleContext<UniversalContext>(0);
  List<TerminalNode> Hashs() => getTokens(CSSParser.TOKEN_Hash);
  TerminalNode? Hash(int i) => getToken(CSSParser.TOKEN_Hash, i);
  List<ClassNameContext> classNames() => getRuleContexts<ClassNameContext>();
  ClassNameContext? className(int i) => getRuleContext<ClassNameContext>(i);
  List<AttribContext> attribs() => getRuleContexts<AttribContext>();
  AttribContext? attrib(int i) => getRuleContext<AttribContext>(i);
  List<PseudoContext> pseudos() => getRuleContexts<PseudoContext>();
  PseudoContext? pseudo(int i) => getRuleContext<PseudoContext>(i);
  List<NegationContext> negations() => getRuleContexts<NegationContext>();
  NegationContext? negation(int i) => getRuleContext<NegationContext>(i);
  SimpleSelectorSequenceContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_simpleSelectorSequence;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSimpleSelectorSequence(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class TypeSelectorContext extends ParserRuleContext {
  ElementNameContext? elementName() => getRuleContext<ElementNameContext>(0);
  TypeNamespacePrefixContext? typeNamespacePrefix() => getRuleContext<TypeNamespacePrefixContext>(0);
  TypeSelectorContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_typeSelector;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitTypeSelector(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class TypeNamespacePrefixContext extends ParserRuleContext {
  TerminalNode? Pipe() => getToken(CSSParser.TOKEN_Pipe, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  TerminalNode? Multiply() => getToken(CSSParser.TOKEN_Multiply, 0);
  TypeNamespacePrefixContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_typeNamespacePrefix;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitTypeNamespacePrefix(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ElementNameContext extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  ElementNameContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_elementName;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitElementName(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class UniversalContext extends ParserRuleContext {
  TerminalNode? Multiply() => getToken(CSSParser.TOKEN_Multiply, 0);
  TypeNamespacePrefixContext? typeNamespacePrefix() => getRuleContext<TypeNamespacePrefixContext>(0);
  UniversalContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_universal;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUniversal(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ClassNameContext extends ParserRuleContext {
  TerminalNode? Dot() => getToken(CSSParser.TOKEN_Dot, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  ClassNameContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_className;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitClassName(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class AttribContext extends ParserRuleContext {
  TerminalNode? OpenBracket() => getToken(CSSParser.TOKEN_OpenBracket, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<IdentContext> idents() => getRuleContexts<IdentContext>();
  IdentContext? ident(int i) => getRuleContext<IdentContext>(i);
  TerminalNode? CloseBracket() => getToken(CSSParser.TOKEN_CloseBracket, 0);
  TypeNamespacePrefixContext? typeNamespacePrefix() => getRuleContext<TypeNamespacePrefixContext>(0);
  TerminalNode? PrefixMatch() => getToken(CSSParser.TOKEN_PrefixMatch, 0);
  TerminalNode? SuffixMatch() => getToken(CSSParser.TOKEN_SuffixMatch, 0);
  TerminalNode? SubstringMatch() => getToken(CSSParser.TOKEN_SubstringMatch, 0);
  TerminalNode? Equal() => getToken(CSSParser.TOKEN_Equal, 0);
  TerminalNode? Includes() => getToken(CSSParser.TOKEN_Includes, 0);
  TerminalNode? DashMatch() => getToken(CSSParser.TOKEN_DashMatch, 0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  AttribContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_attrib;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitAttrib(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class PseudoContext extends ParserRuleContext {
  List<TerminalNode> Colons() => getTokens(CSSParser.TOKEN_Colon);
  TerminalNode? Colon(int i) => getToken(CSSParser.TOKEN_Colon, i);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  FunctionalPseudoContext? functionalPseudo() => getRuleContext<FunctionalPseudoContext>(0);
  PseudoContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_pseudo;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitPseudo(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FunctionalPseudoContext extends ParserRuleContext {
  TerminalNode? Function_() => getToken(CSSParser.TOKEN_Function_, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  ExpressionContext? expression() => getRuleContext<ExpressionContext>(0);
  SelectorContext? selector() => getRuleContext<SelectorContext>(0);
  FunctionalPseudoContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_functionalPseudo;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFunctionalPseudo(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ExpressionContext extends ParserRuleContext {
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Pluss() => getTokens(CSSParser.TOKEN_Plus);
  TerminalNode? Plus(int i) => getToken(CSSParser.TOKEN_Plus, i);
  List<TerminalNode> Minuss() => getTokens(CSSParser.TOKEN_Minus);
  TerminalNode? Minus(int i) => getToken(CSSParser.TOKEN_Minus, i);
  List<TerminalNode> Dimensions() => getTokens(CSSParser.TOKEN_Dimension);
  TerminalNode? Dimension(int i) => getToken(CSSParser.TOKEN_Dimension, i);
  List<TerminalNode> UnknownDimensions() => getTokens(CSSParser.TOKEN_UnknownDimension);
  TerminalNode? UnknownDimension(int i) => getToken(CSSParser.TOKEN_UnknownDimension, i);
  List<TerminalNode> Numbers() => getTokens(CSSParser.TOKEN_Number);
  TerminalNode? Number(int i) => getToken(CSSParser.TOKEN_Number, i);
  List<TerminalNode> String_s() => getTokens(CSSParser.TOKEN_String_);
  TerminalNode? String_(int i) => getToken(CSSParser.TOKEN_String_, i);
  List<IdentContext> idents() => getRuleContexts<IdentContext>();
  IdentContext? ident(int i) => getRuleContext<IdentContext>(i);
  ExpressionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_expression;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitExpression(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class NegationContext extends ParserRuleContext {
  TerminalNode? PseudoNot() => getToken(CSSParser.TOKEN_PseudoNot, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  NegationArgContext? negationArg() => getRuleContext<NegationArgContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  NegationContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_negation;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitNegation(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class NegationArgContext extends ParserRuleContext {
  TypeSelectorContext? typeSelector() => getRuleContext<TypeSelectorContext>(0);
  UniversalContext? universal() => getRuleContext<UniversalContext>(0);
  TerminalNode? Hash() => getToken(CSSParser.TOKEN_Hash, 0);
  ClassNameContext? className() => getRuleContext<ClassNameContext>(0);
  AttribContext? attrib() => getRuleContext<AttribContext>(0);
  PseudoContext? pseudo() => getRuleContext<PseudoContext>(0);
  NegationArgContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_negationArg;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitNegationArg(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class Operator_Context extends ParserRuleContext {
  Operator_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_operator_;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class Property_Context extends ParserRuleContext {
  Property_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_property_;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class RulesetContext extends ParserRuleContext {
  RulesetContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_ruleset;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class DeclarationListContext extends ParserRuleContext {
  List<DeclarationContext> declarations() => getRuleContexts<DeclarationContext>();
  DeclarationContext? declaration(int i) => getRuleContext<DeclarationContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> SemiColons() => getTokens(CSSParser.TOKEN_SemiColon);
  TerminalNode? SemiColon(int i) => getToken(CSSParser.TOKEN_SemiColon, i);
  DeclarationListContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_declarationList;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitDeclarationList(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class DeclarationContext extends ParserRuleContext {
  DeclarationContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_declaration;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class PrioContext extends ParserRuleContext {
  TerminalNode? Important() => getToken(CSSParser.TOKEN_Important, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  PrioContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_prio;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitPrio(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ValueContext extends ParserRuleContext {
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  List<BlockContext> blocks() => getRuleContexts<BlockContext>();
  BlockContext? block(int i) => getRuleContext<BlockContext>(i);
  List<TerminalNode> AtKeywords() => getTokens(CSSParser.TOKEN_AtKeyword);
  TerminalNode? AtKeyword(int i) => getToken(CSSParser.TOKEN_AtKeyword, i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  ValueContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_value;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitValue(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ExprContext extends ParserRuleContext {
  List<TermContext> terms() => getRuleContexts<TermContext>();
  TermContext? term(int i) => getRuleContext<TermContext>(i);
  List<Operator_Context> operator_s() => getRuleContexts<Operator_Context>();
  Operator_Context? operator_(int i) => getRuleContext<Operator_Context>(i);
  ExprContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_expr;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitExpr(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class TermContext extends ParserRuleContext {
  TermContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_term;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class Function_Context extends ParserRuleContext {
  TerminalNode? Function_() => getToken(CSSParser.TOKEN_Function_, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  ExprContext? expr() => getRuleContext<ExprContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  Function_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_function_;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFunction_(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class DxImageTransformContext extends ParserRuleContext {
  TerminalNode? DxImageTransform() => getToken(CSSParser.TOKEN_DxImageTransform, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  ExprContext? expr() => getRuleContext<ExprContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  DxImageTransformContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_dxImageTransform;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitDxImageTransform(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class HexcolorContext extends ParserRuleContext {
  TerminalNode? Hash() => getToken(CSSParser.TOKEN_Hash, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  HexcolorContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_hexcolor;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitHexcolor(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class NumberContext extends ParserRuleContext {
  TerminalNode? Number() => getToken(CSSParser.TOKEN_Number, 0);
  TerminalNode? Plus() => getToken(CSSParser.TOKEN_Plus, 0);
  TerminalNode? Minus() => getToken(CSSParser.TOKEN_Minus, 0);
  NumberContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_number;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitNumber(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class PercentageContext extends ParserRuleContext {
  TerminalNode? Percentage() => getToken(CSSParser.TOKEN_Percentage, 0);
  TerminalNode? Plus() => getToken(CSSParser.TOKEN_Plus, 0);
  TerminalNode? Minus() => getToken(CSSParser.TOKEN_Minus, 0);
  PercentageContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_percentage;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitPercentage(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class DimensionContext extends ParserRuleContext {
  TerminalNode? Dimension() => getToken(CSSParser.TOKEN_Dimension, 0);
  TerminalNode? Plus() => getToken(CSSParser.TOKEN_Plus, 0);
  TerminalNode? Minus() => getToken(CSSParser.TOKEN_Minus, 0);
  DimensionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_dimension;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitDimension(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class UnknownDimensionContext extends ParserRuleContext {
  TerminalNode? UnknownDimension() => getToken(CSSParser.TOKEN_UnknownDimension, 0);
  TerminalNode? Plus() => getToken(CSSParser.TOKEN_Plus, 0);
  TerminalNode? Minus() => getToken(CSSParser.TOKEN_Minus, 0);
  UnknownDimensionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_unknownDimension;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownDimension(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class Any_Context extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  NumberContext? number() => getRuleContext<NumberContext>(0);
  PercentageContext? percentage() => getRuleContext<PercentageContext>(0);
  DimensionContext? dimension() => getRuleContext<DimensionContext>(0);
  UnknownDimensionContext? unknownDimension() => getRuleContext<UnknownDimensionContext>(0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  TerminalNode? Hash() => getToken(CSSParser.TOKEN_Hash, 0);
  TerminalNode? UnicodeRange() => getToken(CSSParser.TOKEN_UnicodeRange, 0);
  TerminalNode? Includes() => getToken(CSSParser.TOKEN_Includes, 0);
  TerminalNode? DashMatch() => getToken(CSSParser.TOKEN_DashMatch, 0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  TerminalNode? Function_() => getToken(CSSParser.TOKEN_Function_, 0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  List<UnusedContext> unuseds() => getRuleContexts<UnusedContext>();
  UnusedContext? unused(int i) => getRuleContext<UnusedContext>(i);
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  TerminalNode? OpenBracket() => getToken(CSSParser.TOKEN_OpenBracket, 0);
  TerminalNode? CloseBracket() => getToken(CSSParser.TOKEN_CloseBracket, 0);
  Any_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_any_;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitAny_(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class AtRuleContext extends ParserRuleContext {
  AtRuleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_atRule;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class UnusedContext extends ParserRuleContext {
  BlockContext? block() => getRuleContext<BlockContext>(0);
  TerminalNode? AtKeyword() => getToken(CSSParser.TOKEN_AtKeyword, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? SemiColon() => getToken(CSSParser.TOKEN_SemiColon, 0);
  TerminalNode? Cdo() => getToken(CSSParser.TOKEN_Cdo, 0);
  TerminalNode? Cdc() => getToken(CSSParser.TOKEN_Cdc, 0);
  UnusedContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_unused;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnused(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class BlockContext extends ParserRuleContext {
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<DeclarationListContext> declarationLists() => getRuleContexts<DeclarationListContext>();
  DeclarationListContext? declarationList(int i) => getRuleContext<DeclarationListContext>(i);
  List<NestedStatementContext> nestedStatements() => getRuleContexts<NestedStatementContext>();
  NestedStatementContext? nestedStatement(int i) => getRuleContext<NestedStatementContext>(i);
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  List<BlockContext> blocks() => getRuleContexts<BlockContext>();
  BlockContext? block(int i) => getRuleContext<BlockContext>(i);
  List<TerminalNode> AtKeywords() => getTokens(CSSParser.TOKEN_AtKeyword);
  TerminalNode? AtKeyword(int i) => getToken(CSSParser.TOKEN_AtKeyword, i);
  List<TerminalNode> SemiColons() => getTokens(CSSParser.TOKEN_SemiColon);
  TerminalNode? SemiColon(int i) => getToken(CSSParser.TOKEN_SemiColon, i);
  BlockContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_block;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBlock(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class NestedStatementContext extends ParserRuleContext {
  RulesetContext? ruleset() => getRuleContext<RulesetContext>(0);
  MediaContext? media() => getRuleContext<MediaContext>(0);
  PageContext? page() => getRuleContext<PageContext>(0);
  FontFaceRuleContext? fontFaceRule() => getRuleContext<FontFaceRuleContext>(0);
  KeyframesRuleContext? keyframesRule() => getRuleContext<KeyframesRuleContext>(0);
  SupportsRuleContext? supportsRule() => getRuleContext<SupportsRuleContext>(0);
  ViewportContext? viewport() => getRuleContext<ViewportContext>(0);
  CounterStyleContext? counterStyle() => getRuleContext<CounterStyleContext>(0);
  FontFeatureValuesRuleContext? fontFeatureValuesRule() => getRuleContext<FontFeatureValuesRuleContext>(0);
  AtRuleContext? atRule() => getRuleContext<AtRuleContext>(0);
  NestedStatementContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_nestedStatement;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitNestedStatement(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GroupRuleBodyContext extends ParserRuleContext {
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<NestedStatementContext> nestedStatements() => getRuleContexts<NestedStatementContext>();
  NestedStatementContext? nestedStatement(int i) => getRuleContext<NestedStatementContext>(i);
  GroupRuleBodyContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_groupRuleBody;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGroupRuleBody(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsRuleContext extends ParserRuleContext {
  TerminalNode? Supports() => getToken(CSSParser.TOKEN_Supports, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  SupportsConditionContext? supportsCondition() => getRuleContext<SupportsConditionContext>(0);
  GroupRuleBodyContext? groupRuleBody() => getRuleContext<GroupRuleBodyContext>(0);
  SupportsRuleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsRule;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsRule(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsConditionContext extends ParserRuleContext {
  SupportsNegationContext? supportsNegation() => getRuleContext<SupportsNegationContext>(0);
  SupportsConjunctionContext? supportsConjunction() => getRuleContext<SupportsConjunctionContext>(0);
  SupportsDisjunctionContext? supportsDisjunction() => getRuleContext<SupportsDisjunctionContext>(0);
  SupportsConditionInParensContext? supportsConditionInParens() => getRuleContext<SupportsConditionInParensContext>(0);
  SupportsConditionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsCondition;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsCondition(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsConditionInParensContext extends ParserRuleContext {
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  SupportsConditionContext? supportsCondition() => getRuleContext<SupportsConditionContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  SupportsDeclarationConditionContext? supportsDeclarationCondition() => getRuleContext<SupportsDeclarationConditionContext>(0);
  GeneralEnclosedContext? generalEnclosed() => getRuleContext<GeneralEnclosedContext>(0);
  SupportsConditionInParensContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsConditionInParens;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsConditionInParens(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsNegationContext extends ParserRuleContext {
  TerminalNode? Not() => getToken(CSSParser.TOKEN_Not, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? Space() => getToken(CSSParser.TOKEN_Space, 0);
  SupportsConditionInParensContext? supportsConditionInParens() => getRuleContext<SupportsConditionInParensContext>(0);
  SupportsNegationContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsNegation;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsNegation(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsConjunctionContext extends ParserRuleContext {
  List<SupportsConditionInParensContext> supportsConditionInParenss() => getRuleContexts<SupportsConditionInParensContext>();
  SupportsConditionInParensContext? supportsConditionInParens(int i) => getRuleContext<SupportsConditionInParensContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Spaces() => getTokens(CSSParser.TOKEN_Space);
  TerminalNode? Space(int i) => getToken(CSSParser.TOKEN_Space, i);
  List<TerminalNode> Ands() => getTokens(CSSParser.TOKEN_And);
  TerminalNode? And(int i) => getToken(CSSParser.TOKEN_And, i);
  SupportsConjunctionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsConjunction;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsConjunction(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsDisjunctionContext extends ParserRuleContext {
  List<SupportsConditionInParensContext> supportsConditionInParenss() => getRuleContexts<SupportsConditionInParensContext>();
  SupportsConditionInParensContext? supportsConditionInParens(int i) => getRuleContext<SupportsConditionInParensContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Spaces() => getTokens(CSSParser.TOKEN_Space);
  TerminalNode? Space(int i) => getToken(CSSParser.TOKEN_Space, i);
  List<TerminalNode> Ors() => getTokens(CSSParser.TOKEN_Or);
  TerminalNode? Or(int i) => getToken(CSSParser.TOKEN_Or, i);
  SupportsDisjunctionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsDisjunction;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsDisjunction(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class SupportsDeclarationConditionContext extends ParserRuleContext {
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  DeclarationContext? declaration() => getRuleContext<DeclarationContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  SupportsDeclarationConditionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_supportsDeclarationCondition;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitSupportsDeclarationCondition(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GeneralEnclosedContext extends ParserRuleContext {
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  TerminalNode? Function_() => getToken(CSSParser.TOKEN_Function_, 0);
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  List<UnusedContext> unuseds() => getRuleContexts<UnusedContext>();
  UnusedContext? unused(int i) => getRuleContext<UnusedContext>(i);
  GeneralEnclosedContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_generalEnclosed;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGeneralEnclosed(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class UrlContext extends ParserRuleContext {
  TerminalNode? Url_() => getToken(CSSParser.TOKEN_Url_, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  TerminalNode? Url() => getToken(CSSParser.TOKEN_Url, 0);
  UrlContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_url;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUrl(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class Var_Context extends ParserRuleContext {
  TerminalNode? Var() => getToken(CSSParser.TOKEN_Var, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? Variable() => getToken(CSSParser.TOKEN_Variable, 0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  Var_Context([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_var_;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitVar_(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CalcContext extends ParserRuleContext {
  TerminalNode? Calc() => getToken(CSSParser.TOKEN_Calc, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  CalcSumContext? calcSum() => getRuleContext<CalcSumContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  CalcContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_calc;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCalc(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CalcSumContext extends ParserRuleContext {
  List<CalcProductContext> calcProducts() => getRuleContexts<CalcProductContext>();
  CalcProductContext? calcProduct(int i) => getRuleContext<CalcProductContext>(i);
  List<TerminalNode> Spaces() => getTokens(CSSParser.TOKEN_Space);
  TerminalNode? Space(int i) => getToken(CSSParser.TOKEN_Space, i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Pluss() => getTokens(CSSParser.TOKEN_Plus);
  TerminalNode? Plus(int i) => getToken(CSSParser.TOKEN_Plus, i);
  List<TerminalNode> Minuss() => getTokens(CSSParser.TOKEN_Minus);
  TerminalNode? Minus(int i) => getToken(CSSParser.TOKEN_Minus, i);
  CalcSumContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_calcSum;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCalcSum(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CalcProductContext extends ParserRuleContext {
  List<CalcValueContext> calcValues() => getRuleContexts<CalcValueContext>();
  CalcValueContext? calcValue(int i) => getRuleContext<CalcValueContext>(i);
  List<TerminalNode> Multiplys() => getTokens(CSSParser.TOKEN_Multiply);
  TerminalNode? Multiply(int i) => getToken(CSSParser.TOKEN_Multiply, i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Divides() => getTokens(CSSParser.TOKEN_Divide);
  TerminalNode? Divide(int i) => getToken(CSSParser.TOKEN_Divide, i);
  List<NumberContext> numbers() => getRuleContexts<NumberContext>();
  NumberContext? number(int i) => getRuleContext<NumberContext>(i);
  CalcProductContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_calcProduct;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCalcProduct(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CalcValueContext extends ParserRuleContext {
  NumberContext? number() => getRuleContext<NumberContext>(0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  DimensionContext? dimension() => getRuleContext<DimensionContext>(0);
  UnknownDimensionContext? unknownDimension() => getRuleContext<UnknownDimensionContext>(0);
  PercentageContext? percentage() => getRuleContext<PercentageContext>(0);
  TerminalNode? OpenParen() => getToken(CSSParser.TOKEN_OpenParen, 0);
  CalcSumContext? calcSum() => getRuleContext<CalcSumContext>(0);
  TerminalNode? CloseParen() => getToken(CSSParser.TOKEN_CloseParen, 0);
  CalcValueContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_calcValue;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCalcValue(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FontFaceRuleContext extends ParserRuleContext {
  TerminalNode? FontFace() => getToken(CSSParser.TOKEN_FontFace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<FontFaceDeclarationContext> fontFaceDeclarations() => getRuleContexts<FontFaceDeclarationContext>();
  FontFaceDeclarationContext? fontFaceDeclaration(int i) => getRuleContext<FontFaceDeclarationContext>(i);
  List<TerminalNode> SemiColons() => getTokens(CSSParser.TOKEN_SemiColon);
  TerminalNode? SemiColon(int i) => getToken(CSSParser.TOKEN_SemiColon, i);
  FontFaceRuleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_fontFaceRule;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFontFaceRule(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FontFaceDeclarationContext extends ParserRuleContext {
  FontFaceDeclarationContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_fontFaceDeclaration;
 
  @override
  void copyFrom(ParserRuleContext ctx) {
    super.copyFrom(ctx);
  }
}

class KeyframesRuleContext extends ParserRuleContext {
  TerminalNode? Keyframes() => getToken(CSSParser.TOKEN_Keyframes, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? Space() => getToken(CSSParser.TOKEN_Space, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<KeyframeBlockContext> keyframeBlocks() => getRuleContexts<KeyframeBlockContext>();
  KeyframeBlockContext? keyframeBlock(int i) => getRuleContext<KeyframeBlockContext>(i);
  KeyframesRuleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_keyframesRule;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKeyframesRule(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class KeyframeBlockContext extends ParserRuleContext {
  KeyframeSelectorContext? keyframeSelector() => getRuleContext<KeyframeSelectorContext>(0);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  DeclarationListContext? declarationList() => getRuleContext<DeclarationListContext>(0);
  KeyframeBlockContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_keyframeBlock;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKeyframeBlock(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class KeyframeSelectorContext extends ParserRuleContext {
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Froms() => getTokens(CSSParser.TOKEN_From);
  TerminalNode? From(int i) => getToken(CSSParser.TOKEN_From, i);
  List<TerminalNode> Tos() => getTokens(CSSParser.TOKEN_To);
  TerminalNode? To(int i) => getToken(CSSParser.TOKEN_To, i);
  List<TerminalNode> Percentages() => getTokens(CSSParser.TOKEN_Percentage);
  TerminalNode? Percentage(int i) => getToken(CSSParser.TOKEN_Percentage, i);
  List<TerminalNode> Commas() => getTokens(CSSParser.TOKEN_Comma);
  TerminalNode? Comma(int i) => getToken(CSSParser.TOKEN_Comma, i);
  KeyframeSelectorContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_keyframeSelector;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKeyframeSelector(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class ViewportContext extends ParserRuleContext {
  TerminalNode? Viewport() => getToken(CSSParser.TOKEN_Viewport, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  DeclarationListContext? declarationList() => getRuleContext<DeclarationListContext>(0);
  ViewportContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_viewport;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitViewport(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class CounterStyleContext extends ParserRuleContext {
  TerminalNode? CounterStyle() => getToken(CSSParser.TOKEN_CounterStyle, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  DeclarationListContext? declarationList() => getRuleContext<DeclarationListContext>(0);
  CounterStyleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_counterStyle;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitCounterStyle(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FontFeatureValuesRuleContext extends ParserRuleContext {
  TerminalNode? FontFeatureValues() => getToken(CSSParser.TOKEN_FontFeatureValues, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  FontFamilyNameListContext? fontFamilyNameList() => getRuleContext<FontFamilyNameListContext>(0);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<FeatureValueBlockContext> featureValueBlocks() => getRuleContexts<FeatureValueBlockContext>();
  FeatureValueBlockContext? featureValueBlock(int i) => getRuleContext<FeatureValueBlockContext>(i);
  FontFeatureValuesRuleContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_fontFeatureValuesRule;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFontFeatureValuesRule(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FontFamilyNameListContext extends ParserRuleContext {
  List<FontFamilyNameContext> fontFamilyNames() => getRuleContexts<FontFamilyNameContext>();
  FontFamilyNameContext? fontFamilyName(int i) => getRuleContext<FontFamilyNameContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  List<TerminalNode> Commas() => getTokens(CSSParser.TOKEN_Comma);
  TerminalNode? Comma(int i) => getToken(CSSParser.TOKEN_Comma, i);
  FontFamilyNameListContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_fontFamilyNameList;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFontFamilyNameList(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FontFamilyNameContext extends ParserRuleContext {
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  List<IdentContext> idents() => getRuleContexts<IdentContext>();
  IdentContext? ident(int i) => getRuleContext<IdentContext>(i);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  FontFamilyNameContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_fontFamilyName;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFontFamilyName(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FeatureValueBlockContext extends ParserRuleContext {
  FeatureTypeContext? featureType() => getRuleContext<FeatureTypeContext>(0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<FeatureValueDefinitionContext> featureValueDefinitions() => getRuleContexts<FeatureValueDefinitionContext>();
  FeatureValueDefinitionContext? featureValueDefinition(int i) => getRuleContext<FeatureValueDefinitionContext>(i);
  List<TerminalNode> SemiColons() => getTokens(CSSParser.TOKEN_SemiColon);
  TerminalNode? SemiColon(int i) => getToken(CSSParser.TOKEN_SemiColon, i);
  FeatureValueBlockContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_featureValueBlock;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFeatureValueBlock(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FeatureTypeContext extends ParserRuleContext {
  TerminalNode? AtKeyword() => getToken(CSSParser.TOKEN_AtKeyword, 0);
  FeatureTypeContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_featureType;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFeatureType(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class FeatureValueDefinitionContext extends ParserRuleContext {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  List<NumberContext> numbers() => getRuleContexts<NumberContext>();
  NumberContext? number(int i) => getRuleContext<NumberContext>(i);
  FeatureValueDefinitionContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_featureValueDefinition;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitFeatureValueDefinition(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class IdentContext extends ParserRuleContext {
  TerminalNode? Ident() => getToken(CSSParser.TOKEN_Ident, 0);
  TerminalNode? MediaOnly() => getToken(CSSParser.TOKEN_MediaOnly, 0);
  TerminalNode? Not() => getToken(CSSParser.TOKEN_Not, 0);
  TerminalNode? And() => getToken(CSSParser.TOKEN_And, 0);
  TerminalNode? Or() => getToken(CSSParser.TOKEN_Or, 0);
  TerminalNode? From() => getToken(CSSParser.TOKEN_From, 0);
  TerminalNode? To() => getToken(CSSParser.TOKEN_To, 0);
  IdentContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_ident;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitIdent(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class WsContext extends ParserRuleContext {
  List<TerminalNode> Comments() => getTokens(CSSParser.TOKEN_Comment);
  TerminalNode? Comment(int i) => getToken(CSSParser.TOKEN_Comment, i);
  List<TerminalNode> Spaces() => getTokens(CSSParser.TOKEN_Space);
  TerminalNode? Space(int i) => getToken(CSSParser.TOKEN_Space, i);
  WsContext([ParserRuleContext? parent, int? invokingState]) : super(parent, invokingState);
  @override
  int get ruleIndex => RULE_ws;
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitWs(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class BadCharsetContext extends CharsetContext {
  TerminalNode? Charset() => getToken(CSSParser.TOKEN_Charset, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  BadCharsetContext(CharsetContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadCharset(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GoodCharsetContext extends CharsetContext {
  TerminalNode? Charset() => getToken(CSSParser.TOKEN_Charset, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  TerminalNode? SemiColon() => getToken(CSSParser.TOKEN_SemiColon, 0);
  GoodCharsetContext(CharsetContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGoodCharset(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class BadImportContext extends ImportsContext {
  TerminalNode? Import() => getToken(CSSParser.TOKEN_Import, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  MediaQueryListContext? mediaQueryList() => getRuleContext<MediaQueryListContext>(0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  BadImportContext(ImportsContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadImport(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GoodImportContext extends ImportsContext {
  TerminalNode? Import() => getToken(CSSParser.TOKEN_Import, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  MediaQueryListContext? mediaQueryList() => getRuleContext<MediaQueryListContext>(0);
  TerminalNode? SemiColon() => getToken(CSSParser.TOKEN_SemiColon, 0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  GoodImportContext(ImportsContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGoodImport(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class GoodNamespaceContext extends Namespace_Context {
  TerminalNode? Namespace() => getToken(CSSParser.TOKEN_Namespace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? SemiColon() => getToken(CSSParser.TOKEN_SemiColon, 0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  NamespacePrefixContext? namespacePrefix() => getRuleContext<NamespacePrefixContext>(0);
  GoodNamespaceContext(Namespace_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGoodNamespace(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class BadNamespaceContext extends Namespace_Context {
  TerminalNode? Namespace() => getToken(CSSParser.TOKEN_Namespace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  NamespacePrefixContext? namespacePrefix() => getRuleContext<NamespacePrefixContext>(0);
  BadNamespaceContext(Namespace_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadNamespace(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class BadOperatorContext extends Operator_Context {
  TerminalNode? Equal() => getToken(CSSParser.TOKEN_Equal, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  BadOperatorContext(Operator_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadOperator(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GoodOperatorContext extends Operator_Context {
  TerminalNode? Divide() => getToken(CSSParser.TOKEN_Divide, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? Comma() => getToken(CSSParser.TOKEN_Comma, 0);
  TerminalNode? Space() => getToken(CSSParser.TOKEN_Space, 0);
  GoodOperatorContext(Operator_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGoodOperator(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class BadPropertyContext extends Property_Context {
  TerminalNode? Multiply() => getToken(CSSParser.TOKEN_Multiply, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  TerminalNode? Underscore() => getToken(CSSParser.TOKEN_Underscore, 0);
  BadPropertyContext(Property_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadProperty(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class GoodPropertyContext extends Property_Context {
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  TerminalNode? Variable() => getToken(CSSParser.TOKEN_Variable, 0);
  GoodPropertyContext(Property_Context ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitGoodProperty(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class UnknownRulesetContext extends RulesetContext {
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  DeclarationListContext? declarationList() => getRuleContext<DeclarationListContext>(0);
  UnknownRulesetContext(RulesetContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownRuleset(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class KnownRulesetContext extends RulesetContext {
  SelectorGroupContext? selectorGroup() => getRuleContext<SelectorGroupContext>(0);
  TerminalNode? OpenBrace() => getToken(CSSParser.TOKEN_OpenBrace, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  TerminalNode? CloseBrace() => getToken(CSSParser.TOKEN_CloseBrace, 0);
  DeclarationListContext? declarationList() => getRuleContext<DeclarationListContext>(0);
  KnownRulesetContext(RulesetContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKnownRuleset(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class UnknownDeclarationContext extends DeclarationContext {
  Property_Context? property_() => getRuleContext<Property_Context>(0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  ValueContext? value() => getRuleContext<ValueContext>(0);
  UnknownDeclarationContext(DeclarationContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownDeclaration(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class KnownDeclarationContext extends DeclarationContext {
  Property_Context? property_() => getRuleContext<Property_Context>(0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  ExprContext? expr() => getRuleContext<ExprContext>(0);
  PrioContext? prio() => getRuleContext<PrioContext>(0);
  KnownDeclarationContext(DeclarationContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKnownDeclaration(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class BadTermContext extends TermContext {
  DxImageTransformContext? dxImageTransform() => getRuleContext<DxImageTransformContext>(0);
  BadTermContext(TermContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitBadTerm(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class KnownTermContext extends TermContext {
  NumberContext? number() => getRuleContext<NumberContext>(0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  PercentageContext? percentage() => getRuleContext<PercentageContext>(0);
  DimensionContext? dimension() => getRuleContext<DimensionContext>(0);
  TerminalNode? String_() => getToken(CSSParser.TOKEN_String_, 0);
  TerminalNode? UnicodeRange() => getToken(CSSParser.TOKEN_UnicodeRange, 0);
  IdentContext? ident() => getRuleContext<IdentContext>(0);
  Var_Context? var_() => getRuleContext<Var_Context>(0);
  UrlContext? url() => getRuleContext<UrlContext>(0);
  HexcolorContext? hexcolor() => getRuleContext<HexcolorContext>(0);
  CalcContext? calc() => getRuleContext<CalcContext>(0);
  Function_Context? function_() => getRuleContext<Function_Context>(0);
  KnownTermContext(TermContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKnownTerm(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class UnknownTermContext extends TermContext {
  UnknownDimensionContext? unknownDimension() => getRuleContext<UnknownDimensionContext>(0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  UnknownTermContext(TermContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownTerm(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class UnknownAtRuleContext extends AtRuleContext {
  TerminalNode? AtKeyword() => getToken(CSSParser.TOKEN_AtKeyword, 0);
  List<WsContext> wss() => getRuleContexts<WsContext>();
  WsContext? ws(int i) => getRuleContext<WsContext>(i);
  BlockContext? block() => getRuleContext<BlockContext>(0);
  TerminalNode? SemiColon() => getToken(CSSParser.TOKEN_SemiColon, 0);
  List<Any_Context> any_s() => getRuleContexts<Any_Context>();
  Any_Context? any_(int i) => getRuleContext<Any_Context>(i);
  UnknownAtRuleContext(AtRuleContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownAtRule(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}class KnownFontFaceDeclarationContext extends FontFaceDeclarationContext {
  Property_Context? property_() => getRuleContext<Property_Context>(0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  ExprContext? expr() => getRuleContext<ExprContext>(0);
  KnownFontFaceDeclarationContext(FontFaceDeclarationContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitKnownFontFaceDeclaration(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}

class UnknownFontFaceDeclarationContext extends FontFaceDeclarationContext {
  Property_Context? property_() => getRuleContext<Property_Context>(0);
  TerminalNode? Colon() => getToken(CSSParser.TOKEN_Colon, 0);
  WsContext? ws() => getRuleContext<WsContext>(0);
  ValueContext? value() => getRuleContext<ValueContext>(0);
  UnknownFontFaceDeclarationContext(FontFaceDeclarationContext ctx) { copyFrom(ctx); }
  @override
  T? accept<T>(ParseTreeVisitor<T> visitor) {
    if (visitor is CSSParserVisitor<T>) {
     return visitor.visitUnknownFontFaceDeclaration(this);
    } else {
    	return visitor.visitChildren(this);
    }
  }
}