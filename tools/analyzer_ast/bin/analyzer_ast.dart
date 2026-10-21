/// Dumps the Dart analyzer's AST, or measures how faithfully a tree-sitter
/// grammar reproduces it.
///
///   dart run bin/analyzer_ast.dart dump <file.dart>
///   dart run bin/analyzer_ast.dart compare [--grammar <dir>]...
///       [--misses] [--kind <Kind>]... (<file.dart>... | --paths <list>)
///   dart run bin/analyzer_ast.dart crossings [--grammar <dir>] [--jobs <n>]
///       (<file.dart>... | --paths <list>)
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
/// `--grammar` takes a grammar directory (default: this repository). For
/// `compare` it may be repeated to compare several grammars side by side.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
  final parser = ArgParser()
    ..addCommand('dump')
    ..addCommand('compare', compareParser)
    ..addCommand('crossings', crossingsParser);
  final results = parser.parse(args);
  switch (results.command) {
    case ArgResults(name: 'dump', rest: [final path]):
      dump(path);
    case final ArgResults command? when command.name == 'compare':
      await compare(command);
    case final ArgResults command? when command.name == 'crossings':
      await crossings(command);
    default:
      stderr.writeln(
        'usage: analyzer_ast dump <file.dart>\n'
        '       analyzer_ast compare [options] <file.dart>...\n'
        '${compareParser.usage}\n'
        '       analyzer_ast crossings [options] <file.dart>...\n'
        '${crossingsParser.usage}',
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
  for (final featureSet in _featureSets) {
    final result = parseString(
      content: source,
      featureSet: featureSet,
      throwIfDiagnostics: false,
    );
    if (!result.errors.any(
      (e) => e.diagnosticCode.type == DiagnosticType.SYNTACTIC_ERROR,
    )) {
      return AnalyzedFile(path, source, result.unit, bomBytes: bom ? 3 : 0);
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

class AnalyzedFile {
  AnalyzedFile(this.path, this.source, this.unit, {required this.bomBytes}) {
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

  final String path;
  final String source;
  final CompilationUnit unit;

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
    final starts = {
      node.offset,
      if (node is AnnotatedNode) ...[
        node.firstTokenAfterCommentAndMetadata.offset,
        if (node.metadata.isNotEmpty) node.metadata.first.offset,
      ],
    };
    if (starts.any((s) => spans.contains((position(file.point(s)), end)))) {
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
  File(job.list).writeAsStringSync(job.files.join('\n'));
  final process = await Process.start(job.cli, [
    'parse',
    '--lib-path',
    job.grammar.lib,
    '--lang-name',
    job.grammar.language,
    '--paths',
    job.list,
  ]);
  final errors = process.stderr.transform(utf8.decoder).join();
  final results = <FileResult>[];
  List<Node>? tree;
  var failed = false;
  void finish() {
    final path = job.files[results.length];
    results.add(
      failed
          ? (
              path: path,
              crossings: const {},
              locations: const [],
              matched: 0,
              nonLeaf: 0,
              skipped: 'tree-sitter ERROR or MISSING',
            )
          : checkFile(path, tree!, locations: job.locations),
    );
  }

  await for (final line
      in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    if (line.startsWith('(')) {
      if (tree != null) finish();
      tree = [];
      failed = false;
    } else if (tree == null || !line.startsWith(' ')) {
      continue;
    }
    for (final m in _nodePattern.allMatches(line)) {
      final name = m[1]!;
      if (name == 'ERROR' || name.startsWith('MISSING')) {
        failed = true;
        continue;
      }
      final start = position((int.parse(m[2]!), int.parse(m[3]!)));
      final end = position((int.parse(m[4]!), int.parse(m[5]!)));
      if (start != end) tree.add((start: start, end: end, kind: name));
    }
  }
  if (tree != null) finish();
  await process.exitCode;
  if (results.length != job.files.length) {
    throw StateError(
      'expected ${job.files.length} trees, got ${results.length}: '
      '${await errors}',
    );
  }
  return results;
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
