import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/notices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const op = SetField('llm', ConfigKey(['prompt']), VString('mine'));
  String titleOf(String id) => id.toUpperCase();
  const id = 's-0123456789abcdef0123456789abcdef';

  test('a conflict notice names the author by display name when the server sent one (protocol 1.3)', () {
    final named = describeRefusal(
      op,
      const Conflict(node: 'llm', field: ConfigKey(['prompt']), seq: 4, by: id, byName: 'Kim'),
      titleOf,
    );
    expect(named.message, startsWith('Kim changed '));
  });

  test('without a display name it falls back to the short id tag', () {
    final plain = describeRefusal(
      op,
      const Conflict(node: 'llm', field: ConfigKey(['prompt']), seq: 4, by: id),
      titleOf,
    );
    expect(plain.message, startsWith('User cdef changed '));
  });
}
