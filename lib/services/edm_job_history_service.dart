import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/edm_job_record.dart';
import 'edm_job_service.dart';

class EdmJobHistoryService {
  EdmJobHistoryService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _jobs(String userId) =>
      _firestore.collection('users').doc(userId).collection('jobs');

  Stream<List<EdmJobRecord>> watchJobs(String userId) {
    return _jobs(userId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (document) => EdmJobRecord.fromJson({
                  ...document.data(),
                  'id': document.id,
                }),
              )
              .toList(),
        );
  }

  Future<void> saveSubmission({
    required String userId,
    required EdmJobSubmission submission,
  }) {
    final now = DateTime.now();
    final record = EdmJobRecord(
      id: _documentId(submission.targetFolder),
      submission: submission,
      createdAt: now,
      updatedAt: now,
    );
    return _jobs(
      userId,
    ).doc(record.id).set(record.toJson(), SetOptions(merge: true));
  }

  Future<void> saveStatus({
    required String userId,
    required String targetFolder,
    required EdmJobStatus status,
  }) {
    return _jobs(userId).doc(_documentId(targetFolder)).set({
      'jobStatus': status.toJson(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, SetOptions(merge: true));
  }

  Future<void> saveNextCheckAt({
    required String userId,
    required String targetFolder,
    required DateTime? nextCheckAt,
  }) {
    return _jobs(userId).doc(_documentId(targetFolder)).update({
      'nextCheckAt': nextCheckAt?.millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> deleteJob({
    required String userId,
    required String targetFolder,
  }) {
    return _jobs(userId).doc(_documentId(targetFolder)).delete();
  }

  String _documentId(String targetFolder) =>
      base64Url.encode(utf8.encode(targetFolder)).replaceAll('=', '');
}
