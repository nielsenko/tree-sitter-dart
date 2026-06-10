enum Color { red, green }

// <- keyword
//   ^ type
//           ^ constant
typedef Predicate = bool Function(int);

// <- keyword
//      ^ type.definition
mixin Walks {}

// <- keyword
//    ^ type
extension type Meters(double value) {}

// <- keyword
//             ^ type
@Deprecated('x')
// <- attribute
// ^ attribute
class Old {}

class Node {
  Node(this.next);
  //^ constructor
  Node? next;
  //^ type
  static Node origin() => Node.zero;
  //       ^ type
}

@foo.bar('y')
// <- attribute
//   ^ attribute
//      ^ punctuation.bracket
class Tagged {}
