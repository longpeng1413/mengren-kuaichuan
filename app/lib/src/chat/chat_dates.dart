// WeChat-style day separators in a conversation: a small centred label above
// the first message of each day.

const _weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

DateTime _day(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// True when [current] needs a separator above it: it is the first message,
/// or it was sent on a different (local) day than [previous].
bool startsNewDay(DateTime? previous, DateTime current) =>
    previous == null || _day(previous) != _day(current);

/// 今天 / 昨天 / 星期三 (within the last week) / 11月3日 / 2025年11月3日.
String chatDayLabel(DateTime value, {DateTime? now}) {
  final day = _day(value);
  final today = _day(now ?? DateTime.now());
  // Calendar days apart; DateTime arithmetic across a DST change is fine
  // because both values are local midnights rounded to whole days.
  final daysAgo = (today.difference(day).inHours / 24).round();
  if (daysAgo == 0) return '今天';
  if (daysAgo == 1) return '昨天';
  if (daysAgo > 1 && daysAgo < 7) return _weekdays[day.weekday - 1];
  if (day.year == today.year) return '${day.month}月${day.day}日';
  return '${day.year}年${day.month}月${day.day}日';
}
