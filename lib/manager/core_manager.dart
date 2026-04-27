import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;

  const CoreManager({super.key, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    coreEventManager.addListener(this);
    ref.listenManual(
      currentSetupStateProvider.select((state) => state?.profileId),
      (prev, next) {
        if (prev != next) {
          appController.fullSetup();
        }
      },
    );
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        appController.updateConfigDebounce();
      }
    });
    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (next) {
        coreController.startLog();
      } else {
        coreController.stopLog();
      }
    }, fireImmediately: true);
  }

  @override
  Future<void> dispose() async {
    coreEventManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    appController.setDelay(delay);
    throttler.call(
      FunctionTag.updateDelay,
      () {
        appController.updateGroupsDebounce(const Duration(milliseconds: 150));
      },
      duration: const Duration(milliseconds: 300),
      fire: true,
    );
  }

  @override
  void onLog(Log log) {
    var processedLog = log;
    if (log.payload.contains('[DNS]')) {
      processedLog = log.copyWith(logLevel: LogLevel.dns);
    }
    final currentLogLevel = appController.config.patchClashConfig.logLevel;
    if (currentLogLevel == LogLevel.dns) {
      if (processedLog.logLevel != LogLevel.dns) {
        return;
      }
    } else {
      if (processedLog.logLevel == LogLevel.dns) {
        return;
      }
    }
    ref.read(logsProvider.notifier).addLog(processedLog);
    if (processedLog.logLevel == LogLevel.error) {
      globalState.showNotifier(processedLog.payload);
    }
    super.onLog(processedLog);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    super.onRequest(trackerInfo);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    ref
        .read(providersProvider.notifier)
        .setProvider(await coreController.getExternalProvider(providerName));
    debouncer.call(FunctionTag.loadedProvider, () async {
      appController.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 1000));
    super.onLoaded(providerName);
  }

  @override
  Future<void> onCrash(String message) async {
    final currentStatus = ref.read(coreStatusProvider);
    commonPrint.log(
      '[CoreManager] onCrash() message="$message", currentStatus=$currentStatus',
    );
    final isStart = ref.read(isStartProvider);
    if (currentStatus != CoreStatus.connected && !isStart) {
      commonPrint.log('[CoreManager] onCrash() ignored, not connected');
      return;
    }
    await appController.handleUnexpectedStop(message: message);
    super.onCrash(message);
  }
}
