List<int?> nums = [];
// <- type.builtin
//   ^ type.builtin
Map<String, void Function(int)> handlers = {};
// <- type.builtin
//          ^ type.builtin
dynamic anything;
// <- type.builtin
final Object obj = 0;
// <- keyword
//    ^ type.builtin
T identity<T extends Comparable<T>>(T v) => v;
// <- type
//         ^ type.parameter
