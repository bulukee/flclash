import 'dart:async';

import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MembershipService extends SalmonService {
  final started = Completer<void>();
  final response = Completer<void>();

  @override
  Future<Map<String, dynamic>> fetchUserInfo({
    bool forceRefresh = false,
  }) async {
    started.complete();
    await response.future;
    return {'plan_id': 1, 'email': 'old@example.com'};
  }

  @override
  Future<Map<String, dynamic>> fetchSubscribeInfo({
    bool forceRefresh = false,
  }) async {
    await response.future;
    return {'plan_id': 1, 'subscribe_url': 'https://old.example.com/sub'};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPlans({
    bool forceRefresh = false,
  }) async {
    await response.future;
    return [
      {'id': 1, 'name': 'old-plan'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchOrders({
    bool forceRefresh = false,
  }) async {
    await response.future;
    return [];
  }
}

void main() {
  test(
    'late membership sync cannot restore account data after logout',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://old.example.com',
        'salmon_auth_data': 'old-token',
      });
      final service = _MembershipService();
      final pending = service.refreshMembershipData();
      final expectation = expectLater(
        pending,
        throwsA(isA<SalmonSessionExpiredException>()),
      );
      await service.started.future;
      await service.clear();
      service.response.complete();
      await expectation;
      expect(salmonAccountCache, isNull);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'salmon_subscribe_url',
        ),
        isNull,
      );
      expect(service.membershipRevision.value, 0);
    },
  );

  test(
    'late membership sync cannot overwrite a new account subscription',
    () async {
      SharedPreferences.setMockInitialValues({
        'salmon_base_url': 'https://old.example.com',
        'salmon_auth_data': 'old-token',
      });
      final service = _MembershipService();
      final pending = service.refreshMembershipData();
      final expectation = expectLater(
        pending,
        throwsA(isA<SalmonSessionExpiredException>()),
      );
      await service.started.future;
      await service.clear();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('salmon_base_url', 'https://new.example.com');
      await preferences.setString('salmon_auth_data', 'new-token');
      await preferences.setString(
        'salmon_subscribe_url',
        'https://new.example.com/sub',
      );
      salmonAccountCache = {'email': 'new@example.com'};
      service.response.complete();
      await expectation;
      expect(salmonAccountCache?['email'], 'new@example.com');
      expect(
        preferences.getString('salmon_subscribe_url'),
        'https://new.example.com/sub',
      );
      expect(service.membershipRevision.value, 0);
      await service.clear();
    },
  );
}
