import 'package:d4rt/d4rt.dart';
import 'bridge_cast.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/m_manga.dart';
import 'package:eclipse_mangayomi_dart_runtime/eval/model/m_pages.dart';

class MPagesBridge {
  final mPageBridgedClass = BridgedClass(
    nativeType: MPages,
    name: 'MPages',
    constructors: {
      '': (visitor, positionalArgs, namedArgs) {
        return MPages(
          list: asBridgedList<MManga>(positionalArgs[0], 'MPages.list') ?? [],
          hasNextPage: positionalArgs[1] as bool,
        );
      },
    },
    getters: {
      'list': (visitor, target) => (target as MPages).list,
      'hasNextPage': (visitor, target) => (target as MPages).hasNextPage,
    },
    setters: {
      'list': (visitor, target, value) =>
          (target as MPages).list = asBridgedList<MManga>(value, 'MPages.list') ?? [],
      'hasNextPage': (visitor, target, value) =>
          (target as MPages).hasNextPage = value as bool,
    },
  );
  void registerBridgedClasses(D4rt interpreter) {
    interpreter.registerBridgedClass(
      mPageBridgedClass,
      'package:mangayomi/bridge_lib.dart',
    );
  }
}
