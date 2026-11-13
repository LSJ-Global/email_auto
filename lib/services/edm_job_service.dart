import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';

class EdmJobSubmission {
  const EdmJobSubmission({
    required this.imagePath,
    required this.targetFolder,
    required this.status,
    this.displayName,
    this.commitSha,
    this.commitUrl,
    this.workflowRunId,
    this.workflowRunUrl,
  });

  final String imagePath;
  final String targetFolder;
  final String status;
  final String? displayName;
  final String? commitSha;
  final String? commitUrl;
  final int? workflowRunId;
  final String? workflowRunUrl;

  String get label => displayName ?? targetFolder;

  bool get isAccountScoped =>
      RegExp(r'__acct_[0-9a-f]{12}$').hasMatch(targetFolder);

  factory EdmJobSubmission.fromJson(Map<String, dynamic> json) {
    return EdmJobSubmission(
      imagePath: json['imagePath'] as String,
      targetFolder: json['targetFolder'] as String,
      status: json['status'] as String,
      displayName: json['displayName'] as String?,
      commitSha: json['commitSha'] as String?,
      commitUrl: json['commitUrl'] as String?,
      workflowRunId: json['workflowRunId'] as int?,
      workflowRunUrl: json['workflowRunUrl'] as String?,
    );
  }

  factory EdmJobSubmission.fromMap(Map<String, dynamic> map) =>
      EdmJobSubmission.fromJson(map);

  Map<String, dynamic> toJson() => {
    'imagePath': imagePath,
    'targetFolder': targetFolder,
    'status': status,
    'displayName': displayName,
    'commitSha': commitSha,
    'commitUrl': commitUrl,
    'workflowRunId': workflowRunId,
    'workflowRunUrl': workflowRunUrl,
  };
}

class EdmResultFile {
  const EdmResultFile({
    required this.name,
    required this.type,
    required this.size,
    required this.downloadUrl,
    this.htmlUrl,
  });

  final String name;
  final String type;
  final int size;
  final String downloadUrl;
  final String? htmlUrl;

  String get displayName =>
      name.replaceAll(RegExp(r'__acct_[0-9a-f]{12}', caseSensitive: false), '');

  factory EdmResultFile.fromJson(Map<String, dynamic> json) {
    return EdmResultFile(
      name: json['name'] as String,
      type: json['type'] as String,
      size: json['size'] as int? ?? 0,
      downloadUrl: json['downloadUrl'] as String,
      htmlUrl: json['htmlUrl'] as String?,
    );
  }

  factory EdmResultFile.fromMap(Map<String, dynamic> map) =>
      EdmResultFile.fromJson(map);

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'size': size,
    'downloadUrl': downloadUrl,
    'htmlUrl': htmlUrl,
  };
}

class EdmJobStatus {
  const EdmJobStatus({
    required this.targetFolder,
    required this.status,
    required this.folderUrl,
    required this.files,
  });

  final String targetFolder;
  final String status;
  final String folderUrl;
  final List<EdmResultFile> files;

  bool get isComplete => status == 'complete';

  factory EdmJobStatus.fromJson(Map<String, dynamic> json) {
    final files = (json['files'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              EdmResultFile.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    return EdmJobStatus(
      targetFolder: json['targetFolder'] as String,
      status: json['status'] as String,
      folderUrl: json['folderUrl'] as String,
      files: files,
    );
  }

  factory EdmJobStatus.fromMap(Map<String, dynamic> map) =>
      EdmJobStatus.fromJson(map);

  Map<String, dynamic> toJson() => {
    'targetFolder': targetFolder,
    'status': status,
    'folderUrl': folderUrl,
    'files': files.map((file) => file.toJson()).toList(),
  };
}

class EdmJobService {
  EdmJobService({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'asia-northeast3');

  final FirebaseFunctions _functions;

  Future<EdmJobSubmission> submit({
    required String fileName,
    required Uint8List bytes,
    List<String> landingUrls = const [],
  }) async {
    final callable = _functions.httpsCallable(
      'submitEdmJob',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    final response = await callable.call<Map<String, dynamic>>({
      'fileName': fileName,
      'contentBase64': base64Encode(bytes),
      'landingUrls': landingUrls,
    });
    return EdmJobSubmission.fromMap(response.data);
  }

  Future<EdmJobStatus> getStatus({required String targetFolder}) async {
    final callable = _functions.httpsCallable(
      'getEdmJobStatus',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final response = await callable.call<Map<String, dynamic>>({
      'targetFolder': targetFolder,
    });
    return EdmJobStatus.fromMap(response.data);
  }

  Future<void> deleteJob({
    required String targetFolder,
    required String imagePath,
  }) async {
    final callable = _functions.httpsCallable(
      'deleteEdmJob',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    await callable.call<Map<String, dynamic>>({
      'targetFolder': targetFolder,
      'imagePath': imagePath,
    });
  }
}
