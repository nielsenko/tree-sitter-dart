void f() {
  var a = 1 + 2 * 3;
  //        ^ operator
  //            ^ operator
  var b = x is String;
  //        ^ keyword.operator
  var c = y as int;
  //        ^ keyword.operator
  var d = !done;
  //      ^ operator
  var e = n++;
  //       ^ operator
  var g = p ?? q;
  //        ^ operator
  var h = (s) => s;
  //          ^ operator
}
