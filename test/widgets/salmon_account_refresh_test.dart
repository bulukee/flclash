import 'dart:async';

import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:fl_clash/views/account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends SalmonService {
  bool fail = false;
  int generation = 0;
  Completer<Map<String, dynamic>>? pendingUser;

  @override
  int get sessionGeneration => generation;

  @override
  Future<Map<String, dynamic>> fetchUserInfo({
    bool forceRefresh = false,
  }) async {
    if (fail) throw StateError('账户加载失败');
    return pendingUser == null ? {'plan_id': 1} : pendingUser!.future;
  }

  @override
  Future<Map<String, dynamic>> fetchSubscribeInfo({
    bool forceRefresh = false,
  }) async => {'plan_id': 1};

  @override
  Future<List<Map<String, dynamic>>> fetchPlans({
    bool forceRefresh = false,
  }) async => [
    {'id': 1, 'name': '测试套餐'},
  ];

  @override
  Future<Map<String, dynamic>> fetchInvites({bool forceRefresh = false}) async {
    if (fail) throw StateError('邀请加载失败');
    return {'codes': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> fetchCommissionConfig({
    bool forceRefresh = false,
  }) async => {};

  @override
  Future<String> fetchInvitationUrl({bool forceRefresh = false}) async =>
      'https://invite.example.com/register';
}

Future<void> _open(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    salmonAccountCache = null;
    salmonAccountCacheAt = null;
  });
  tearDown(() {
    salmonAccountCache = null;
    salmonAccountCacheAt = null;
  });

  testWidgets('account load errors stop loading and retry can recover', (
    tester,
  ) async {
    final service = _Service()..fail = true;
    await _open(tester, AccountView(service: service));
    await tester.pumpAndSettle();
    expect(find.text('账户加载失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    service.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(salmonAccountCache?['plan_name'], '测试套餐');
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final disposed in [false, true]) {
    testWidgets(
      'late account results cannot repopulate cache after ${disposed ? 'dispose' : 'account change'}',
      (tester) async {
        final user = Completer<Map<String, dynamic>>();
        final service = _Service()..pendingUser = user;
        await _open(tester, AccountView(service: service));
        if (disposed) {
          await tester.pumpWidget(const SizedBox());
        } else {
          service.generation++;
        }
        user.complete({'plan_id': 1});
        await tester.pumpAndSettle();
        expect(salmonAccountCache, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('invitation retry and refresh do not return Future to setState', (
    tester,
  ) async {
    final service = _Service()..fail = true;
    await _open(tester, InvitationPage(service: service));
    await tester.pumpAndSettle();
    service.fail = false;
    await tester.tap(find.text('重新获取'));
    await tester.pumpAndSettle();
    expect(find.text('重新获取'), findsNothing);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
