extension StringMapConversion on Map {
  Map<String, String> get toMapStringString => map((key, value) => MapEntry(key.toString(), value.toString()));
  Map<String, dynamic> get toMapStringDynamic => map((key, value) => MapEntry(key.toString(), value));
}
