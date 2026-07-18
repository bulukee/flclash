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
import 'package:fl_clash/services/salmon_update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/pages.dart';

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;

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
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF245CFF),
      brightness: brightness,
    ).copyWith(
      primary: const Color(0xFF245CFF),
      secondary: const Color(0xFF00BCEB),
      tertiary: const Color(0xFF755BFF),
      error: const Color(0xFFE5484D),
      surface: const Color(0xFFFFFFFF),
      onSurface: const Color(0xFF10233F),
      outline: const Color(0xFFD8E3F3),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await globalState.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _initLink();
      app?.initShortcuts();
      if (mounted) {
        await Future<void>.delayed(const Duration(seconds: 3));
        final updateContext = globalState.navigatorKey.currentContext;
        if (mounted && updateContext != null && updateContext.mounted) {
          await SalmonUpdateService.checkAndPrompt(updateContext);
        }
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      final res = await globalState.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: currentAppLocalizations.doYouWantToPass),
            TextSpan(
              text: ' $url ',
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            TextSpan(text: currentAppLocalizations.createProfile),
          ],
        ),
      );
      if (res != true) return;
      ref.read(profilesActionProvider.notifier).addProfileFormURL(url);
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
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
          onConnectivityChanged: (results) async {
            commonPrint.log('connectivityChanged ${results.toString()}');
            ref.read(systemActionProvider.notifier).updateLocalIp();
            final hasVpn = results.contains(ConnectivityResult.vpn);
            if (_preHasVpn == hasVpn) {
              ref.read(checkIpNumProvider.notifier).add();
            }
            _preHasVpn = hasVpn;
          },
          child: child,
        ),
      ),
    );
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
          themeMode: ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            pageTransitionsTheme: _pageTransitionsTheme,
            scaffoldBackgroundColor: const Color(0xFFF3F6FC),
            colorScheme: _getAppColorScheme(
              brightness: Brightness.light,
              primaryColor: 0xFF2F6BFF,
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF3F6FC),
              surfaceTintColor: Colors.transparent,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: Color(0xFF10233F),
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            iconTheme: const IconThemeData(color: Color(0xFF29476F)),
            dividerTheme: const DividerThemeData(
              color: Color(0xFFD8E3F3),
              thickness: 1,
              space: 1,
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: const Color(0xFFFFFFFF),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
              titleTextStyle: const TextStyle(
                color: Color(0xFF10233F),
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            bottomSheetTheme: const BottomSheetThemeData(
              backgroundColor: Color(0xFFFFFFFF),
              surfaceTintColor: Colors.transparent,
              modalBackgroundColor: Color(0xFFFFFFFF),
              modalBarrierColor: Color(0x520B1730),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              showDragHandle: true,
              dragHandleColor: Color(0xFF9EB1CF),
            ),
            progressIndicatorTheme: const ProgressIndicatorThemeData(
              color: Color(0xFF245CFF),
              linearTrackColor: Color(0xFFDCE7FA),
              circularTrackColor: Color(0xFFDCE7FA),
            ),
            cardTheme: CardThemeData(
              elevation: 0,
              color: const Color(0xFFFFFFFF),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: const Color(0xFFFAFCFF),
              indicatorColor: const Color(0xFFE2EBFF),
              height: 72,
              labelTextStyle: WidgetStateProperty.all(
                const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF405777),
                ),
              ),
            ),
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF173D82),
              contentTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
              elevation: 3,
              insetPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFF4D7DFF)),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFFFFFFF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: Color(0xFFD8E3F3)),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
              ),
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
      child: const SalmonGate(child: HomePage()),
    );
  }

  @override
  Future<void> dispose() async {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    await coreController.destroy();
    await ref.read(systemActionProvider.notifier).handleExit();
    super.dispose();
  }
}
