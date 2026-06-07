/// Checks Dart files for syntax errors using the Dart analyzer's parser.
/// Prints files that have parse errors to stdout.
/// Usage: dart run bin/check_syntax.dart < file_list.txt
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/error/error.dart';

void main(List<String> args) async {
  final lines = await stdin.transform(const SystemEncoding().decoder).join();
  final files = lines.split('\n').where((l) => l.trim().isNotEmpty).toList();

  var checked = 0;
  var errors = 0;

  for (final path in files) {
    checked++;
    if (checked % 10000 == 0) {
      stderr.writeln('Checked $checked / ${files.length}...');
    }

    try {
      final content = File(path).readAsStringSync();
      final result = parseString(
        content: content,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final syntaxErrors = result.errors.where(
        (e) => e.errorCode.type == ErrorType.SYNTACTIC_ERROR,
      );

      if (syntaxErrors.isNotEmpty) {
        print(path);
        errors++;
      }
    } catch (e) {
      print(path);
      errors++;
    }
  }

  stderr.writeln('Done: $checked files checked, $errors with syntax errors.');
}
