import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dify_sf_app/src/public_app/public_inputs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fields = [
    {'variable': 'q', 'type': 'text-input', 'hide': true},
    {'variable': 'n', 'type': 'number'},
    {'variable': 'yes', 'type': 'checkbox'},
    {'variable': 'sys.user_id', 'type': 'text-input'},
  ];
  test('plain and compressed hidden launch values use only declared inputs', () {
    expect(
      publicInputsFromQuery(fields, {
        'q': 'plain',
        'n': '2',
        'yes': 'true',
        'sys.user_id': 'forged',
        'other': 'ignored',
      }),
      {'q': 'plain', 'n': 2, 'yes': true},
    );
    final encoded = base64Encode(GZipEncoder().encodeBytes(utf8.encode('中文 query')));
    expect(publicInputsFromQuery(fields, {'q': encoded}), {'q': '中文 query'});
  });
  test('compressed link inputs cannot expand without a limit', () {
    final encoded = base64Encode(GZipEncoder().encodeBytes(utf8.encode('x' * 65537)));
    expect(() => publicInputsFromQuery(fields, {'q': encoded}), throwsA(anything));
  });
}
