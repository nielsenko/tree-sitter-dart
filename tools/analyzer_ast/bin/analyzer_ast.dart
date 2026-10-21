/// Dumps the Dart analyzer's AST, or measures how faithfully a tree-sitter
/// grammar reproduces it.
///
///   dart run bin/analyzer_ast.dart dump <file.dart>
///   dart run bin/analyzer_ast.dart compare [--grammar <dir>]...
///       [--misses] [--kind <Kind>]... (<file.dart>... | --paths <list>)
///
/// `dump` prints the analyzer AST as an S-expression with tree-sitter-style
/// 0-based `[row, column]` ranges (columns in UTF-8 bytes), so it can be read
/// next to `tree-sitter parse` output.
///
/// `compare` asks, for every analyzer node, whether the grammar's tree has a
/// named node spanning exactly the same source range. A declaration also
/// matches when the grammar's node starts at its annotations or at its name
/// instead of at its doc comment. The match rate per analyzer node kind shows
/// which constructs the grammar has no node for (flat selector chains,
/// unwrapped declarations), and `--misses` lists the unmatched nodes, which
/// is where silent misparses show up. Files the analyzer rejects are skipped.
///
/// `--grammar` takes a grammar directory (default: this repository) and may
/// be repeated to compare several grammars side by side.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

final repoRoot = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..', '..', '..'),
);

const leafKinds = {
  'SimpleIdentifier',
  'IntegerLiteral',
  'DoubleLiteral',
  'BooleanLiteral',
  'NullLiteral',
  'SimpleStringLiteral',
  'InterpolationString',
  'Comment',
  'CommentReference',
  'Label',
  'SuperExpression',
  'ThisExpression',
};

Future<void> main(List<String> args) async {
  final compareParser = ArgParser()
    ..addMultiOption('grammar', help: 'Grammar directory (repeatable).')
    ..addOption('paths', help: 'File listing the Dart files to compare.')
    ..addFlag('misses', help: 'List the unmatched analyzer nodes.')
    ..addMultiOption('kind', help: 'Restrict the report to these kinds.')
    ..addOption('min-count', defaultsTo: '1', help: 'Hide rarer kinds.');
  final parser = ArgParser()
    ..addCommand('dump')
    ..addCommand('compare', compareParser);
  final results = parser.parse(args);
  switch (results.command) {
    case ArgResults(name: 'dump', rest: [final path]):
      dump(path);
    case final ArgResults command? when command.name == 'compare':
      await compare(command);
    default:
      stderr.writeln(
        'usage: analyzer_ast dump <file.dart>\n'
        '       analyzer_ast compare [options] <file.dart>...\n'
        '${compareParser.usage}',
      );
      exit(64);
  }
}

/// An analyzer parse of one file, or null when it has syntax errors.
AnalyzedFile? analyze(String path) {
  final source = File(path).readAsStringSync();
  final result = parseString(
    content: source,
    featureSet: FeatureSet.latestLanguageVersion(),
    throwIfDiagnostics: false,
  );
  if (result.errors.any(
    (e) => e.diagnosticCode.type == DiagnosticType.SYNTACTIC_ERROR,
  )) {
    return null;
  }
  return AnalyzedFile(path, source, result.unit);
}

class AnalyzedFile {
  AnalyzedFile(this.path, this.source, this.unit) {
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0A) _lineStarts.add(i + 1);
    }
  }

  final String path;
  final String source;
  final CompilationUnit unit;
  final _lineStarts = [0];

  /// The tree-sitter point (row, UTF-8 byte column) of a UTF-16 offset.
  (int, int) point(int offset) {
    var lo = 0, hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final prefix = source.substring(_lineStarts[lo], offset);
    return (lo, utf8.encode(prefix).length);
  }
}

String kindOf(AstNode node) =>
    node.runtimeType.toString().replaceFirst(RegExp(r'Impl$'), '');

String range(AnalyzedFile file, int start, int end) {
  final (sr, sc) = file.point(start);
  final (er, ec) = file.point(end);
  return '[$sr, $sc] - [$er, $ec]';
}

void dump(String path) {
  final file = analyze(path);
  if (file == null) {
    stderr.writeln('$path: syntax errors');
    exit(1);
  }
  final out = StringBuffer();
  file.unit.accept(_Dumper(file, out));
  stdout.write(out);
}

class _Dumper extends GeneralizingAstVisitor<void> {
  _Dumper(this.file, this.out);

  final AnalyzedFile file;
  final StringBuffer out;
  var _depth = 0;

  @override
  void visitNode(AstNode node) {
    final children = <AstNode>[];
    node.visitChildren(_Collector(children));
    final text = switch (node) {
      SimpleIdentifier() || Literal() when children.isEmpty =>
        ' ${jsonEncode(_clip(node.toSource()))}',
      _ => '',
    };
    if (_depth > 0) out.writeln();
    out.write(
      '${'  ' * _depth}(${kindOf(node)}$text '
      '${range(file, node.offset, node.end)}',
    );
    _depth++;
    for (final child in children) {
      child.accept(this);
    }
    _depth--;
    out.write(')');
    if (_depth == 0) out.writeln();
  }

  static String _clip(String s) =>
      s.length > 40 ? '${s.substring(0, 37)}...' : s;
}

class _Collector extends GeneralizingAstVisitor<void> {
  _Collector(this.into);

  final List<AstNode> into;

  @override
  void visitNode(AstNode node) => into.add(node);
}

/// An analyzer node to look for in a grammar's tree.
class Expected {
  Expected(this.kind, this.starts, this.end, this.offset);

  final String kind;

  /// Every start a matching grammar node may have.
  final Set<(int, int)> starts;
  final (int, int) end;
  final int offset;
}

List<Expected> expectedNodes(AnalyzedFile file) {
  final nodes = <Expected>[];
  file.unit.accept(_ExpectedCollector(file, nodes));
  return nodes;
}

class _ExpectedCollector extends GeneralizingAstVisitor<void> {
  _ExpectedCollector(this.file, this.nodes);

  final AnalyzedFile file;
  final List<Expected> nodes;

  @override
  void visitNode(AstNode node) {
    if (node.length > 0) {
      final starts = {file.point(node.offset)};
      if (node is AnnotatedNode) {
        starts.add(file.point(node.firstTokenAfterCommentAndMetadata.offset));
        if (node.metadata.isNotEmpty) {
          starts.add(file.point(node.metadata.first.offset));
        }
      }
      nodes.add(
        Expected(kindOf(node), starts, file.point(node.end), node.offset),
      );
    }
    super.visitNode(node);
  }
}

typedef Span = (int, int, int, int);

final _nodePattern = RegExp(
  r'\((\w+|MISSING[^\[]*?) \[(\d+), (\d+)\] - \[(\d+), (\d+)\]',
);

/// Named-node spans per file, in input order, from `tree-sitter parse`.
Future<List<Set<Span>>> treeSitterSpans(
  String grammarDir,
  List<String> files,
  Directory temp,
) async {
  final config = jsonDecode(
    File(p.join(grammarDir, 'tree-sitter.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final language =
      ((config['grammars'] as List).first as Map)['name'] as String;
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final lib = p.join(temp.path, '${temp.listSync().length}-$language.$ext');
  final cli = treeSitterCli();
  final build = await Process.run(cli, ['build', '-o', lib, grammarDir]);
  if (build.exitCode != 0) {
    stderr.writeln(
      'tree-sitter build failed for $grammarDir:\n${build.stderr}',
    );
    exit(1);
  }
  final list = File(p.join(temp.path, 'paths.txt'))
    ..writeAsStringSync(files.join('\n'));
  final process = await Process.start(cli, [
    'parse',
    '--lib-path',
    lib,
    '--lang-name',
    language,
    '--paths',
    list.path,
  ]);
  process.stderr.drain<void>();
  final trees = <Set<Span>>[];
  await for (final line
      in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    // A tree's root line starts with `(`. Error summary lines start with the
    // file path and are skipped.
    if (line.startsWith('(')) trees.add({});
    if (trees.isEmpty || !(line.startsWith('(') || line.startsWith(' '))) {
      continue;
    }
    for (final m in _nodePattern.allMatches(line)) {
      final name = m[1]!;
      if (name == 'ERROR' || name.startsWith('MISSING')) continue;
      trees.last.add((
        int.parse(m[2]!),
        int.parse(m[3]!),
        int.parse(m[4]!),
        int.parse(m[5]!),
      ));
    }
  }
  await process.exitCode;
  if (trees.length != files.length) {
    stderr.writeln('expected ${files.length} trees, got ${trees.length}');
    exit(1);
  }
  return trees;
}

String treeSitterCli() {
  final local = p.join(repoRoot, 'node_modules', '.bin', 'tree-sitter');
  return File(local).existsSync() ? local : 'tree-sitter';
}

/// The directory name of each grammar, qualified by its parent directory
/// when two grammars share a name.
List<String> columnNames(List<String> grammars) => [
  for (final g in grammars)
    grammars.where((o) => p.basename(o) == p.basename(g)).length > 1
        ? p.join(p.basename(p.dirname(g)), p.basename(g))
        : p.basename(g),
];

Future<void> compare(ArgResults args) async {
  final grammars = (args['grammar'] as List<String>).isEmpty
      ? [repoRoot]
      : [
          for (final g in args['grammar'] as List<String>)
            p.normalize(p.absolute(g)),
        ];
  final kinds = (args['kind'] as List<String>).toSet();
  final minCount = int.parse(args['min-count'] as String);
  final paths = [
    ...args.rest,
    if (args['paths'] case final String list)
      ...File(list).readAsLinesSync().where((l) => l.trim().isNotEmpty),
  ];

  final files = <AnalyzedFile>[];
  for (final path in paths) {
    final file = analyze(path);
    if (file == null) {
      stderr.writeln('skipping $path: the analyzer reports syntax errors');
    } else {
      files.add(file);
    }
  }
  if (files.isEmpty) {
    stderr.writeln('no analyzer-valid files to compare');
    exit(1);
  }

  final temp = Directory.systemTemp.createTempSync('analyzer_ast');
  try {
    final names = columnNames(grammars);
    final width = names.fold(8, (w, n) => n.length > w ? n.length : w) + 2;
    final spans = [
      for (final g in grammars)
        await treeSitterSpans(g, [for (final f in files) f.path], temp),
    ];
    final total = <String, int>{};
    final matched = [for (final _ in grammars) <String, int>{}];
    final misses = StringBuffer();
    for (var i = 0; i < files.length; i++) {
      for (final node in expectedNodes(files[i])) {
        if (kinds.isNotEmpty && !kinds.contains(node.kind)) continue;
        total.update(node.kind, (n) => n + 1, ifAbsent: () => 1);
        for (var g = 0; g < grammars.length; g++) {
          final tree = spans[g][i];
          final (er, ec) = node.end;
          if (node.starts.any((s) => tree.contains((s.$1, s.$2, er, ec)))) {
            matched[g].update(node.kind, (n) => n + 1, ifAbsent: () => 1);
          } else if (args['misses'] as bool) {
            final (sr, sc) = node.starts.first;
            final snippet = files[i].source
                .substring(node.offset)
                .split('\n')
                .first;
            misses.writeln(
              '${names[g]}: ${files[i].path}:${sr + 1}:${sc + 1}'
              '-${er + 1}:${ec + 1} ${node.kind}  '
              '${snippet.length > 80 ? snippet.substring(0, 80) : snippet}',
            );
          }
        }
      }
    }

    double rate(int g, Iterable<String> ks) {
      final t = ks.fold(0, (s, k) => s + total[k]!);
      return t == 0 ? 1 : ks.fold(0, (s, k) => s + (matched[g][k] ?? 0)) / t;
    }

    String pct(double r) => '${(r * 100).toStringAsFixed(1)}%'.padLeft(width);
    final nonLeaf = total.keys.where((k) => !leafKinds.contains(k));
    stdout.writeln(
      '${files.length} files, '
      '${total.values.fold(0, (a, b) => a + b)} analyzer nodes',
    );
    stdout.writeln(
      '${'exact-span match'.padRight(36)}'
      '${names.map((n) => n.padLeft(width)).join()}',
    );
    stdout.writeln(
      '${'  all nodes'.padRight(36)}'
      '${[for (var g = 0; g < grammars.length; g++) pct(rate(g, total.keys))].join()}',
    );
    stdout.writeln(
      '${'  non-leaf nodes'.padRight(36)}'
      '${[for (var g = 0; g < grammars.length; g++) pct(rate(g, nonLeaf))].join()}',
    );
    stdout.writeln();
    final sorted = total.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final MapEntry(key: kind, value: n) in sorted) {
      if (n < minCount) continue;
      stdout.writeln(
        '${kind.padRight(28)}${'$n'.padLeft(8)}'
        '${[for (var g = 0; g < grammars.length; g++) pct((matched[g][kind] ?? 0) / n)].join()}',
      );
    }
    if (misses.isNotEmpty) {
      stdout
        ..writeln()
        ..write(misses);
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}
