class Shape {
  //    ^ definition.class
  double area() => 0;
  //     ^ definition.method
}

void render(Shape s) {
  //   ^ definition.function
  s.area();
  //  ^ reference.call
}

enum Status { ready }

//   ^ definition.class
typedef Handler = void Function();

//      ^ definition.type
class Boxed {
  factory Boxed() = Box.of.unit;
  //      ^ definition.method
}
