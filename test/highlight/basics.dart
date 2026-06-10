/// Doc comment.
// <- comment.documentation
// Plain comment.
// <- comment
class Point {
  // <- keyword
  //    ^ type
  final int x;
  //    ^ type.builtin
  Point({required this.x});
  // ^ constructor
  //     ^ keyword
  factory Point.origin() => Point(x: 0);
  // ^ keyword
  //            ^ constructor
}

void main() {
  // <- type.builtin
  //  ^ function
  var p = Point(x: 1 + 2);
  //      ^ function.call
  //                 ^ operator
  final s = p.x..toString();
  //          ^ property
  print('hi $s done');
  //^ function.call
  //        ^ punctuation.special
  //         ^ variable
}

int await = 1;
//  ^ variable
int yield = 2;
//  ^ variable
Future<void> later() async {
  await go();
  //^ keyword
}

Stream<int> gen() async* {
  yield 1;
  //^ keyword
}
