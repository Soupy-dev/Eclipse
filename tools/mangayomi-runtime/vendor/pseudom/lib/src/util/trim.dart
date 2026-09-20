String trimLeft(String from, String pattern) {
  if (from.isEmpty || pattern.isEmpty || pattern.length > from.length)
    return from;

  while (from.startsWith(pattern)) {
    from = from.substring(pattern.length);
  }
  return from;
}

String trimRight(String from, String pattern) {
  if (from.isEmpty || pattern.isEmpty || pattern.length > from.length)
    return from;

  while (from.endsWith(pattern)) {
    from = from.substring(0, from.length - pattern.length);
  }
  return from;
}

T trim<T extends String?>(T from, String pattern) {
  if (from == null) {
    return from;
  }
  return trimLeft(trimRight(from, pattern), pattern) as dynamic;
}
