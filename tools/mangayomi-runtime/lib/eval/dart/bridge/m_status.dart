import 'package:d4rt/d4rt.dart';
import 'package:eclipse_mangayomi_dart_runtime/models/manga.dart';

class MStatusBridge {
  final statusDefinition = BridgedEnumDefinition<Status>(
    name: 'MStatus',
    values: Status.values,
  );
  void registerBridgedEnum(D4rt interpreter) {
    interpreter.registerBridgedEnum(
      statusDefinition,
      'package:mangayomi/bridge_lib.dart',
    );
  }
}
