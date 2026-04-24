import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:animations/animations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'database/database.dart';
import 'l10n/l10n.dart';
import 'models/models.dart';

typedef UpdateTasks = List<FutureOr Function()>;

class GlobalState {
  static const serviceStartupGraceDuration = Duration(seconds: 5);
  static const serviceHealthFailureThreshold = 2;
  static GlobalState? _instance;
  final navigatorKey = GlobalKey<NavigatorState>();
  Timer? timer;
  bool _isExecutingUpdateTasks = false;
  bool _updateTasksEnabled = false;
  bool isPre = true;
  late final String coreSHA256;
  late final PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  bool needInitStatus = true;
  CorePalette? corePalette;
  DateTime? startTime;
  DateTime? _serviceStartRequestedAt;
  int _runTimeFailureCount = 0;
  int _trafficFailureCount = 0;
  bool _hasSuccessfulRuntimeSync = false;
  UpdateTasks tasks = [];
  SetupState? lastSetupState;
  VpnState? lastVpnState;

  bool get isStart => startTime != null && startTime!.isBeforeNow;
  bool get isWithinServiceStartupGrace =>
      _serviceStartRequestedAt != null &&
      DateTime.now().difference(_serviceStartRequestedAt!) <
          serviceStartupGraceDuration;
  bool get hasSuccessfulRuntimeSync => _hasSuccessfulRuntimeSync;

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  Future<ProviderContainer> init(int version) async {
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    await _initDynamicColor();
    return await _initData(version);
  }

  Future<void> _initDynamicColor() async {
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ??
          Color(defaultPrimaryColor);
    } catch (_) {}
  }

  Future<ProviderContainer> _initData(int version) async {
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    packageInfo = await PackageInfo.fromPlatform();
    final configMap = await preferences.getConfigMap();
    final config = await migration.migrationIfNeeded(
      configMap,
      sync: (data) async {
        final newConfigMap = data.configMap;
        final config = Config.realFromJson(newConfigMap);
        await Future.wait([
          database.restore(data.profiles, data.scripts, data.rules, data.links),
          preferences.saveConfig(config),
        ]);
        return config;
      },
    );
    final configOverrides = buildConfigOverrides(config);
    final container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    final profiles = await database.profilesDao.all().get();
    container.read(profilesProvider.notifier).setAndReorder(profiles);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    await window?.init(version, config.windowProps);
    return container;
  }

  Future<void> startUpdateTasks([UpdateTasks? tasks]) async {
    if (tasks != null) {
      this.tasks = tasks;
    }
    if (this.tasks.isEmpty) {
      return;
    }
    _updateTasksEnabled = true;
    if (timer?.isActive == true || _isExecutingUpdateTasks) return;
    _isExecutingUpdateTasks = true;
    try {
      await executorUpdateTask();
    } finally {
      _isExecutingUpdateTasks = false;
    }
    if (!_updateTasksEnabled || this.tasks.isEmpty || timer?.isActive == true) {
      return;
    }
    timer = Timer(const Duration(seconds: 1), () async {
      startUpdateTasks();
    });
  }

  Future<void> executorUpdateTask() async {
    timer = null;
    for (final task in tasks) {
      if (!_updateTasksEnabled) {
        break;
      }
      try {
        await task();
      } catch (e, s) {
        commonPrint.log('Update task error: $e, $s');
      }
    }
  }

  void stopUpdateTasks() {
    _updateTasksEnabled = false;
    if (timer == null || timer?.isActive == false) return;
    timer?.cancel();
    timer = null;
  }

  void markServiceStartRequested() {
    _serviceStartRequestedAt = DateTime.now();
    _runTimeFailureCount = 0;
    _trafficFailureCount = 0;
    _hasSuccessfulRuntimeSync = false;
  }

  void markRuntimeSyncSuccess() {
    _runTimeFailureCount = 0;
    _hasSuccessfulRuntimeSync = true;
  }

  void markTrafficSyncSuccess() {
    _trafficFailureCount = 0;
  }

  bool registerRuntimeSyncFailure() {
    _runTimeFailureCount += 1;
    if (isWithinServiceStartupGrace) {
      return false;
    }
    return _runTimeFailureCount >= serviceHealthFailureThreshold;
  }

  bool registerTrafficSyncFailure() {
    _trafficFailureCount += 1;
    if (!_hasSuccessfulRuntimeSync || isWithinServiceStartupGrace) {
      return false;
    }
    return _trafficFailureCount >= serviceHealthFailureThreshold;
  }

  void resetServiceHealthTracking() {
    _serviceStartRequestedAt = null;
    _runTimeFailureCount = 0;
    _trafficFailureCount = 0;
    _hasSuccessfulRuntimeSync = false;
  }

  Future<bool> handleStart([UpdateTasks? tasks]) async {
    await coreController.startListener();
    final started = await service?.start() ?? true;
    if (!started) {
      startTime = null;
      resetServiceHealthTracking();
      await coreController.stopListener();
      stopUpdateTasks();
      return false;
    }
    markServiceStartRequested();
    final serviceStartTime = await service?.getRunTime();
    startTime = serviceStartTime ?? DateTime.now();
    if (serviceStartTime != null) {
      markRuntimeSyncSuccess();
    }
    startUpdateTasks(tasks);
    return true;
  }

  Future updateStartTime() async {
    startTime = await service?.getRunTime();
    if (startTime != null) {
      markRuntimeSyncSuccess();
    }
  }

  Future handleStop() async {
    startTime = null;
    resetServiceHealthTracking();
    await coreController.stopListener();
    await service?.stop();
    stopUpdateTasks();
  }

  Future<bool?> showMessage({
    required InlineSpan message,
    BuildContext? context,
    String? title,
    String? confirmText,
    String? cancelText,
    bool cancelable = true,
    bool? dismissible,
  }) async {
    return await showCommonDialog<bool>(
      context: context,
      dismissible: dismissible,
      child: Builder(
        builder: (context) {
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(cancelText ?? appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                  style: const TextStyle(overflow: TextOverflow.visible),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool?> showAllUpdatingMessagesDialog(
    List<UpdatingMessage> messages,
  ) async {
    return await showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          return CommonDialog(
            padding: EdgeInsets.zero,
            title: appLocalizations.tip,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(appLocalizations.confirm),
              ),
            ],
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                itemBuilder: (_, index) {
                  final message = messages[index];
                  return ListItem(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    title: Text(message.label),
                    subtitle: Text(message.message),
                  );
                },
                itemCount: messages.length,
                separatorBuilder: (_, _) => Divider(height: 0),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    BuildContext? context,
    bool? dismissible,
    bool filter = true,
  }) async {
    return await showModal<T>(
      useRootNavigator: false,
      context: context ?? globalState.navigatorKey.currentContext!,
      configuration: FadeScaleTransitionConfiguration(
        barrierColor: Colors.black38,
        barrierDismissible: dismissible ?? true,
      ),
      builder: (_) => child,
      filter: filter ? commonFilter : null,
    );
  }

  void showNotifier(String text, {MessageActionState? actionState}) {
    if (text.isEmpty) {
      return;
    }
    navigatorKey.currentContext?.showNotifier(text, actionState: actionState);
  }

  Future<void> openUrl(String url) async {
    final res = await showMessage(
      message: TextSpan(text: url),
      title: appLocalizations.externalLink,
      confirmText: appLocalizations.go,
    );
    if (res != true) {
      return;
    }
    launchUrl(Uri.parse(url));
  }

  Future<Map<String, dynamic>> handleEvaluate(
    String scriptContent,
    Map<String, dynamic> config,
  ) async {
    if (config['proxy-providers'] == null) {
      config['proxy-providers'] = {};
    }
    final configJs = json.encode(config);
    final runtime = getJavascriptRuntime();
    final res = await runtime.evaluateAsync('''
      $scriptContent
      main($configJs)
    ''');
    if (res.isError) {
      throw res.stringResult;
    }
    final value = switch (res.rawResult is ffi.Pointer) {
      true => runtime.convertValue<Map<String, dynamic>>(res),
      false => Map<String, dynamic>.from(res.rawResult),
    };
    return value ?? config;
  }
}

final globalState = GlobalState();
