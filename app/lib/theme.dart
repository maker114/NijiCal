import 'package:flutter/material.dart';

/// 设计语言沿用 GuideLine（maker114/Guide-Line 的 lib/ui/theme）。
///
/// 三条核心规则（照抄它的口径）：
///   1. **底色永远中性灰**，主题色只出现在前景（文字 / 图标 / 选中态）；
///   2. **能点的用胶囊，装东西的用圆角矩形，只有图标的用正圆**；
///   3. 不靠阴影浮起——用 surface 家族的层级和一条分隔线。

/// 形状 token（对应 GuideLine 的 `AppShapes`）。
abstract final class AppShapes {
  static const StadiumBorder pill = StadiumBorder();
  static const CircleBorder circle = CircleBorder();

  static const double cardRadius = 20;
  static const double chipRadius = 16;
  static const double sheetRadius = 28;
  static const double nestedRadius = 12;
  static const double pillRadius = 24;

  static const RoundedRectangleBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(cardRadius)),
  );
  static const RoundedRectangleBorder chip = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(chipRadius)),
  );
  static const RoundedRectangleBorder dialog = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(28)),
  );
  static const RoundedRectangleBorder sheet = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(sheetRadius)),
  );
  static const BorderRadius topOnly = BorderRadius.vertical(top: Radius.circular(sheetRadius));
}

/// 一套主题 = 一个主色种子。
class AccentPreset {
  const AccentPreset({required this.id, required this.name, required this.seed, required this.mood});

  final String id;
  final String name;
  final Color seed;
  final String mood;
}

const List<AccentPreset> accentPresets = <AccentPreset>[
  AccentPreset(id: 'ink', name: '墨黑', seed: Color(0xFF37474F), mood: '克制、少颜色'),
  AccentPreset(id: 'default', name: '默认蓝', seed: Color(0xFF2F6FEB), mood: '干净、通用'),
  AccentPreset(id: 'pine', name: '松绿', seed: Color(0xFF2E7D32), mood: '安静、耐看'),
  AccentPreset(id: 'clay', name: '陶土', seed: Color(0xFFB4532A), mood: '温暖、偏土黄'),
  AccentPreset(id: 'plum', name: '梅紫', seed: Color(0xFF7B3FA0), mood: '偏文艺'),
  AccentPreset(id: 'sand', name: '沙金', seed: Color(0xFF9A7B31), mood: '旧纸张的感觉'),
  AccentPreset(id: 'ocean', name: '海松', seed: Color(0xFF0E7C86), mood: '清爽、偏冷'),
];

/// 与用户自己在 GuideLine 里选的一致：墨黑。
const String defaultAccentId = 'ink';

AccentPreset presetOf(String id) =>
    accentPresets.firstWhere((p) => p.id == id, orElse: () => accentPresets.first);

/// 中文字形兜底链 —— **只给兜底，不设 fontFamily**。
/// 不设它的话，Android 上还好，Windows 上中文会落成宋体（发虚、笔画细）。
const List<String> cjkFontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'HarmonyOS Sans SC',
  'Noto Sans SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'DengXian',
  'PingFang SC',
];

/// 中性底色用的种子（纯灰，Material 3 由此推导一整套中性 surface）。
const Color _neutralSeed = Color(0xFF8A8A8A);

Color _neutralize(Color color) => HSLColor.fromColor(color).withSaturation(0).toColor();

/// 把 M3 推到的一套配色**统一去色**，只保留明度层级。
ColorScheme _neutralScheme(ColorScheme from) => from.copyWith(
      surface: _neutralize(from.surface),
      surfaceDim: _neutralize(from.surfaceDim),
      surfaceBright: _neutralize(from.surfaceBright),
      surfaceContainerLowest: _neutralize(from.surfaceContainerLowest),
      surfaceContainerLow: _neutralize(from.surfaceContainerLow),
      surfaceContainer: _neutralize(from.surfaceContainer),
      surfaceContainerHigh: _neutralize(from.surfaceContainerHigh),
      surfaceContainerHighest: _neutralize(from.surfaceContainerHighest),
      onSurface: _neutralize(from.onSurface),
      onSurfaceVariant: _neutralize(from.onSurfaceVariant),
      outline: _neutralize(from.outline),
      outlineVariant: _neutralize(from.outlineVariant),
    );

/// 只换前景：主 / 次 / 三色与它们的容器色；surface 家族一律不碰。
ColorScheme applyAccent(ColorScheme neutral, Color accent) {
  // 压在强调色上的字取黑或白，判据只能看强调色自己的明暗
  final onAccent = accent.computeLuminance() > 0.5 ? const Color(0xFF1A1A1A) : Colors.white;

  return neutral.copyWith(
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: accent,
    onPrimaryContainer: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    // 选中胶囊 = 强调色 22% 淡底
    secondaryContainer: accent.withValues(alpha: 0.22),
    onSecondaryContainer: accent,
    tertiary: accent,
    onTertiary: onAccent,
    tertiaryContainer: accent.withValues(alpha: 0.18),
    onTertiaryContainer: accent,
    inversePrimary: accent,
  );
}

ThemeData buildAppTheme({String accentId = defaultAccentId, Brightness brightness = Brightness.light}) {
  final accent = presetOf(accentId).seed;
  final neutral = _neutralScheme(ColorScheme.fromSeed(seedColor: _neutralSeed, brightness: brightness));
  final scheme = applyAccent(neutral, accent);

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamilyFallback: cjkFontFallback,
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.dark ? UrgencyColors.dark : UrgencyColors.light,
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        fontFamilyFallback: cjkFontFallback,
      ),
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: AppShapes.card,
    ),
    dialogTheme: DialogThemeData(shape: AppShapes.dialog, backgroundColor: scheme.surfaceContainerLow),
    bottomSheetTheme: BottomSheetThemeData(
      shape: AppShapes.sheet,
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: AppShapes.pill,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: AppShapes.pill,
        foregroundColor: scheme.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(AppShapes.pillRadius)), borderSide: BorderSide.none),
      enabledBorder: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(AppShapes.pillRadius)), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppShapes.pillRadius)),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    ),
    textTheme: TextTheme(
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: scheme.onSurface),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
      bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: scheme.onSurface),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: scheme.onSurface),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.5, color: scheme.onSurfaceVariant),
      labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
      labelMedium: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      labelSmall: TextStyle(fontSize: 11, letterSpacing: 0.2, color: scheme.onSurfaceVariant),
    ),
  );

  return base;
}

// ---------------------------------------------------------------- 紧迫度

/// 紧迫度分档（照抄 GuideLine 的 `Urgency`，只是把档位收敛到本项目需要的那几档）。
enum Urgency { overdue, today, within3, within7, later }

String urgencyLabel(Urgency u) => switch (u) {
      Urgency.overdue => '已过期',
      Urgency.today => '今天',
      Urgency.within3 => '3 天内',
      Urgency.within7 => '7 天内',
      Urgency.later => '更远',
    };

/// 越接近越红：冷端绿、热端红，中间走黄橙。
@immutable
class UrgencyColors extends ThemeExtension<UrgencyColors> {
  const UrgencyColors({
    required this.overdue,
    required this.today,
    required this.within3,
    required this.within7,
    required this.later,
  });

  final Color overdue;
  final Color today;
  final Color within3;
  final Color within7;
  final Color later;

  static const UrgencyColors light = UrgencyColors(
    overdue: Color(0xFFC62828),
    today: Color(0xFFE64A19),
    within3: Color(0xFFEF6C00),
    within7: Color(0xFF9E9D24),
    later: Color(0xFF2E7D32),
  );

  static const UrgencyColors dark = UrgencyColors(
    overdue: Color(0xFFFF8A80),
    today: Color(0xFFFFAB91),
    within3: Color(0xFFFFCC80),
    within7: Color(0xFFDCE775),
    later: Color(0xFFA5D6A7),
  );

  Color of(Urgency u) => switch (u) {
        Urgency.overdue => overdue,
        Urgency.today => today,
        Urgency.within3 => within3,
        Urgency.within7 => within7,
        Urgency.later => later,
      };

  static UrgencyColors ofContext(BuildContext context) =>
      Theme.of(context).extension<UrgencyColors>() ?? light;

  @override
  UrgencyColors copyWith({Color? overdue, Color? today, Color? within3, Color? within7, Color? later}) => UrgencyColors(
        overdue: overdue ?? this.overdue,
        today: today ?? this.today,
        within3: within3 ?? this.within3,
        within7: within7 ?? this.within7,
        later: later ?? this.later,
      );

  @override
  UrgencyColors lerp(ThemeExtension<UrgencyColors>? other, double t) {
    if (other is! UrgencyColors) return this;
    return UrgencyColors(
      overdue: Color.lerp(overdue, other.overdue, t)!,
      today: Color.lerp(today, other.today, t)!,
      within3: Color.lerp(within3, other.within3, t)!,
      within7: Color.lerp(within7, other.within7, t)!,
      later: Color.lerp(later, other.later, t)!,
    );
  }
}

/// 距离 → 档位（按日历天算，避开夏令时 23/25 小时的偏差）。
Urgency urgencyOf(DateTime due, {DateTime? now}) {
  final current = now ?? DateTime.now();
  if (!due.isAfter(current)) return Urgency.overdue;
  final a = DateTime.utc(due.year, due.month, due.day);
  final b = DateTime.utc(current.year, current.month, current.day);
  final days = a.difference(b).inDays;
  if (days == 0) return Urgency.today;
  if (days <= 3) return Urgency.within3;
  if (days <= 7) return Urgency.within7;
  return Urgency.later;
}
