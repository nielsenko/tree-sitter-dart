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
