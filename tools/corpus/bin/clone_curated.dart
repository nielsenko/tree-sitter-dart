import 'package:corpus/utils.dart';

/// Clones curated GitHub repos that use advanced Dart features.
/// These complement the pub.dev top-2000 packages with repos known
/// for heavy use of patterns, records, macros, sealed classes, etc.
void main(List<String> arguments) async {
  clean('download/curated');

  var repos = [
    // Core Dart ecosystem
    (user: 'dart-lang', repo: 'shelf'),
    (user: 'dart-lang', repo: 'http'),
    (user: 'dart-lang', repo: 'test'),
    (user: 'dart-lang', repo: 'args'),
    (user: 'dart-lang', repo: 'logging'),
    (user: 'dart-lang', repo: 'mockito'),
    (user: 'dart-lang', repo: 'protobuf'),
    (user: 'dart-lang', repo: 'tools'),
    (user: 'dart-lang', repo: 'dartdoc'),
    (user: 'dart-lang', repo: 'webdev'),

    // Popular frameworks and packages
    (user: 'cfug', repo: 'dio'),
    (user: 'rrousselGit', repo: 'riverpod'),
    (user: 'rrousselGit', repo: 'freezed'),
    (user: 'rrousselGit', repo: 'provider'),
    (user: 'felangel', repo: 'bloc'),
    (user: 'flame-engine', repo: 'flame'),
    (user: 'invertase', repo: 'melos'),
    (user: 'passsy', repo: 'dart_lint'),
    (user: 'gql-dart', repo: 'gql'),
    (user: 'cerebroapp', repo: 'cerebro'),

    // Server-side Dart
    (user: 'dart-lang', repo: 'shelf'),
    (user: 'serverpod', repo: 'serverpod'),

    // Code generation / build
    (user: 'dart-lang', repo: 'build'),
    (user: 'dart-lang', repo: 'source_gen'),
    (user: 'google', repo: 'json_serializable.dart'),

    // State management / architecture
    (user: 'nickvdyck', repo: 'stacked'),
    (user: 'peiffer-innovations', repo: 'automated_testing_framework'),

    // Advanced Dart 3.x features (patterns, records, sealed)
    (user: 'celest-dev', repo: 'celest'),
    (user: 'shorebirdtech', repo: 'shorebird'),
    (user: 'VeryGoodOpenSource', repo: 'very_good_cli'),
    (user: 'VeryGoodOpenSource', repo: 'dart_frog'),
    (user: 'dartclub', repo: 'turf_dart'),
    (user: 'simolus3', repo: 'drift'),
    (user: 'isar', repo: 'isar'),
    (user: 'aspect-build', repo: 'rules_dart'),

    // Flutter packages with complex Dart
    (user: 'fluttercommunity', repo: 'flutter_launcher_icons'),
    (user: 'abuanwar072', repo: 'Flutter-Responsive-Admin-Panel-or-Dashboard'),
    (user: 'TheAlphameworpsource', repo: 'flutter_riverpod_2'),
    (user: 'gskinnerTeam', repo: 'flutter-wonderous-app'),
  ];

  var downloader = Downloader(totalResources: repos.length, concurrency: 5);
  for (var (:user, :repo) in repos) {
    downloader.cloneGitHubRepo('curated', user, repo);
  }
}
