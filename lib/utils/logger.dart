import 'dart:developer' as developer;

/// Logs a message to the console.
///
/// This function logs a message with a specific name and the current timestamp.
///
/// [message] The message to be logged.
void log(String message) {
  developer.log(
    message,
    name: 'OGGCAFConverter',
    time: DateTime.now(),
  );
}
