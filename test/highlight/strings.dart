var a = r'raw $not';
//      ^ string
var b = 'esc\n done';
//          ^ string.escape
var c = """multi
line""";
// <- string
var d = #symbol;
//       ^ string.special.symbol
var e = 'pre ${value} post';
//           ^ punctuation.special
//            ^ punctuation.special
//             ^ variable
