int? salmonTrafficResetDays(
  Map<String, dynamic> data, {
  DateTime? currentTime,
}) {
  final now = currentTime ?? DateTime.now();
  final remainingDays = int.tryParse('${data['reset_day'] ?? ''}');
  if (remainingDays != null) {
    return remainingDays >= 0 ? remainingDays : null;
  }
  final today = DateTime.utc(now.year, now.month, now.day);
  final raw = data['reset_at'] ?? data['reset_time'] ?? data['reset_date'];
  DateTime? reset;
  final timestamp = int.tryParse('${raw ?? ''}');
  if (timestamp != null && timestamp >= 1000000000) {
    reset = DateTime.fromMillisecondsSinceEpoch(
      timestamp < 100000000000 ? timestamp * 1000 : timestamp,
    );
  } else if (raw is String) {
    reset = DateTime.tryParse(raw);
  }
  if (reset == null) return null;
  final date = DateTime.utc(reset.year, reset.month, reset.day);
  final days = date.difference(today).inDays;
  return days >= 0 ? days : null;
}

DateTime? salmonTrafficResetDate(
  Map<String, dynamic> data, {
  DateTime? currentTime,
}) {
  final now = currentTime ?? DateTime.now();
  final days = salmonTrafficResetDays(data, currentTime: now);
  if (days == null) return null;
  return DateTime(now.year, now.month, now.day + days);
}

String salmonTrafficResetSummary(
  Map<String, dynamic> data, {
  DateTime? currentTime,
}) {
  final days = salmonTrafficResetDays(data, currentTime: currentTime);
  if (days != null) {
    return days == 0 ? '今日重置流量' : '距流量重置 $days 天';
  }
  return int.tryParse('${data['reset_traffic_method'] ?? ''}') == 2
      ? '流量不自动重置'
      : '重置日期暂未提供';
}
