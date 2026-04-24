import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controller.dart';
import 'pages/pages.dart';

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;
  // Tracks whether VPN was auto-started by our logic;
  // only then do we auto-stop it on network change.
  bool _autoStartedVpn = false;

  final _pageTransitionsTheme = const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: commonSharedXPageTransitions,
      TargetPlatform.windows: commonSharedXPageTransitions,
      TargetPlatform.linux: commonSharedXPageTransitions,
      TargetPlatform.macOS: commonSharedXPageTransitions,
    },
  );

  ColorScheme _getAppColorScheme({
    required Brightness brightness,
    int? primaryColor,
  }) {
    return ref.read(genColorSchemeProvider(brightness));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      final currentContext = globalState.navigatorKey.currentContext;
      if (currentContext != null) {
        await appController.attach(currentContext, ref);
      } else {
        exit(0);
      }
      await _syncCurrentConnectivity();
      _autoUpdateProfilesTask();
      appController.initLink();
      app?.initShortcuts();
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await appController.autoUpdateProfiles();
      _autoUpdateProfilesTask();
    });
  }

  Widget _buildPlatformState({required Widget child}) {
    if (system.isDesktop) {
      return WindowManager(
        child: TrayManager(
          child: HotKeyManager(child: ProxyManager(child: child)),
        ),
      );
    }
    return AndroidManager(child: TileManager(child: child));
  }

  Widget _buildState({required Widget child}) {
    return AppStateManager(
      child: CoreManager(
        child: ConnectivityManager(
          onConnectivityChanged: _handleConnectivityChanged,
          child: child,
        ),
      ),
    );
  }

  Future<void> _syncCurrentConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      await _handleConnectivityChanged(results);
    } catch (e) {
      commonPrint.log('syncCurrentConnectivity error: $e');
    }
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    commonPrint.log('connectivityChanged ${results.toString()}');
    await appController.updateLocalIp();
    final hasVpn = results.contains(ConnectivityResult.vpn);
    if (_preHasVpn == hasVpn) {
      appController.addCheckIp();
    }
    _preHasVpn = hasVpn;

    if (system.isAndroid) {
      await _handleNetworkAutoControl(results);
    }
  }

  Future<void> _handleNetworkAutoControl(
    List<ConnectivityResult> results,
  ) async {
    final appSetting = ref.read(appSettingProvider);
    final autoStartOnMobile = appSetting.autoStartOnMobileData;
    final autoStopOnWifi = appSetting.autoStopOnSpecificWifi;

    if (!autoStartOnMobile && !autoStopOnWifi) return;

    final hasMobile = results.contains(ConnectivityResult.mobile);
    final hasWifi = results.contains(ConnectivityResult.wifi);
    final isStart = appController.isStart;

    // If VPN was stopped externally/manually, reset the flag
    if (!isStart) _autoStartedVpn = false;

    // Priority 1: Check if connected to a specific Gateway that should auto-stop VPN
    if (autoStopOnWifi && hasWifi) {
      final gatewayList = appSetting.autoStopGatewayList;
      if (gatewayList.isNotEmpty) {
        _checkAndStopGateway(gatewayList);
      }
    }

    // Priority 2: Auto-start VPN when on mobile only (no WiFi)
    if (autoStartOnMobile) {
      if (hasMobile && !hasWifi) {
        if (appController.disableMobileAutoStartUntilRestart) {
          commonPrint.log(
            'Auto start skipped: disabled for this session after manual stop',
          );
          return;
        }
        if (!isStart) {
          commonPrint.log(
            'Auto starting VPN: mobile data active, no WiFi. Waiting 1s for stability...',
          );
          await Future.delayed(const Duration(seconds: 1));
          final currentResults = await Connectivity().checkConnectivity();
          if (currentResults.contains(ConnectivityResult.mobile) &&
              !currentResults.contains(ConnectivityResult.wifi)) {
            commonPrint.log('Auto starting VPN: conditions still met, starting now');
            _autoStartedVpn = true;
            await appController.updateStatus(true);
          } else {
            commonPrint.log('Auto start cancelled: network conditions changed during delay');
          }
        }
        // If VPN is already on, nothing to do (handles WiFi→Mobile switch correctly)
      } else if (!hasMobile && !hasWifi) {
        // No mobile AND no WiFi — only stop VPN if we auto-started it
        if (isStart && _autoStartedVpn) {
          commonPrint.log('Auto stopping VPN: no network (we auto-started it)');
          _autoStartedVpn = false;
          await appController.updateStatus(false);
        }
      }
    }
  }

  Future<void> _checkAndStopGateway(List<String> gatewayList) async {
    for (int i = 0; i < 4; i++) {
      // Retry up to 4 times for DHCP assignment to complete
      try {
        // Use native Android ConnectivityManager — no location permission needed
        final gatewayIP = await app?.getWifiGatewayIP();
        if (gatewayIP != null &&
            gatewayIP.isNotEmpty &&
            gatewayIP != '0.0.0.0') {
          if (gatewayList.contains(gatewayIP)) {
            if (appController.isStart) {
              commonPrint.log(
                'Auto stopping VPN: connected to specific Gateway "$gatewayIP"',
              );
              await appController.updateStatus(false);
            }
          }
          return; // Successfully resolved, stop retrying
        }
      } catch (e) {
        commonPrint.log(
          'Failed to get WiFi Gateway IP (native) on retry $i: $e',
        );
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Widget _buildPlatformApp({required Widget child}) {
    if (system.isDesktop) {
      return WindowHeaderContainer(child: child);
    }
    return VpnManager(child: child);
  }

  Widget _buildApp({required Widget child}) {
    return StatusManager(child: ThemeManager(child: child));
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (_, child) {
            return AppEnvManager(
              child: _buildApp(
                child: _buildPlatformState(
                  child: _buildState(child: _buildPlatformApp(child: child!)),
                ),
              ),
            );
          },
          scrollBehavior: BaseScrollBehavior(),
          title: appName,
          locale: utils.getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            pageTransitionsTheme: _pageTransitionsTheme,
            colorScheme: _getAppColorScheme(
              brightness: Brightness.light,
              primaryColor: themeProps.primaryColor,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            pageTransitionsTheme: _pageTransitionsTheme,
            colorScheme: _getAppColorScheme(
              brightness: Brightness.dark,
              primaryColor: themeProps.primaryColor,
            ).toPureBlack(themeProps.pureBlack),
          ),
          home: child!,
        );
      },
      child: const HomePage(),
    );
  }

  @override
  Future<void> dispose() async {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    await coreController.destroy();
    await appController.handleExit();
    super.dispose();
  }
}
