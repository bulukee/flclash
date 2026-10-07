import 'package:fl_clash/services/salmon_traffic_reset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts calendar days to an explicit reset date', () {
    expect(
      salmonTrafficResetDays({
        'reset_date': '2026-11-07',
      }, currentTime: DateTime(2026, 10, 7, 23)),
      31,
    );
  });

  test('reset_day is the remaining number of days, not a day of month', () {
    expect(
      salmonTrafficResetDays({
        'reset_day': 31,
      }, currentTime: DateTime(2026, 2, 28, 12)),
      31,
    );
    expect(
      salmonTrafficResetDays({
        'reset_day': 45,
      }, currentTime: DateTime(2026, 10, 8)),
      45,
    );
    expect(
      salmonTrafficResetDate({
        'reset_day': 31,
      }, currentTime: DateTime(2026, 10, 8)),
      DateTime(2026, 11, 8),
    );
    expect(
      salmonTrafficResetSummary({
        'reset_day': 0,
      }, currentTime: DateTime(2026, 10, 8)),
      '今日重置流量',
    );
  });

  test('does not invent a reset day without schedule data', () {
    expect(
      salmonTrafficResetDays({}, currentTime: DateTime(2026, 10, 7)),
      isNull,
    );
    expect(salmonTrafficResetSummary({}), '重置日期暂未提供');
    expect(salmonTrafficResetSummary({'reset_traffic_method': 2}), '流量不自动重置');
  });
}
