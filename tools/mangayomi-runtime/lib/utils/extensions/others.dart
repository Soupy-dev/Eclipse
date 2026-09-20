extension LetExtension<T> on T { R let<R>(R Function(T) block) => block(this); }
