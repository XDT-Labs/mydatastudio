import 'package:rxdart/rxdart.dart';

/// C = invoking Command
/// R = Result Type
class RxService<C, R> {
  late BehaviorSubject<C> _source;
  late BehaviorSubject<R> _sink;
  late BehaviorSubject<bool> _isLoading;

  RxService() {
    _isLoading = BehaviorSubject<bool>.seeded(false);
    _source = BehaviorSubject<C>();
    _sink = BehaviorSubject<R>();

    _source.listen((value) => invoke(value));
  }

  BehaviorSubject<bool> get isLoading => _isLoading;
  BehaviorSubject<C> get source => _source;
  BehaviorSubject<R> get sink => _sink;

  /// support direct invocation to get immediate value while at the same time
  /// putting the value in a Stream for any other listeners.
  Future<R> invoke(C command) async => throw UnimplementedError();
  Future<R?> invokeOrNull(C command) async => throw UnimplementedError();

  /// Reset the service streams, closing old subjects and initializing new ones.
  void reset() {
    _source.close();
    _sink.close();
    _isLoading.close();
    _isLoading = BehaviorSubject<bool>.seeded(false);
    _source = BehaviorSubject<C>();
    _sink = BehaviorSubject<R>();
    _source.listen((value) => invoke(value));
  }
}

abstract class RxCommand {}
