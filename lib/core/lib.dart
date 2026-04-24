import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/plugins/service.dart';

import 'interface.dart';

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  Completer<bool> _connectedCompleter = Completer();

  CoreLib._internal();

  @override
  Future<String> preload() async {
    commonPrint.log('[CoreLib] preload() start');
    if (service == null) {
      commonPrint.log('[CoreLib] preload() service is null!');
      return 'Service not available';
    }
    commonPrint.log('[CoreLib] preload() calling service.init()...');
    final res = await service!.init();
    commonPrint.log('[CoreLib] preload() init result: "$res"');
    if (res.isNotEmpty) {
      commonPrint.log('[CoreLib] preload() init failed with: "$res"');
      return res;
    }
    if (!_connectedCompleter.isCompleted) {
      _connectedCompleter.complete(true);
      commonPrint.log('[CoreLib] preload() completer completed');
    }
    commonPrint.log('[CoreLib] preload() calling syncState...');
    final syncRes = await service!.syncState(appController.sharedState);
    commonPrint.log('[CoreLib] preload() syncState result: "$syncRes"');
    return syncRes;
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  @override
  destroy() async {
    return true;
  }

  @override
  Future<bool> shutdown(_) async {
    commonPrint.log('[CoreLib] shutdown() called, completer.isCompleted=${_connectedCompleter.isCompleted}');
    if (!_connectedCompleter.isCompleted) {
      return false;
    }
    _connectedCompleter = Completer();
    return service?.shutdown() ?? true;
  }

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    final id = '${method.name}#${utils.id}';
    final result = await service
        ?.invokeAction(Action(id: id, method: method, data: data))
        .withTimeout(onTimeout: () => null);
    if (result == null) {
      return null;
    }
    return parasResult<T>(result);
  }

  @override
  Completer get completer => _connectedCompleter;
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
