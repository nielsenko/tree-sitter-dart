class CounterPage extends StatefulWidget {
  //  ^ definition.class
  const CounterPage({super.key, required this.title});
  //    ^ definition.method

  final String title;

  @override
  State<CounterPage> createState() => _CounterPageState();
  //                 ^ definition.method
  //                                  ^ reference.call
}

class _CounterPageState extends State<CounterPage> {
  //  ^ definition.class
  int _count = 0;

  void _increment() => setState(() => _count++);
  //   ^ definition.method
  //                   ^ reference.call

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      //   ^ reference.call
      appBar: AppBar(title: Text(widget.title)),
      //      ^ reference.call
      //                    ^ reference.call
      body: Center(child: Text('$_count')),
      //    ^ reference.call
      //                  ^ reference.call
      floatingActionButton: FloatingActionButton(
        //                  ^ reference.call
        onPressed: _increment,
        child: const Icon(Icons.add),
        //           ^ reference.class
      ),
    );
  }
}

Future<void> main() async {
  //         ^ definition.function
  WidgetsFlutterBinding.ensureInitialized();
  //                    ^ reference.call
  final controller = StreamController<int>.broadcast();
  //                 ^ reference.class
  controller.stream.listen(print);
  //                ^ reference.call
  runApp(const MaterialApp(home: CounterPage(title: 'Counter')));
  // <- reference.call
  //           ^ reference.class
  //                             ^ reference.call
}
