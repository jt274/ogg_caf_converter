import 'dart:developer' as developer;

void log(String message) {
  developer.log(
    message,
    name: 'OGGCAFConverter',
    time: DateTime.now(),
  );
}
