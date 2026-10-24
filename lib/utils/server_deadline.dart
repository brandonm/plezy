import 'dart:async';

import '../exceptions/media_server_exceptions.dart';
import 'media_server_http_client.dart';

/// Whether [error] is a client-side abort (client teardown mid-request)
/// rather than a genuine server failure. Cross-server callers report these
/// servers as cancelled, so a *disrupted* pass — whose results say nothing
/// about actual content — is told apart from a settled failure.
bool isClientCancellation(Object error) => error is MediaServerHttpException && error.isCancellation;

/// Runs one server's leg of a fan-out under [deadline]. The legs' results
/// are shown together, so without a bound one server that accepted the
/// connection and then stopped answering would hold back every other
/// server's results for its whole HTTP budget.
///
/// [run] gets its own [AbortController], aborted with [parent] and on
/// expiry. Expiry fails the leg as a timeout — a failure, not a
/// cancellation ([isClientCancellation] is false for it) — and drops
/// whatever arrives later. A backend call that takes no abort keeps its
/// request running to the HTTP layer's own budget.
Future<R> withinServerDeadline<R>(
  Duration deadline, {
  required String operation,
  AbortController? parent,
  required Future<R> Function(AbortController abort) run,
}) {
  final leg = AbortController();
  if (parent != null) unawaited(parent.trigger.then((_) => leg.abort()));
  return run(leg).timeout(
    deadline,
    onTimeout: () {
      leg.abort();
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.connectionTimeout,
        message: '$operation exceeded its ${deadline.inSeconds}s budget',
      );
    },
  );
}
