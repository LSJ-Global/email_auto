import 'dart:typed_data';

import 'package:edm_auto_web/services/edm_job_service.dart';
import 'package:edm_auto_web/services/file_download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const file = EdmResultFile(
    name: 'sample.html',
    type: 'html',
    size: 3,
    downloadUrl: 'https://example.com/sample.html',
  );

  test('downloads bytes and saves them with the original file name', () async {
    String? savedName;
    Uint8List? savedBytes;
    String? savedMimeType;
    final service = FileDownloadService(
      client: MockClient(
        (_) async => http.Response.bytes(const [1, 2, 3], 200),
      ),
      saveBytes: ({required name, required bytes, required mimeType}) async {
        savedName = name;
        savedBytes = bytes;
        savedMimeType = mimeType;
      },
    );

    await service.download(file);

    expect(savedName, 'sample.html');
    expect(savedBytes, Uint8List.fromList(const [1, 2, 3]));
    expect(savedMimeType, 'text/html; charset=utf-8');
  });

  test('throws when the remote file request fails', () async {
    final service = FileDownloadService(
      client: MockClient((_) async => http.Response('missing', 404)),
    );

    expect(() => service.download(file), throwsA(isA<FileDownloadException>()));
  });

  test(
    'hides the account scope marker from the downloaded file name',
    () async {
      String? savedName;
      final service = FileDownloadService(
        client: MockClient(
          (_) async => http.Response.bytes(const [1, 2, 3], 200),
        ),
        saveBytes: ({required name, required bytes, required mimeType}) async {
          savedName = name;
        },
      );
      const scopedFile = EdmResultFile(
        name: 'sample__acct_43d021786db1.eml',
        type: 'eml',
        size: 3,
        downloadUrl: 'https://example.com/scoped.eml',
      );

      await service.download(scopedFile);

      expect(scopedFile.displayName, 'sample.eml');
      expect(savedName, 'sample.eml');
    },
  );
}
