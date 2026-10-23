import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _Tokens implements TokenProvider {
  @override
  String? accessToken = 'old-access';
  int refreshes = 0;
  @override
  Future<bool> refresh({String? failedToken}) async {
    expect(failedToken, 'old-access');
    refreshes++;
    accessToken = 'new-access';
    return true;
  }
}

void main() {
  test('multipart upload retains binary bytes and is replayable after token refresh', () async {
    final requests = <http.Request>[];
    final auth = _Tokens();
    final bytes = [0, 255, 1, 13, 10, 200];
    final api = HttpFilesApi(Uri.parse('https://server.test/base'), auth: auth, client: MockClient((req) async {
      requests.add(req);
      if (requests.length == 1) return http.Response('{"error":{"code":"unauthorized","message":"expired"}}', 401);
      return http.Response(jsonEncode({
        'id': 'file-id', 'name': 'photo.png', 'size': bytes.length,
        'extension': 'png', 'mime_type': 'image/png', 'preview_url': 'https://files.test/signed',
      }), 201);
    }));
    addTearDown(api.close);
    final file = await api.upload(bytes, filename: 'photo.png', mimeType: 'image/png');
    expect(file.id, 'file-id');
    expect(auth.refreshes, 1);
    expect(requests.map((r) => r.headers['authorization']), ['Bearer old-access', 'Bearer new-access']);
    expect(requests.last.url.path, '/base/v1/files/upload');
    expect(requests.first.bodyBytes, requests.last.bodyBytes);
    expect(requests.last.bodyBytes, containsAllInOrder(bytes));
    expect(latin1.decode(requests.last.bodyBytes), contains('filename="photo.png"'));
    expect(requests.last.headers['content-type'], startsWith('multipart/form-data; boundary='));
  });

  test('limits, UTF8 preview, and structured refusal are preserved', () async {
    final api = HttpFilesApi(Uri.parse('https://server.test'), client: MockClient((req) async {
      if (req.url.path == '/v1/files/upload' && req.method == 'GET') {
        return http.Response('{"file_size_limit":15,"image_file_size_limit":10,"audio_file_size_limit":50,'
            '"video_file_size_limit":100,"batch_count_limit":5,"workflow_file_upload_limit":10}', 200);
      }
      if (req.method == 'GET') return http.Response(jsonEncode({'content': '🌲é中'}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      return http.Response('{"error":{"code":"file_too_large","message":"File size exceeded."}}', 413);
    }));
    addTearDown(api.close);
    expect((await api.limits()).imageMiB, 10);
    expect(await api.textPreview('file-id'), '🌲é中');
    await expectLater(api.upload([1], filename: 'large.txt'),
      throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 413)
          .having((e) => e.code, 'code', 'file_too_large')));
  });

  test('avatar profile uses an id and system features fail closed', () async {
    http.Request? sent;
    final api = HttpAuthApi(Uri.parse('https://server.test'), client: MockClient((req) async {
      sent = req;
      return http.Response('{"id":"account","email":"owner@example.test","name":"Owner","avatar_url":"https://files.test/signed"}', 200);
    }));
    addTearDown(api.close);
    final account = await api.updateProfile('access', avatar: 'upload-id');
    expect(sent?.method, 'PATCH');
    expect(jsonDecode(sent!.body), {'avatar': 'upload-id'});
    expect(account.avatarUrl, 'https://files.test/signed');
    expect(SystemFeatures.fromJson(<String, Object?>{}).fileUpload, isFalse);
    expect(SystemFeatures.fromJson({'enable_file_upload': true}).fileUpload, isTrue);
    await api.updateProfile('access', avatar: '');
    expect(jsonDecode(sent!.body), {'avatar': ''});
  });
}
