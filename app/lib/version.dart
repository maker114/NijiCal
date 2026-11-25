/// 应用版本：与 pubspec.yaml 的 version 保持一致（提交时一起改）
///
/// 分支标记版：功能在 feature/auto-refresh-quiet 上验收，版本名带 -beta-<分支名>，
/// 合回 main 定版时再改成正式的三段版本号。
const String kAppVersion = '2.18.0-beta-auto-refresh-quiet';

/// 版本号（versionCode）：更新检查按它比较，必须与构建时的 --build-number 一致
const int kAppVersionCode = 82;
