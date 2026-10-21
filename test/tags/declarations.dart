abstract class Animal implements Comparable<Animal> {}
//             ^ definition.class
//                               ^ reference.implementation

mixin Swimmer on Animal {}
//    ^ definition.class

extension Shout on String {}
//        ^ definition.class

extension type UserId(int raw) {}
//             ^ definition.class

enum Level { low, high }
//   ^ definition.class
//           ^ definition.constant
//                ^ definition.constant

typedef Callback = void Function(int);
//      ^ definition.type

typedef Mapper<T> = T Function(T);
//      ^ definition.type

int counter = 0;
//  ^ definition.variable

const limit = 10, floor = 1;
//    ^ definition.variable
//                ^ definition.variable

external int nativeCount;
//           ^ definition.variable

void topLevel() {}
//   ^ definition.function

int get answer => 42;
//      ^ definition.function

set answer(int value) {}
//  ^ definition.function

external void nativeCall();
//            ^ definition.function

class Dog extends Animal with Swimmer implements Pet, Guard {
  //  ^ definition.class
  //                                             ^ reference.implementation
  //                                                  ^ reference.implementation
  Dog();
  // <- definition.method
  Dog.named(this.name);
  //  ^ definition.method
  const Dog.frozen() : name = '';
  //        ^ definition.method
  factory Dog.adopt() => Dog();
  //          ^ definition.method
  //                     ^ reference.call
  factory Dog.stray() = Dog.named;
  //          ^ definition.method

  String name = '';

  void bark() => print('woof');
  //   ^ definition.method
  //             ^ reference.call
  String get label => name;
  //         ^ definition.method
  set label(String value) => name = value;
  //  ^ definition.method
  Dog operator +(Dog other) => this;
  //           ^ definition.method
  static Dog parse(String raw) => Dog.named(raw);
  //         ^ definition.method
  //                                  ^ reference.call
}

class Point(final int x, final int y);
//    ^ definition.class

class const Origin.zero(final int x);
//          ^ definition.class
//                 ^ definition.method

void main() {
  // ^ definition.function
  final dog = Dog.adopt();
  //              ^ reference.call
  dog.bark();
  //  ^ reference.call
  dog?.bark();
  //   ^ reference.call
  dog
    ..bark()
    ..label = 'x';
  //   ^ reference.call
  topLevel();
  // <- reference.call
  var a = new Animal2();
  //          ^ reference.class
  var b = const Insets.all(8);
  //            ^ reference.class
  var c = Box<int>.of(1);
  //      ^ reference.class
  Level l = .parse('low');
  //         ^ reference.call
}
