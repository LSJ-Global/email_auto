import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:http/http.dart' as http;

import 'edm_job_service.dart';

typedef SaveDownloadedBytes =
    Future<void> Function({
      required String name,
      required Uint8List bytes,
      required String mimeType,
    });

class FileDownloadService {
  FileDownloadService({http.Client? client, SaveDownloadedBytes? saveBytes})
    : _client = client ?? http.Client(),
      _saveBytes = saveBytes ?? _saveWithBrowser;

  final http.Client _client;
  final SaveDownloadedBytes _saveBytes;

  Future<void> download(EdmResultFile file) async {
    final response = await _client.get(Uri.parse(file.downloadUrl));
    if (response.statusCode != 200) {
      throw FileDownloadException(response.statusCode);
    }
    await _saveBytes(
      name: file.displayName,
      bytes: response.bodyBytes,
      mimeType: _mimeType(file.type),
    );
  }

  static Future<void> _saveWithBrowser({
    required String name,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    await FileSaver.instance.saveFile(
      name: name,
      bytes: bytes,
      includeExtension: false,
      mimeType: MimeType.custom,
      customMimeType: mimeType,
    );
  }

  static String _mimeType(String type) {
    return switch (type) {
      'html' => 'text/html; charset=utf-8',
      'eml' => 'message/rfc822',
      'oft' => 'application/vnd.ms-outlook',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}

class FileDownloadException implements Exception {
  const FileDownloadException(this.statusCode);

  final int statusCode;
}
