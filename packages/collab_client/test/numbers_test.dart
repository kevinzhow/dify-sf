/// Protocol 1.5: fractional numbers (Dify settings such as temperature 0.7). Mirrors the server's numbersHaveOneRepresentation.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

void main() {
  test('every number has one representation', () {
    expect(Value.number(1.0), const VInt(1));
    expect(Value.number(0.7), const VDouble(0.7));
    expect(Value.number(3), const VInt(3));
    expect(const VDouble(2.0).structuralProblem, isNotNull);
    expect(const VDouble(double.nan).structuralProblem, isNotNull);
    expect(const VDouble(0.7).structuralProblem, isNull);
  });

  test('JSON round trip keeps the form', () {
    final v = Value.fromJson(jsonDecode('{"t": 0.7, "n": 3, "w": 2.0}'));
    expect(v, const VMap({'t': VDouble(0.7), 'n': VInt(3), 'w': VInt(2)}));
    expect(Value.fromJson(jsonDecode(jsonEncode(v.toJson()))), v);
    expect(jsonEncode(const VDouble(0.7).toJson()), '0.7');
  });
}
