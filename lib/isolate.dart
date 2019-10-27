import 'dart:async';
import 'dart:isolate';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:worker_manager/task.dart';

import 'isolate_bundle.dart';

mixin IsolateFlags {
  //flags
  bool isBusy = false;
  bool isInitialized = false;
  var initializationCompleter = Completer<bool>();
  String taskId = '';

  //data bridges
  Isolate _isolate;
  SendPort _sendPort;
  ReceivePort _receivePort;
  var _resultCompleter = Completer<Result>();
}

abstract class WorkerIsolate with IsolateFlags {
  void initPortConnection();

  Stream<Result> work({@required Task task});

  void cancel();

  factory WorkerIsolate() => _Worker();
}

class _Worker with IsolateFlags implements WorkerIsolate {
  @override
  void initPortConnection() {
    _receivePort = ReceivePort();
    Isolate.spawn(_handleWithPorts, _receivePort.sendPort).then((isolate) {
      _isolate = isolate;
      _receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          initializationCompleter.complete(true);
          isInitialized = true;
        } else {
          if (taskId != '') {
            final resultFromIsolate = message as Result;
            resultFromIsolate is ErrorResult
                ? _resultCompleter.complete(Result.error(resultFromIsolate.asError.error))
                : _resultCompleter.complete(Result.value(resultFromIsolate.asValue.value));
            taskId = '';
            isBusy = false;
          }
          _resultCompleter = null;
        }
      });
    });
  }

  @override
  Stream<Result> work({@required Task task}) {
    isBusy = true;
    taskId = task.id;
    _resultCompleter = Completer<Result>();
    _sendPort
        .send(IsolateBundle(function: task.function, bundle: task.bundle, timeout: task.timeout));
    return Stream.fromFuture(_resultCompleter.future);
  }

  @override
  void cancel() {
    taskId = '';
    isInitialized = false;
    initializationCompleter.future.then((_) {
      _isolate.kill(priority: Isolate.immediate);
      _isolate = null;
      _sendPort = null;
      _receivePort = null;
      isBusy = false;
      initializationCompleter = Completer<bool>();
      initPortConnection();
    });
  }

  static void _handleWithPorts(SendPort sendPort) async {
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);
    await for (IsolateBundle isolateBundle in receivePort) {
      final function = isolateBundle.function;
      final bundle = isolateBundle.bundle;
      final timeout = isolateBundle.timeout;
      Result result;
      Future execute() async => Future.microtask(() async {
            return await Future.delayed(Duration(microseconds: 0), () async {
              return Result.value(bundle == null ? await function() : await function(bundle));
            });
          });
      try {
        result = timeout != null
            ? await execute().timeout(timeout, onTimeout: () {
                throw TimeoutException;
              })
            : await execute();
      } catch (error) {
        result = Result.error(error);
      }
      try {
        sendPort.send(result);
      } catch (_) {
        sendPort.send(Result.error('isolate error: ${(result as ErrorResult).error.toString()}'));
      }
    }
  }
}