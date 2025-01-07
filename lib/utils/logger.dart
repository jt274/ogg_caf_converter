import 'dart:developer' as developer;

/// Logs a message to the console.
void log(String message) {
  developer.log(
    message,
    name: 'OGGCAFConverter',
    time: DateTime.now(),
  );
}
