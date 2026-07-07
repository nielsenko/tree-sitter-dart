/// Runs tree-sitter parse on all corpus Dart files and reports results.
///
/// Usage:
///   dart run bin/report.dart [--filter-valid] [--details] [--zero-width]
///
/// Options:
///   --filter-valid  Filter out files with Dart syntax errors before parsing
///   --details       Show individual failure details
///   --zero-width    Also flag files whose tree hides recovery behind a
///                   zero-width node (exit-code acceptance misses these);
///                   reported separately so the pass/fail baseline is stable
import 'dart:io';

void main(List<String> args) async {
  var filterValid = args.contains('--filter-valid');
  var showDetails = args.contains('--details');
  var checkZeroWidth = args.contains('--zero-width');

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

  // Optionally filter for valid Dart files.
  var invalidFiles = <String>{};
  if (filterValid) {
    stderr.writeln('Checking syntax with Dart analyzer...');
    var allFiles = corpora.values.expand((f) => f).toList();
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

    for (var line in stdout.split('\n')) {
      var trimmed = line.trim();
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('Done:') &&
          !trimmed.startsWith('Checked')) {
        invalidFiles.add(trimmed);
      }
    }
    if (stderr2.contains('Done:')) {
      stderr.writeln(
        stderr2
            .split('\n')
            .firstWhere((l) => l.startsWith('Done:'), orElse: () => ''),
      );
    }
  }

  // Run tree-sitter parse on each corpus.
  stderr.writeln('');
  stderr.writeln('Corpus Report');
  stderr.writeln('${'=' * 80}');

  var totalFiles = 0;
  var totalPassed = 0;
  var totalFailed = 0;

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

    // Parse the stats line.
    var output = result.stdout as String;
    if (result.exitCode != 0 && output.isEmpty) {
      stderr.writeln(
        '${name.padRight(20)} tree-sitter error: ${result.stderr}',
      );
      continue;
    }
    var statsLine = output
        .split('\n')
        .firstWhere((l) => l.contains('Total parses'), orElse: () => '');

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

      if (checkZeroWidth) {
        var zwResult = await Process.run('node', [
          'tools/check_zero_width.mjs',
          '--config-path',
          tsConfigPath,
          '--quiet',
          '--paths',
          tempFile.path,
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

      if (showDetails && failed > 0) {
        // Re-run to get failure details.
        var detailResult = await Process.run('npx', [
          'tree-sitter',
          'parse',
          '--config-path',
          tsConfigPath,
          '--quiet',
          '--paths',
          tempFile.path,
        ], workingDirectory: repoRoot);
        var detailOutput = detailResult.stdout as String;
        for (var line in detailOutput.split('\n')) {
          if (line.contains('ERROR')) {
            // Shorten the path for readability.
            var short = line.replaceAll(RegExp(r'.*download/[^/]+/'), '  ');
            // Trim the Parse timing info.
            short = short.replaceAll(RegExp(r'\s+Parse:.*'), '');
            stderr.writeln(short);
          }
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

  // Clean up temp directory.
  tempDir.deleteSync(recursive: true);
}
