library highlight_dart3;

// <- keyword

import 'dart:async' as async_lib show Future hide Stream;

// <- keyword
//     ^ string
//                  ^ keyword
//                               ^ keyword
//                                           ^ keyword
import 'package:a/a.dart' deferred as lazy;

//                        ^ keyword
export 'src/b.dart' show B;

// <- keyword

sealed class Shape {}
// <- keyword
//     ^ keyword
//           ^ type

final class Circle extends Shape {
  //               ^ keyword
  //                       ^ type
  final double radius;
  //    ^ type.builtin
  //           ^ variable
  Circle(this.radius);
  // <- constructor
  //     ^ keyword
  //          ^ variable.parameter
}

base mixin Logger {}
// <- keyword
//   ^ keyword
//         ^ type

interface class Api {}
// <- keyword
//              ^ type

class Point(final int x, final int y);
//    ^ type
//          ^ keyword
//                    ^ variable.parameter

class const Origin.zero(final int x);
//    ^ keyword
//          ^ type
//                 ^ constructor

extension type const Meters(int value) implements num {}
// <- keyword
//        ^ keyword
//                   ^ type
//                              ^ property
//                                     ^ keyword
//                                                ^ type.builtin

typedef Pair = (int count, {String label});
// <- keyword
//      ^ type.definition
//                  ^ variable
//                          ^ type.builtin
//                                 ^ variable

enum Planet {
  mercury(3.7),
  // <- constant
  //      ^ number.float
  venus(8.9);

  const Planet(this.gravity);
  // <- keyword
  //    ^ constructor
  //                ^ variable.parameter
  final double gravity;
  //           ^ variable
}

String describe(Object shape) {
  //   ^ function
  //            ^ type.builtin
  //                   ^ variable.parameter
  var rec = (1, tag: 'x');
  // <- keyword
  //  ^ variable
  //            ^ property
  return switch (shape) {
    //   ^ keyword
    Circle(radius: var len) when len > 1 => 'big',
    // <- type
    //     ^ property
    //                 ^ variable
    //                      ^ keyword
    //                                   ^ operator
    //                                      ^ string
    Point(:final y) => 'point $y',
    //           ^ variable
    //                        ^ punctuation.special
    [int first, ...] => 'list',
    //   ^ variable
    //          ^ operator
    {'key': String value} => value,
    //             ^ variable
    (int a, label: var b) => '$a$b',
    //      ^ property
    _ => 'other',
  };
}

void matches(Object o) {
  if (o case > 0 && < 10) {}
  // <- keyword
  //    ^ keyword
  //         ^ operator
  //             ^ operator
  //                ^ operator
  if (o case Circle(:var radius) when radius > 0) {}
  //                     ^ variable
  switch (o) {
    case int k:
      //     ^ variable
      break;
    //^ keyword
    default:
      return;
    //^ keyword
  }
  for (final x in xs) print(x);
  // <- keyword
  //   ^ keyword
  //         ^ variable
  //           ^ keyword
  //                  ^ function.call
}

void shorthands() {
  Color c = .red;
  // <- type
  //    ^ variable
  //         ^ property
  Color d = .fromHex(0xff);
  //         ^ function.method.call
  //                 ^ number
  var items = [?maybe, ...?more];
  //  ^ variable
  //                   ^ operator
}

Stream<int> countdown(int from) async* {
  //        ^ function
  //                      ^ variable.parameter
  //                            ^ keyword
  for (var i = from; i > 0; i--) {
    //     ^ variable
    //                 ^ operator
    //                       ^ operator
    yield i;
    // <- keyword
  }
  yield* other();
  // <- keyword
  //     ^ function.call
}

Future<void> load() async {
  //   ^ type.builtin
  //         ^ function
  //                ^ keyword
  try {
    await fetch();
    // <- keyword
    //    ^ function.call
  } on FormatException catch (e) {
    // <- keyword
    // ^ type
    //                 ^ keyword
    rethrow;
    // <- keyword
  } finally {
    // <- keyword
    close();
  }
}

void ops(int a, int b, String? name) {
  var q = a ~/ b;
  //        ^ operator
  q += 1;
  //^ operator
  var s = a << 2 | b >>> 1;
  //        ^ operator
  //             ^ operator
  //                 ^ operator
  var t = a is int && b is! String;
  //        ^ keyword.operator
  //               ^ operator
  var u = a as num;
  //        ^ keyword.operator
  //           ^ type.builtin
  var len = name?.length ?? 0;
  //            ^ punctuation.delimiter
  //              ^ property
  //                     ^ operator
  //                        ^ number
  var buf = StringBuffer()..write('a');
  //        ^ function.call
  //                      ^ operator
  //                        ^ function.method.call
  var sym = #foo;
  //         ^ string.special.symbol
  var greeting = 'Hello, ${user.name}!\n';
  //                     ^ punctuation.special
  //                            ^ property
  //                                  ^ string.escape
  var none = null;
  //         ^ constant.builtin
  var yes = true;
  //        ^ boolean
}

class Temp {
  double _c = 0;
  double get fahrenheit => _c * 9 / 5 + 32;
  //     ^ keyword
  //         ^ function.method
  //                          ^ operator
  //                                  ^ operator
  set fahrenheit(double deg) => _c = (deg - 32) * 5 / 9;
  // <- keyword
  //  ^ function.method
  //                    ^ variable.parameter
  Temp operator +(Temp other) => Temp();
  //   ^ keyword
  //                   ^ variable.parameter
  static Temp parse(String raw) => Temp();
  // <- keyword
  //          ^ function.method
  //                       ^ variable.parameter
  factory Temp.zero() = Temp;
  // <- keyword
  //           ^ constructor
}

T firstOf<T extends Comparable<T>>(List<T> items) => items.first;
//^ function
//        ^ type.parameter
//          ^ keyword
//                  ^ type
//                                         ^ variable.parameter
//                                                         ^ property

class Config {
  late final String path;
  // <- keyword
  //                ^ variable
  Config({required this.path});
  //      ^ keyword
  //                    ^ variable.parameter
  @Deprecated('use other')
  // <- attribute
  void old(@unused int a) {}
  //   ^ function.method
  //        ^ attribute
}

Widget build(BuildContext context) {
  //   ^ function
  //         ^ type
  //                      ^ variable.parameter
  return Padding(
    //   ^ function.call
    padding: const EdgeInsets.all(8),
    // <- variable.parameter
    //             ^ type
    //                            ^ number
    child: Text('hi', style: theme.textTheme.bodyLarge),
    // <- variable.parameter
    //     ^ function.call
    //                ^ variable.parameter
    //                             ^ property
    //                                       ^ property
  );
}
