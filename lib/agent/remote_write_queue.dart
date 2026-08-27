import 'dart:async';

import 'agent_loop.dart';

/// Serializes state-changing operations for one remote target.
///
/// A cancelled operation that is still waiting behind an earlier write is
/// rejected when its turn arrives, so it cannot become a late remote side
/// effect after the task has already stopped.
class RemoteWriteQueue {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(
    String leaseKey,
    Future<T> Function() operation, {
    required AgentCancellation cancellation,
  }) {
    final previous = _tails[leaseKey] ?? Future<void>.value();
    late Future<T> current;
    current = previous.then<T>((_) {
      if (cancellation.isCancelled) {
        throw StateError('Remote write cancelled before execution.');
      }
      return operation();
    });
    final settled = current.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _tails[leaseKey] = settled;
    unawaited(
      settled.then<void>((_) {
        if (identical(_tails[leaseKey], settled)) _tails.remove(leaseKey);
      }),
    );
    return current;
  }
}
