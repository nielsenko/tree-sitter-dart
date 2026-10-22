/// Dumps the Dart analyzer's AST, or measures how faithfully a tree-sitter
/// grammar reproduces it.
///
///   dart run bin/analyzer_ast.dart dump <file.dart>
///   dart run bin/analyzer_ast.dart compare [--grammar <dir>]...
///       [--misses] [--kind <Kind>]... (<file.dart>... | --paths <list>)
///   dart run bin/analyzer_ast.dart crossings [--grammar <dir>] [--jobs <n>]
///       (<file.dart>... | --paths <list>)
///   dart run bin/analyzer_ast.dart recovery [--grammar <dir>] [--files <n>]
///       [--edits <n>] [--seed <n>] (<file.dart>... | --paths <list>)
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
/// `crossings` finds structural disagreements. A grammar node crosses an
/// analyzer node when it starts inside it and ends outside it, or the other
/// way round. Missing or extra nodes never cross, so unlike a span mismatch a
/// crossing is a misparse unless [isCrossingExempt] covers it. It prints one
/// tab-separated `crossing` line per file and kind pair with a count, then a
/// `summary` line, for the corpus gate in tools/corpus/bin/report.dart.
/// `--locations` adds an `at` line with the start of each crossing.
///
/// `recovery` measures how far a syntax error spreads. It breaks a random
/// sample of files with one edit at a time (see [sampleEdits]) and keeps the
/// edits that leave the file invalid Dart. The reference is the non-leaf
/// analyzer nodes outside the edit that the grammar matched exactly in the
/// intact file, so a grammar is only measured on structure it has. An edit
/// keeps a node when the broken tree has a node of the same kind at the
/// shifted span. The report gives the share kept before and after the edit,
/// how many rows away the farthest lost node reaches, and the contexts that
/// lose the most nodes.
///
/// `--grammar` takes a grammar directory (default: this repository). For
/// `compare` it may be repeated to compare several grammars side by side.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

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
  final crossingsParser = ArgParser()
    ..addOption('grammar', help: 'Grammar directory.')
    ..addOption('paths', help: 'File listing the Dart files to check.')
    ..addFlag('locations', help: 'Also print where each crossing starts.')
    ..addOption(
      'jobs',
      defaultsTo: '${Platform.numberOfProcessors}',
      help: 'Parallel tree-sitter processes.',
    );
  final recoveryParser = ArgParser()
    ..addOption('grammar', help: 'Grammar directory.')
    ..addOption('paths', help: 'File listing the Dart files to sample.')
    ..addOption('files', defaultsTo: '2000', help: 'Files to sample.')
    ..addOption('edits', defaultsTo: '3', help: 'Edits of each kind per file.')
    ..addOption('seed', defaultsTo: '1', help: 'Seed for the sample.')
    ..addOption('max-bytes', defaultsTo: '100000', help: 'Skip larger files.')
    ..addOption('worst', defaultsTo: '30', help: 'Worst edits to list.')
    ..addOption(
      'jobs',
      defaultsTo: '${Platform.numberOfProcessors}',
      help: 'Parallel tree-sitter processes.',
    );
  final parser = ArgParser()
    ..addCommand('dump')
    ..addCommand('compare', compareParser)
    ..addCommand('crossings', crossingsParser)
    ..addCommand('recovery', recoveryParser);
  final results = parser.parse(args);
  switch (results.command) {
    case ArgResults(name: 'dump', rest: [final path]):
      dump(path);
    case final ArgResults command? when command.name == 'compare':
      await compare(command);
    case final ArgResults command? when command.name == 'crossings':
      await crossings(command);
    case final ArgResults command? when command.name == 'recovery':
      await recovery(command);
    default:
      stderr.writeln(
        'usage: analyzer_ast dump <file.dart>\n'
        '       analyzer_ast compare [options] <file.dart>...\n'
        '${compareParser.usage}\n'
        '       analyzer_ast crossings [options] <file.dart>...\n'
        '${crossingsParser.usage}\n'
        '       analyzer_ast recovery [options] <file.dart>...\n'
        '${recoveryParser.usage}',
      );
      exit(64);
  }
}

/// An analyzer parse of one file at the newest language version that
/// accepts it, or null when none does.
AnalyzedFile? analyze(String path) {
  final bytes = File(path).readAsBytesSync();
  final bom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  final source = utf8.decode(bom ? bytes.sublist(3) : bytes);
  return switch (parseValid(source)) {
    final unit? => AnalyzedFile(path, source, unit, bomBytes: bom ? 3 : 0),
    null => null,
  };
}

/// The analyzer's AST of [source] at the newest language version that
/// accepts it, or null when none does.
CompilationUnit? parseValid(String source) {
  for (final featureSet in _featureSets) {
    final result = parseString(
      content: source,
      featureSet: featureSet,
      throwIfDiagnostics: false,
    );
    if (!result.errors.any(
      (e) => e.diagnosticCode.type == DiagnosticType.SYNTACTIC_ERROR,
    )) {
      return result.unit;
    }
  }
  return null;
}

/// Language versions to parse with, newest first. Dart 3.13 rejects `final`
/// on parameters outside a primary constructor, and older code uses it.
final _featureSets = [
  FeatureSet.latestLanguageVersion(),
  FeatureSet.latestLanguageVersion().restrictToVersion(Version(3, 12, 0)),
];

class AnalyzedFile extends Lines {
  AnalyzedFile(this.path, super.source, this.unit, {required super.bomBytes});

  final String path;
  final CompilationUnit unit;
}

/// Tree-sitter points of the UTF-16 offsets into [source].
class Lines {
  Lines(this.source, {this.bomBytes = 0}) {
    var ascii = true;
    for (var i = 0; i < source.length; i++) {
      final c = source.codeUnitAt(i);
      if (c == 0x0A) {
        _asciiLines.add(ascii);
        _lineStarts.add(i + 1);
        ascii = true;
      } else if (c > 0x7F) {
        ascii = false;
      }
    }
    _asciiLines.add(ascii);
  }

  final String source;

  /// The length of the byte order mark the file starts with, which [source]
  /// leaves out and tree-sitter columns count.
  final int bomBytes;
  final _lineStarts = [0];
  final _asciiLines = <bool>[];

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
    final shift = lo == 0 ? bomBytes : 0;
    if (_asciiLines[lo]) return (lo, shift + offset - _lineStarts[lo]);
    final prefix = source.substring(_lineStarts[lo], offset);
    return (lo, shift + utf8.encode(prefix).length);
  }
}

final _kinds = <Type, String>{};

String kindOf(AstNode node) => _kinds.putIfAbsent(node.runtimeType, () {
  final name = node.runtimeType.toString();
  return name.endsWith('Impl') ? name.substring(0, name.length - 4) : name;
});

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
      nodes.add(
        Expected(
          kindOf(node),
          {for (final s in startOffsets(node)) file.point(s)},
          file.point(node.end),
          node.offset,
        ),
      );
    }
    super.visitNode(node);
  }
}

/// Every offset a grammar node matching [node] may start at. A declaration
/// also matches when the grammar's node starts at its annotations or at its
/// name instead of at its doc comment.
Set<int> startOffsets(AstNode node) => {
  node.offset,
  if (node is AnnotatedNode) ...[
    node.firstTokenAfterCommentAndMetadata.offset,
    if (node.metadata.isNotEmpty) node.metadata.first.offset,
  ],
};

typedef Span = (int, int, int, int);

final _nodePattern = RegExp(
  r'\((\w+|MISSING[^\[]*?) \[(\d+), (\d+)\] - \[(\d+), (\d+)\]',
);

/// A grammar compiled into [temp], and the language name its library exports.
typedef Grammar = ({String lib, String language});

Future<Grammar> buildGrammar(String grammarDir, Directory temp) async {
  final config = jsonDecode(
    File(p.join(grammarDir, 'tree-sitter.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final language =
      ((config['grammars'] as List).first as Map)['name'] as String;
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final lib = p.join(temp.path, '${temp.listSync().length}-$language.$ext');
  final build = await Process.run(treeSitterCli(), [
    'build',
    '-o',
    lib,
    grammarDir,
  ]);
  if (build.exitCode != 0) {
    stderr.writeln(
      'tree-sitter build failed for $grammarDir:\n${build.stderr}',
    );
    exit(1);
  }
  return (lib: lib, language: language);
}

/// Named-node spans per file, in input order, from `tree-sitter parse`.
Future<List<Set<Span>>> treeSitterSpans(
  String grammarDir,
  List<String> files,
  Directory temp,
) async {
  final (:lib, :language) = await buildGrammar(grammarDir, temp);
  final cli = treeSitterCli();
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

/// A node as a pair of [position]s.
typedef Node = ({int start, int end, String kind});

/// A row and a UTF-8 byte column packed so that positions compare in source
/// order.
int position((int, int) point) => point.$1 << 32 | point.$2;

/// Where [node] starts, leaving out a doc comment in front of it. The
/// analyzer counts the doc comment as part of the declaration. Grammars keep
/// it as a separate node.
int startAfterDocComment(AstNode node) => switch (node) {
  AnnotatedNode(metadata: [final first, ...]) => first.offset,
  AnnotatedNode() => node.firstTokenAfterCommentAndMetadata.offset,
  _ => node.offset,
};

/// Whether [node] spans source in a way no tree-sitter Dart grammar
/// reproduces, so a crossing with it says nothing about a misparse.
///
/// - A [Comment] covers a whole `///` block. Grammars make a node per line.
/// - A function declaration's [FunctionExpression] covers `(params) body`.
///   Grammars put the parameters in the signature, next to the name.
/// - The innermost target of a cascade section (`..x` in `..x.y()`) starts
///   at the `..`, which grammars keep in the section node.
bool isCrossingExempt(AstNode node) => switch (node) {
  Comment() => true,
  FunctionExpression(parent: FunctionDeclaration()) => true,
  _ =>
    node.beginToken.type == TokenType.PERIOD_PERIOD ||
        node.beginToken.type == TokenType.QUESTION_PERIOD_PERIOD,
};

/// The crossings and exact-span matches in one file.
typedef FileResult = ({
  String path,
  Map<String, int> crossings,
  List<String> locations,
  int matched,
  int nonLeaf,
  String? skipped,
});

/// Each analyzer node and grammar node that cross.
List<(Node, Node)> crossingsBetween(List<Node> analyzer, List<Node> grammar) {
  final nodes = [...analyzer, ...grammar];
  final starts = Int64List.fromList([for (final n in nodes) n.start]);
  final ends = Int64List.fromList([for (final n in nodes) n.end]);
  final order = List<int>.generate(nodes.length, (i) => i)
    ..sort(
      (a, b) => starts[a] != starts[b]
          ? starts[a].compareTo(starts[b])
          : ends[b].compareTo(ends[a]),
    );
  final open = <int>[];
  final pairs = <(Node, Node)>[];
  for (final i in order) {
    final start = starts[i], end = ends[i];
    var kept = 0;
    for (final o in open) {
      if (ends[o] > start) open[kept++] = o;
    }
    open.length = kept;
    final fromAnalyzer = i < analyzer.length;
    for (final o in open) {
      if ((o < analyzer.length) == fromAnalyzer) continue;
      if (starts[o] < start && ends[o] < end) {
        pairs.add(fromAnalyzer ? (nodes[i], nodes[o]) : (nodes[o], nodes[i]));
      }
    }
    open.add(i);
  }
  return pairs;
}

FileResult checkFile(
  String path,
  List<Node> grammar, {
  required bool locations,
}) {
  final file = analyze(path);
  if (file == null) {
    return (
      path: path,
      crossings: const {},
      locations: const [],
      matched: 0,
      nonLeaf: 0,
      skipped: 'analyzer syntax errors',
    );
  }
  final analyzer = <Node>[];
  final spans = {for (final n in grammar) (n.start, n.end)};
  var matched = 0, nonLeaf = 0;
  for (final node in _allNodes(file.unit)) {
    if (node.length == 0 || isCrossingExempt(node)) continue;
    final kind = kindOf(node);
    final end = position(file.point(node.end));
    analyzer.add((
      start: position(file.point(startAfterDocComment(node))),
      end: end,
      kind: kind,
    ));
    if (leafKinds.contains(kind)) continue;
    nonLeaf++;
    if (startOffsets(node)
        .any((s) => spans.contains((position(file.point(s)), end)))) {
      matched++;
    }
  }
  final counts = <String, int>{};
  final where = <String>[];
  for (final (a, g) in crossingsBetween(analyzer, grammar)) {
    final kinds = '${a.kind} x ${g.kind}';
    counts.update(kinds, (n) => n + 1, ifAbsent: () => 1);
    if (locations) {
      where.add('${(a.start >> 32) + 1}:${(a.start & 0xffffffff) + 1}\t$kinds');
    }
  }
  return (
    path: path,
    crossings: counts,
    locations: where,
    matched: matched,
    nonLeaf: nonLeaf,
    skipped: null,
  );
}

List<AstNode> _allNodes(CompilationUnit unit) {
  final nodes = <AstNode>[];
  unit.accept(_Recorder(nodes));
  return nodes;
}

class _Recorder extends GeneralizingAstVisitor<void> {
  _Recorder(this.into);

  final List<AstNode> into;

  @override
  void visitNode(AstNode node) {
    into.add(node);
    super.visitNode(node);
  }
}

/// Results for one shard of files, parsed by its own `tree-sitter parse`.
Future<List<FileResult>> checkShard(
  ({
    String cli,
    Grammar grammar,
    List<String> files,
    String list,
    bool locations,
  })
  job,
) async {
  final results = <FileResult>[];
  await for (final tree in parseTrees(
    job.cli,
    job.grammar,
    job.files,
    job.list,
  )) {
    final path = job.files[results.length];
    results.add(
      tree.failed
          ? (
              path: path,
              crossings: const {},
              locations: const [],
              matched: 0,
              nonLeaf: 0,
              skipped: 'tree-sitter ERROR or MISSING',
            )
          : checkFile(path, tree.nodes, locations: job.locations),
    );
  }
  return results;
}

/// One file's tree from `tree-sitter parse`.
class Tree {
  /// The named nodes other than ERROR and MISSING, leaving out zero-width
  /// ones.
  final nodes = <Node>[];
  final errors = <Node>[];
  var missing = 0;

  bool get failed => errors.isNotEmpty || missing > 0;
}

/// The tree of each of [files], in order, from one `tree-sitter parse`.
Stream<Tree> parseTrees(
  String cli,
  Grammar grammar,
  List<String> files,
  String list,
) async* {
  File(list).writeAsStringSync(files.join('\n'));
  final process = await Process.start(cli, [
    'parse',
    '--lib-path',
    grammar.lib,
    '--lang-name',
    grammar.language,
    '--paths',
    list,
  ]);
  final errors = process.stderr.transform(utf8.decoder).join();
  var count = 0;
  Tree? tree;
  await for (final line
      in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    if (line.startsWith('(')) {
      if (tree != null) {
        count++;
        yield tree;
      }
      tree = Tree();
    } else if (tree == null || !line.startsWith(' ')) {
      continue;
    }
    for (final m in _nodePattern.allMatches(line)) {
      final name = m[1]!;
      if (name.startsWith('MISSING')) {
        tree.missing++;
        continue;
      }
      final start = position((int.parse(m[2]!), int.parse(m[3]!)));
      final end = position((int.parse(m[4]!), int.parse(m[5]!)));
      final node = (start: start, end: end, kind: name);
      if (name == 'ERROR') {
        tree.errors.add(node);
      } else if (start != end) {
        tree.nodes.add(node);
      }
    }
  }
  if (tree != null) {
    count++;
    yield tree;
  }
  await process.exitCode;
  if (count != files.length) {
    throw StateError(
      'expected ${files.length} trees, got $count: ${await errors}',
    );
  }
}

Future<void> crossings(ArgResults args) async {
  final grammarDir = switch (args['grammar']) {
    final String g => p.normalize(p.absolute(g)),
    _ => repoRoot,
  };
  final jobs = int.parse(args['jobs'] as String);
  final files = [
    ...args.rest,
    if (args['paths'] case final String list)
      ...File(list).readAsLinesSync().where((l) => l.trim().isNotEmpty),
  ];
  final temp = Directory.systemTemp.createTempSync('analyzer_ast');
  try {
    final grammar = await buildGrammar(grammarDir, temp);
    final cli = treeSitterCli();
    final shards = [
      for (var j = 0; j < jobs; j++)
        [for (var i = j; i < files.length; i += jobs) files[i]],
    ].where((shard) => shard.isNotEmpty).toList();
    final results = [
      for (final shard in await Future.wait([
        for (final (j, shard) in shards.indexed)
          Isolate.run(
            () => checkShard((
              cli: cli,
              grammar: grammar,
              files: shard,
              list: p.join(temp.path, 'shard-$j.txt'),
              locations: args['locations'] as bool,
            )),
          ),
      ]))
        ...shard,
    ]..sort((a, b) => a.path.compareTo(b.path));

    var skipped = 0, crossingFiles = 0, total = 0, matched = 0, nonLeaf = 0;
    for (final r in results) {
      if (r.skipped case final reason?) {
        skipped++;
        stdout.writeln('skipped\t${r.path}\t$reason');
        continue;
      }
      matched += r.matched;
      nonLeaf += r.nonLeaf;
      if (r.crossings.isNotEmpty) crossingFiles++;
      for (final MapEntry(key: kinds, value: n)
          in r.crossings.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key))) {
        total += n;
        stdout.writeln('crossing\t${r.path}\t$kinds\t$n');
      }
      for (final at in r.locations) {
        stdout.writeln('at\t${r.path}:$at');
      }
    }
    stdout.writeln(
      'summary\t${results.length}\t$skipped\t$crossingFiles\t$total\t'
      '$matched\t$nonLeaf',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

/// A replacement of [length] UTF-16 code units at [offset] by [insert], and
/// the token and node it hits.
typedef Edit = ({
  String kind,
  int offset,
  int length,
  String insert,
  String context,
});

/// What one edit left intact of the nodes before and after it.
typedef EditResult = ({
  String path,
  Edit edit,
  (int, int) at,
  int before,
  int keptBefore,
  int after,
  int keptAfter,
  int reach,
  int errorRows,
});

/// A reference node as UTF-16 offsets into the intact source, with the kind
/// the grammar gave it there.
typedef Reference = ({int start, int end, String kind});

const editKinds = ['truncate', 'close', 'drop', 'insert'];

const _closingTokens = {
  TokenType.CLOSE_PAREN,
  TokenType.CLOSE_SQUARE_BRACKET,
  TokenType.CLOSE_CURLY_BRACKET,
  TokenType.SEMICOLON,
  TokenType.GT,
};

const _numberTokens = {
  TokenType.INT,
  TokenType.INT_WITH_SEPARATORS,
  TokenType.DOUBLE,
  TokenType.DOUBLE_WITH_SEPARATORS,
  TokenType.HEXADECIMAL,
  TokenType.HEXADECIMAL_WITH_SEPARATORS,
};

String describe(Token token) => switch (token.type) {
  TokenType.IDENTIFIER => 'identifier',
  TokenType.STRING => 'string',
  final type when _numberTokens.contains(type) => 'number',
  _ => '`${token.lexeme}`',
};

/// The innermost node of [root] around [offset] that is not a leaf.
AstNode enclosing(AstNode root, int offset) {
  var node = root;
  while (true) {
    final children = <AstNode>[];
    node.visitChildren(_Collector(children));
    final inner = children.where(
      (c) =>
          c.offset <= offset &&
          offset < c.end &&
          !leafKinds.contains(kindOf(c)),
    );
    if (inner.isEmpty) return node;
    node = inner.first;
  }
}

/// Whether a half-typed [node] would end where the cursor is: a statement
/// other than a block, a class member, a top-level declaration or directive.
bool _isTypedUnit(AstNode node) =>
    (node is Statement && node is! Block) ||
    node is ClassMember ||
    node is CompilationUnitMember ||
    node is Directive ||
    node is EnumConstantDeclaration;

/// Up to [perKind] edits of each of [editKinds] at random tokens of [unit].
///
/// - `truncate` deletes from a token to the end of its statement or member,
///   the way a half-typed line looks.
/// - `close` deletes one `)`, `]`, `}`, `;` or `>`.
/// - `drop` deletes any one token.
/// - `insert` puts an identifier before a token.
List<Edit> sampleEdits(CompilationUnit unit, Random random, int perKind) {
  final tokens = [
    for (Token? t = unit.beginToken; t != null && !t.isEof; t = t.next) t,
  ];
  final closing = [
    for (final t in tokens)
      if (_closingTokens.contains(t.type)) t,
  ];
  final edits = <Edit>[];
  for (final kind in editKinds) {
    final pool = kind == 'close' ? closing : tokens;
    if (pool.isEmpty) continue;
    var made = 0;
    for (var tries = 0; made < perKind && tries < perKind * 10; tries++) {
      final token = pool[random.nextInt(pool.length)];
      final at = enclosing(unit, token.offset);
      final where = '${describe(token)} in ${kindOf(at)}';
      final Edit edit;
      switch (kind) {
        case 'truncate':
          final cut = at.thisOrAncestorMatching(_isTypedUnit);
          final first = switch (cut) {
            AnnotatedNode() => cut.firstTokenAfterCommentAndMetadata,
            _ => cut?.beginToken,
          };
          if (cut == null || first == token) continue;
          edit = (
            kind: kind,
            offset: token.offset,
            length: cut.end - token.offset,
            insert: '',
            context: 'truncate ${kindOf(cut)} at $where',
          );
        case 'insert':
          edit = (
            kind: kind,
            offset: token.offset,
            length: 0,
            insert: 'x ',
            context: 'insert before $where',
          );
        default:
          edit = (
            kind: kind,
            offset: token.offset,
            length: token.length,
            insert: '',
            context: 'drop $where',
          );
      }
      edits.add(edit);
      made++;
    }
  }
  return edits;
}

String applyEdit(String source, Edit edit) =>
    source.replaceRange(edit.offset, edit.offset + edit.length, edit.insert);

/// The non-leaf analyzer nodes that [tree] has a node for with the same span.
Set<Reference> referenceNodes(AnalyzedFile file, Tree tree) {
  final kinds = <(int, int), List<String>>{};
  for (final n in tree.nodes) {
    (kinds[(n.start, n.end)] ??= []).add(n.kind);
  }
  final reference = <Reference>{};
  for (final node in _allNodes(file.unit)) {
    if (node.length == 0 || leafKinds.contains(kindOf(node))) continue;
    final end = position(file.point(node.end));
    for (final start in startOffsets(node)) {
      for (final kind in kinds[(position(file.point(start)), end)] ?? []) {
        reference.add((start: start, end: node.end, kind: kind));
      }
    }
  }
  return reference;
}

/// The rows that ERROR nodes of [tree] cover.
int errorRows(Tree tree) {
  final spans = [for (final e in tree.errors) (e.start >> 32, e.end >> 32)]
    ..sort((a, b) => a.$1.compareTo(b.$1));
  var rows = 0, until = -1;
  for (final (start, end) in spans) {
    if (end <= until) continue;
    rows += end - max<int>(start, until + 1) + 1;
    until = end;
  }
  return rows;
}

/// How many [reference] nodes before and after [edit] the [broken] tree still
/// has with the same kind and the shifted span. A node around the edit has
/// to change, so it does not count.
EditResult score(
  AnalyzedFile file,
  Set<Reference> reference,
  Edit edit,
  Tree broken,
) {
  final lines = Lines(applyEdit(file.source, edit));
  final have = {for (final n in broken.nodes) (n.start, n.end, n.kind)};
  final editEnd = edit.offset + edit.length;
  final shift = edit.insert.length - edit.length;
  final (editRow, _) = lines.point(edit.offset);
  var before = 0, keptBefore = 0, after = 0, keptAfter = 0, reach = 0;
  for (final r in reference) {
    final isBefore = r.end <= edit.offset;
    if (!isBefore && r.start < editEnd) continue;
    final s = lines.point(isBefore ? r.start : r.start + shift);
    final e = lines.point(isBefore ? r.end : r.end + shift);
    final kept = have.contains((position(s), position(e), r.kind));
    if (isBefore) {
      before++;
      if (kept) keptBefore++;
    } else {
      after++;
      if (kept) keptAfter++;
    }
    if (!kept) {
      reach = max(reach, isBefore ? editRow - s.$1 : e.$1 - editRow);
    }
  }
  return (
    path: file.path,
    edit: edit,
    at: file.point(edit.offset),
    before: before,
    keptBefore: keptBefore,
    after: after,
    keptAfter: keptAfter,
    reach: reach,
    errorRows: errorRows(broken),
  );
}

/// Breaks each of [job.files] [job.perKind] times per edit kind, parses the
/// intact and broken files, and scores each edit that leaves the file
/// invalid Dart. Works through the files in batches to bound memory and disk.
Future<({List<EditResult> results, int valid})> recoverShard(
  ({
    String cli,
    Grammar grammar,
    List<(int, String)> files,
    String dir,
    int perKind,
    int seed,
  })
  job,
) async {
  Directory(job.dir).createSync();
  final results = <EditResult>[];
  var valid = 0;
  for (var from = 0; from < job.files.length; from += 100) {
    final planned = <(AnalyzedFile, List<Edit>)>[];
    final paths = <String>[];
    for (final (index, path) in job.files.skip(from).take(100)) {
      final file = analyze(path);
      if (file == null || file.bomBytes > 0) continue;
      final edits = <Edit>[];
      paths.add(path);
      for (final edit in sampleEdits(
        file.unit,
        Random(job.seed + index),
        job.perKind,
      )) {
        final broken = applyEdit(file.source, edit);
        if (parseValid(broken) != null) {
          valid++;
          continue;
        }
        final out = p.join(job.dir, '$index-${edits.length}.dart');
        File(out).writeAsStringSync(broken);
        paths.add(out);
        edits.add(edit);
      }
      planned.add((file, edits));
    }
    final trees = StreamIterator(
      parseTrees(job.cli, job.grammar, paths, p.join(job.dir, 'paths.txt')),
    );
    Future<Tree> next() async {
      await trees.moveNext();
      return trees.current;
    }

    for (final (file, edits) in planned) {
      final intact = await next();
      final reference = intact.failed ? null : referenceNodes(file, intact);
      for (final edit in edits) {
        final broken = await next();
        if (reference != null) {
          results.add(score(file, reference, edit, broken));
        }
      }
    }
    await trees.cancel();
    for (final path in paths.where((f) => p.isWithin(job.dir, f))) {
      File(path).deleteSync();
    }
  }
  return (results: results, valid: valid);
}

Future<void> recovery(ArgResults args) async {
  final grammarDir = switch (args['grammar']) {
    final String g => p.normalize(p.absolute(g)),
    _ => repoRoot,
  };
  final jobs = int.parse(args['jobs'] as String);
  final count = int.parse(args['files'] as String);
  final perKind = int.parse(args['edits'] as String);
  final seed = int.parse(args['seed'] as String);
  final maxBytes = int.parse(args['max-bytes'] as String);
  final worst = int.parse(args['worst'] as String);
  final files = [
    ...args.rest,
    if (args['paths'] case final String list)
      ...File(list).readAsLinesSync().where((l) => l.trim().isNotEmpty),
  ]..shuffle(Random(seed));
  final sample = files
      .where((f) => File(f).lengthSync() <= maxBytes)
      .take(count)
      .toList()
      .indexed
      .toList();
  final temp = Directory.systemTemp.createTempSync('analyzer_ast');
  try {
    final grammar = await buildGrammar(grammarDir, temp);
    final cli = treeSitterCli();
    final shards = [
      for (var j = 0; j < jobs; j++)
        [for (var i = j; i < sample.length; i += jobs) sample[i]],
    ].where((shard) => shard.isNotEmpty).toList();
    final outcomes = await Future.wait([
      for (final (j, shard) in shards.indexed)
        Isolate.run(
          () => recoverShard((
            cli: cli,
            grammar: grammar,
            files: shard,
            dir: p.join(temp.path, 'shard-$j'),
            perKind: perKind,
            seed: seed,
          )),
        ),
    ]);
    final results = [for (final o in outcomes) ...o.results];
    final valid = outcomes.fold(0, (n, o) => n + o.valid);
    stdout.writeln(
      '${sample.length} files, ${results.length} edits scored, $valid more '
      'left the file valid Dart',
    );
    _recoveryReport(results, worst);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

int _lost(EditResult r) => r.before - r.keptBefore + r.after - r.keptAfter;

int _percentile(List<int> values, double q) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

String _pct(int part, int whole) =>
    whole == 0 ? '-' : '${(100 * part / whole).toStringAsFixed(1)}%';

void _recoveryReport(List<EditResult> results, int worst) {
  stdout
    ..writeln()
    ..writeln(
      '${'kind'.padRight(10)}${'edits'.padLeft(7)}'
      '${'kept before'.padLeft(13)}${'kept after'.padLeft(12)}'
      '${'lossless'.padLeft(10)}${'reach p50/p90/max'.padLeft(19)}'
      '${'ERROR rows p50/p90'.padLeft(20)}',
    );
  for (final kind in [...editKinds, 'all']) {
    final rs = [
      for (final r in results)
        if (kind == 'all' || r.edit.kind == kind) r,
    ];
    final reach = [for (final r in rs) r.reach];
    final rows = [for (final r in rs) r.errorRows];
    stdout.writeln(
      '${kind.padRight(10)}${'${rs.length}'.padLeft(7)}'
      '${_pct(rs.fold(0, (n, r) => n + r.keptBefore), rs.fold(0, (n, r) => n + r.before)).padLeft(13)}'
      '${_pct(rs.fold(0, (n, r) => n + r.keptAfter), rs.fold(0, (n, r) => n + r.after)).padLeft(12)}'
      '${_pct(rs.where((r) => _lost(r) == 0).length, rs.length).padLeft(10)}'
      '${'${_percentile(reach, .5)}/${_percentile(reach, .9)}/${_percentile(reach, 1)}'.padLeft(19)}'
      '${'${_percentile(rows, .5)}/${_percentile(rows, .9)}'.padLeft(20)}',
    );
  }

  final byContext = <String, List<EditResult>>{};
  for (final r in results) {
    (byContext[r.edit.context] ??= []).add(r);
  }
  final contexts = byContext.entries.toList()
    ..sort(
      (a, b) =>
          b.value.fold(0, (n, r) => n + _lost(r)) -
          a.value.fold(0, (n, r) => n + _lost(r)),
    );
  stdout
    ..writeln()
    ..writeln('contexts by nodes lost')
    ..writeln(
      '${'lost'.padLeft(8)}${'edits'.padLeft(7)}${'lossless'.padLeft(10)}'
      '${'reach p90'.padLeft(11)}  context',
    );
  for (final MapEntry(key: context, value: rs) in contexts.take(40)) {
    stdout.writeln(
      '${'${rs.fold(0, (n, r) => n + _lost(r))}'.padLeft(8)}'
      '${'${rs.length}'.padLeft(7)}'
      '${_pct(rs.where((r) => _lost(r) == 0).length, rs.length).padLeft(10)}'
      '${'${_percentile([for (final r in rs) r.reach], .9)}'.padLeft(11)}'
      '  $context',
    );
  }

  stdout
    ..writeln()
    ..writeln('edits that lose the most nodes');
  for (final r in ([
    ...results,
  ]..sort((a, b) => _lost(b) - _lost(a))).take(worst)) {
    final (row, column) = r.at;
    stdout.writeln(
      '${_lost(r)}/${r.before + r.after}\treach ${r.reach}\t'
      '${r.path}:${row + 1}:${column + 1}\t${r.edit.context}\t'
      'length ${r.edit.length}',
    );
  }
}
