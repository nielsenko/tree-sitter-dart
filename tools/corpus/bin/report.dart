/// Runs tree-sitter parse on all corpus Dart files and reports results.
///
/// Usage:
///   dart run bin/report.dart [--no-filter-valid] [--recheck-syntax]
///                            [--details] [--no-zero-width] [--no-ast]
///                            [--update-ast-pins]
///
/// By default, files the Dart analyzer rejects as syntactically invalid are
/// excluded (mustache templates, parse-error fixtures, broken codegen), so
/// the gate measures the grammar against valid Dart only. The analyzer
/// verdict is cached in download/.analyzer-invalid.txt and rebuilt
/// automatically when the corpus file count changes.
///
/// Remaining failures are compared by identity against known_failures.txt;
/// any failing file not listed there (or listed file that now passes) is
/// reported and the run exits non-zero.
///
/// Options:
///   --no-filter-valid  Include analyzer-invalid files (historical raw
///                      numbers; skips the known-failures identity gate)
///   --recheck-syntax   Rebuild the cached analyzer verdict
///   --details          Show individual failure lines
///   --no-zero-width    Skip the zero-width scan. It runs by default: a tree
///                      can hide error recovery behind a zero-width node
///                      (recovery supplied a MISSING *hidden* token), and
///                      `tree-sitter parse` still exits 0 there, because its
///                      exit code reflects only VISIBLE ERROR/MISSING nodes -
///                      so parse-rate acceptance alone cannot see the class.
///                      Reported separately, so the pass/fail baseline above
///                      stays comparable across runs.
///   --no-ast           Skip the analyzer AST check. It runs by default on the
///                      files that parse and compares the grammar's tree with
///                      the Dart analyzer's AST (tools/analyzer_ast). A
///                      crossing, a node of one tree that starts inside a
///                      node of the other and ends outside it, is a silent
///                      misparse that parse rate cannot see. Crossings are
///                      compared by identity against known_ast_crossings.txt.
///   --update-ast-pins  Rewrite the entries of known_ast_crossings.txt from
///                      this run, keeping its comment header.
import 'dart:io';

void main(List<String> args) async {
  var filterValid = !args.contains('--no-filter-valid');
  var recheckSyntax = args.contains('--recheck-syntax');
  var showDetails = args.contains('--details');
  var checkZeroWidth = !args.contains('--no-zero-width');
  var checkAst = !args.contains('--no-ast');
  var updateAstPins = args.contains('--update-ast-pins');

  // Find the tree-sitter-dart root (2 levels up from this package root).
  var scriptDir = Directory.current.path;
  if (!scriptDir.endsWith('corpus')) {
    stderr.writeln('Run from tools/corpus/');
    exit(1);
  }
  var repoRoot = Directory(scriptDir).parent.parent.path;

  // Ensure config points to our grammar.
  var tempDir = Directory.systemTemp.createTempSync('corpus-report-');
  var tsConfigPath = '${tempDir.path}/ts-config.json';
  var tsParentDir = Directory(repoRoot).parent.path;
  File(
    tsConfigPath,
  ).writeAsStringSync('{"parser-directories":["$tsParentDir"]}');

  // Clear cached parser (the cache is keyed by language name only, so a lib
  // compiled from a different dart grammar would be silently reused).
  var home = Platform.environment['HOME'] ?? '';
  for (var ext in ['dylib', 'so']) {
    var cacheFile = File('$home/.cache/tree-sitter/lib/dart.$ext');
    if (cacheFile.existsSync()) {
      cacheFile.deleteSync();
    }
  }

  // Discover corpora.
  var downloadDir = '$scriptDir/download';
  var corpora = <String, List<String>>{};

  for (var entry in Directory(downloadDir).listSync()) {
    if (entry is Directory) {
      var name = entry.path.split('/').last;
      var files = <String>[];
      await for (var file
          in entry
              .list(recursive: true)
              .where((e) => e is File && e.path.endsWith('.dart'))) {
        files.add(File(file.path).absolute.path);
      }
      files.sort();
      corpora[name] = files;
    }
  }

  if (corpora.isEmpty) {
    stderr.writeln('No corpora found in $downloadDir/');
    stderr.writeln('Run download_packages.dart or clone_curated.dart first.');
    exit(1);
  }

  var allFiles = corpora.values.expand((f) => f).toList();

  // Filter out analyzer-invalid files (cached; keyed on corpus file count).
  var invalidFiles = <String>{};
  if (filterValid) {
    var cacheFile = File('$downloadDir/.analyzer-invalid.txt');
    var cached = _readSyntaxCache(cacheFile, downloadDir);
    if (recheckSyntax || cached == null || cached.checkedFiles != allFiles.length) {
      if (cached != null && cached.checkedFiles != allFiles.length) {
        stderr.writeln(
          'Corpus changed (${cached.checkedFiles} -> ${allFiles.length} '
          'files); rebuilding syntax cache...',
        );
      } else {
        stderr.writeln('Checking syntax with Dart analyzer (cached after)...');
      }
      invalidFiles = await _runSyntaxCheck(scriptDir, allFiles);
      _writeSyntaxCache(cacheFile, downloadDir, allFiles.length, invalidFiles);
    } else {
      invalidFiles = cached.invalid;
      stderr.writeln(
        'Excluding ${invalidFiles.length} analyzer-invalid files '
        '(cached; --recheck-syntax to rebuild).',
      );
    }
  }

  // Expected failures, by identity (paths relative to download/).
  var knownFailures = <String>{};
  var knownFailuresFile = File('$scriptDir/known_failures.txt');
  if (knownFailuresFile.existsSync()) {
    for (var line in knownFailuresFile.readAsLinesSync()) {
      var trimmed = line.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        knownFailures.add(trimmed);
      }
    }
  }

  // Run tree-sitter parse on each corpus.
  stderr.writeln('');
  stderr.writeln('Corpus Report');
  stderr.writeln('${'=' * 80}');

  var totalFiles = 0;
  var totalPassed = 0;
  var totalFailed = 0;
  var allFailures = <String>[];
  var allPassed = <String>[];

  for (var entry in corpora.entries) {
    var name = entry.key;
    var files = entry.value;

    if (filterValid) {
      files = files.where((f) => !invalidFiles.contains(f)).toList();
    }

    if (files.isEmpty) {
      stderr.writeln('$name: no files');
      continue;
    }

    // Write file list to temp file.
    var tempFile = File('${tempDir.path}/corpus-files-$name.txt');
    tempFile.writeAsStringSync(files.join('\n'));

    // A single --quiet --stat pass prints one line per failing file (ERROR
    // and MISSING alike) followed by the stats summary.
    var result = await Process.run('npx', [
      'tree-sitter',
      'parse',
      '--config-path',
      tsConfigPath,
      '--quiet',
      '--stat',
      '--paths',
      tempFile.path,
    ], workingDirectory: repoRoot);

    var output = result.stdout as String;
    if (result.exitCode != 0 && output.isEmpty) {
      stderr.writeln(
        '${name.padRight(20)} tree-sitter error: ${result.stderr}',
      );
      continue;
    }

    var failureLines = <String>[];
    var statsLine = '';
    for (var line in output.split('\n')) {
      if (line.contains('Total parses')) {
        statsLine = line;
      } else if (line.contains('\tParse:')) {
        failureLines.add(line);
      }
    }

    var totalMatch = RegExp(
      r'successful parses: (\d+).*failed parses: (\d+).*success percentage: ([\d.]+)%',
    ).firstMatch(statsLine);

    if (totalMatch != null) {
      var passed = int.parse(totalMatch.group(1)!);
      var failed = int.parse(totalMatch.group(2)!);
      var pct = totalMatch.group(3)!;

      totalFiles += passed + failed;
      totalPassed += passed;
      totalFailed += failed;

      stderr.writeln(
        '${name.padRight(20)} ${(passed + failed).toString().padLeft(8)} files  '
        '${passed.toString().padLeft(8)} passed  '
        '${failed.toString().padLeft(5)} failed  '
        '$pct%',
      );

      for (var line in failureLines) {
        var path = line.split(RegExp(r'\s+Parse:')).first.trim();
        allFailures.add(_relativeToDownload(path, downloadDir));
      }

      if (failed != failureLines.length) {
        stderr.writeln(
          '${''.padRight(20)} WARNING: stats report $failed failures but '
          '${failureLines.length} failure lines were captured',
        );
      }

      var failedPaths = failureLines
          .map((line) => line.split(RegExp(r'\s+Parse:')).first.trim())
          .toSet();
      var passedFiles =
          files.where((f) => !failedPaths.contains(f)).toList();
      allPassed.addAll(passedFiles);

      if (checkZeroWidth) {
        // Scan only the files that PASSED: check_zero_width flags ERROR and
        // MISSING nodes too, so feeding it the failures would just re-report
        // what the gate above already caught. What is wanted here is the
        // opposite - defects the parse rate cannot see - so a non-zero count
        // below always means a file that was accepted but should not be.
        var passedFile = File('${tempDir.path}/corpus-passed-$name.txt');
        passedFile.writeAsStringSync(passedFiles.join('\n'));
        var zwResult = await Process.run('node', [
          'tools/check_zero_width.mjs',
          '--config-path',
          tsConfigPath,
          '--quiet',
          '--paths',
          passedFile.path,
        ], workingDirectory: repoRoot);
        var zwLine = (zwResult.stdout as String)
            .split('\n')
            .firstWhere(
              (l) => l.startsWith('zero-width check:'),
              orElse: () => '',
            );
        stderr.writeln(
          '${''.padRight(20)} ${zwLine.isEmpty ? 'zero-width check failed to run' : zwLine}',
        );
      }

      if (showDetails) {
        for (var line in failureLines) {
          // Shorten the path for readability.
          var short = line.replaceAll(RegExp(r'.*download/[^/]+/'), '  ');
          // Trim the Parse timing info.
          short = short.replaceAll(RegExp(r'\s+Parse:.*'), '');
          stderr.writeln(short);
        }
      }
    } else {
      stderr.writeln('${name.padRight(20)} parse failed');
    }
  }

  stderr.writeln('${'─' * 80}');
  var totalPct = totalFiles > 0
      ? (totalPassed / totalFiles * 100).toStringAsFixed(2)
      : '0.00';
  stderr.writeln(
    '${'TOTAL'.padRight(20)} ${totalFiles.toString().padLeft(8)} files  '
    '${totalPassed.toString().padLeft(8)} passed  '
    '${totalFailed.toString().padLeft(5)} failed  '
    '$totalPct%',
  );

  // Identity gate: every failure must be a known one, every known one must
  // still fail. Only meaningful when analyzer-invalid files are excluded.
  var exitCode = 0;
  if (checkAst && filterValid) {
    var agrees = await _checkAstCrossings(
      repoRoot: repoRoot,
      pinsFile: File('$scriptDir/known_ast_crossings.txt'),
      downloadDir: downloadDir,
      tempDir: tempDir.path,
      files: allPassed,
      update: updateAstPins,
      showDetails: showDetails,
    );
    if (!agrees) exitCode = 1;
  }
  if (filterValid) {
    var failureSet = allFailures.toSet();
    var newFailures = failureSet.difference(knownFailures).toList()..sort();
    var stalePins = knownFailures.difference(failureSet).toList()..sort();

    if (newFailures.isEmpty && stalePins.isEmpty) {
      stderr.writeln(
        'All $totalFailed failures match known_failures.txt.',
      );
    }
    if (newFailures.isNotEmpty) {
      stderr.writeln('NEW failures (not in known_failures.txt):');
      for (var f in newFailures) {
        stderr.writeln('  $f');
      }
      exitCode = 1;
    }
    if (stalePins.isNotEmpty) {
      stderr.writeln('Known failures that now pass (prune known_failures.txt):');
      for (var f in stalePins) {
        stderr.writeln('  $f');
      }
      exitCode = 1;
    }
  }

  // Clean up temp directory.
  tempDir.deleteSync(recursive: true);
  exit(exitCode);
}

class _SyntaxCache {
  final int checkedFiles;
  final Set<String> invalid;
  _SyntaxCache(this.checkedFiles, this.invalid);
}

_SyntaxCache? _readSyntaxCache(File cacheFile, String downloadDir) {
  if (!cacheFile.existsSync()) return null;
  int? checkedFiles;
  var invalid = <String>{};
  for (var line in cacheFile.readAsLinesSync()) {
    var trimmed = line.trim();
    if (trimmed.startsWith('# checked-files:')) {
      checkedFiles = int.tryParse(trimmed.split(':').last.trim());
    } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      invalid.add('$downloadDir/$trimmed');
    }
  }
  if (checkedFiles == null) return null;
  return _SyntaxCache(checkedFiles, invalid);
}

void _writeSyntaxCache(
  File cacheFile,
  String downloadDir,
  int checkedFiles,
  Set<String> invalid,
) {
  var relative = invalid.map((f) => _relativeToDownload(f, downloadDir)).toList()
    ..sort();
  cacheFile.writeAsStringSync(
    '# Analyzer-invalid corpus files; rebuild with --recheck-syntax.\n'
    '# checked-files: $checkedFiles\n'
    '${relative.join('\n')}\n',
  );
}

String _relativeToDownload(String path, String downloadDir) =>
    path.startsWith('$downloadDir/')
        ? path.substring(downloadDir.length + 1)
        : path;

Future<Set<String>> _runSyntaxCheck(
  String scriptDir,
  List<String> allFiles,
) async {
  var process = await Process.start('dart', [
    'run',
    'bin/check_syntax.dart',
  ], workingDirectory: scriptDir);
  process.stdin.write(allFiles.join('\n'));
  await process.stdin.close();

  var stdout = await process.stdout
      .transform(const SystemEncoding().decoder)
      .join();
  var stderr2 = await process.stderr
      .transform(const SystemEncoding().decoder)
      .join();
  await process.exitCode;

  var invalid = <String>{};
  for (var line in stdout.split('\n')) {
    var trimmed = line.trim();
    if (trimmed.isNotEmpty &&
        !trimmed.startsWith('Done:') &&
        !trimmed.startsWith('Checked')) {
      invalid.add(trimmed);
    }
  }
  if (stderr2.contains('Done:')) {
    stderr.writeln(
      stderr2
          .split('\n')
          .firstWhere((l) => l.startsWith('Done:'), orElse: () => ''),
    );
  }
  return invalid;
}

/// Runs the analyzer AST crossing check on [files] and compares the result
/// with [pinsFile], or rewrites its entries when [update] is set. Returns
/// whether the crossings match the pins.
Future<bool> _checkAstCrossings({
  required String repoRoot,
  required File pinsFile,
  required String downloadDir,
  required String tempDir,
  required List<String> files,
  required bool update,
  required bool showDetails,
}) async {
  var listFile = File('$tempDir/ast-files.txt')
    ..writeAsStringSync(files.join('\n'));
  var result = await Process.run(
      'dart',
      [
        'run',
        'bin/analyzer_ast.dart',
        'crossings',
        '--paths',
        listFile.path,
      ],
      workingDirectory: '$repoRoot/tools/analyzer_ast');
  if (result.exitCode != 0) {
    stderr.writeln('analyzer AST check failed to run:\n${result.stderr}');
    return false;
  }

  // Entries are `path<TAB>AnalyzerKind x grammar_kind<TAB>count`.
  var found = <String, int>{};
  var skipped = <String>[];
  var summary = <String>[];
  for (var line in (result.stdout as String).split('\n')) {
    switch (line.split('\t')) {
      case ['crossing', var path, var kinds, var count]:
        found['${_relativeToDownload(path, downloadDir)}\t$kinds'] =
            int.parse(count);
      case ['skipped', var path, var reason]:
        skipped.add('${_relativeToDownload(path, downloadDir)}: $reason');
      case ['summary', ...var fields]:
        summary = fields;
    }
  }
  if (summary
      case [
        var checked,
        _,
        var crossingFiles,
        var crossings,
        var matched,
        var nonLeaf,
      ]) {
    var rate = int.parse(matched) / int.parse(nonLeaf) * 100;
    stderr.writeln(
      'analyzer AST         ${checked.padLeft(8)} files  '
      '${skipped.length} skipped  $crossings crossings in $crossingFiles '
      'files  (${rate.toStringAsFixed(1)}% of non-leaf nodes span-equal)',
    );
  }
  if (showDetails) {
    for (var s in skipped) {
      stderr.writeln('  skipped $s');
    }
  }

  var header = <String>[];
  var pinned = <String, int>{};
  if (pinsFile.existsSync()) {
    for (var line in pinsFile.readAsLinesSync()) {
      if (line.startsWith('#') || line.trim().isEmpty) {
        if (pinned.isEmpty) header.add(line);
        continue;
      }
      var fields = line.split('\t');
      pinned['${fields[0]}\t${fields[1]}'] = int.parse(fields[2]);
    }
  }

  if (update) {
    var entries = [
      for (var MapEntry(key: key, value: count) in found.entries)
        '$key\t$count',
    ]..sort();
    pinsFile.writeAsStringSync('${[...header, ...entries].join('\n')}\n');
    stderr.writeln(
      'Wrote ${entries.length} entries to ${pinsFile.path.split('/').last}.',
    );
    return true;
  }

  var added = [
    for (var MapEntry(key: key, value: count) in found.entries)
      if (pinned[key] != count) '$key\t$count',
  ]..sort();
  var gone = [
    for (var MapEntry(key: key, value: count) in pinned.entries)
      if (found[key] != count) '$key\t$count',
  ]..sort();
  if (added.isEmpty && gone.isEmpty) {
    stderr.writeln('All crossings match known_ast_crossings.txt.');
    return true;
  }
  if (added.isNotEmpty) {
    stderr.writeln('NEW crossings (not in known_ast_crossings.txt):');
    for (var entry in added) {
      stderr.writeln('  $entry');
    }
  }
  if (gone.isNotEmpty) {
    stderr.writeln(
      'Pinned crossings that changed or no longer occur '
      '(update known_ast_crossings.txt):',
    );
    for (var entry in gone) {
      stderr.writeln('  $entry');
    }
  }
  return false;
}
