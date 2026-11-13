import 'package:edm_auto_web/models/edm_job_record.dart';
import 'package:edm_auto_web/services/edm_job_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'EdmJobRecord JSON round-trip preserves submission and result files',
    () {
      final record = EdmJobRecord(
        id: 'sample-job',
        submission: const EdmJobSubmission(
          imagePath: 'sample/original.png',
          targetFolder: 'sample',
          status: 'queued',
          commitSha: 'abc123',
          commitUrl: 'https://github.com/example/commit/abc123',
          workflowRunId: 42,
          workflowRunUrl: 'https://github.com/example/actions/runs/42',
        ),
        status: const EdmJobStatus(
          targetFolder: 'sample',
          status: 'complete',
          folderUrl: 'https://github.com/example/tree/main/sample',
          files: [
            EdmResultFile(
              name: 'sample.html',
              type: 'html',
              size: 1200,
              downloadUrl: 'https://raw.githubusercontent.com/sample.html',
            ),
          ],
        ),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000005000),
        nextCheckAt: DateTime.fromMillisecondsSinceEpoch(1700000480000),
      );

      final restored = EdmJobRecord.fromJson(record.toJson());

      expect(restored.id, record.id);
      expect(restored.submission.toJson(), record.submission.toJson());
      expect(restored.status?.toJson(), record.status?.toJson());
      expect(restored.createdAt, record.createdAt);
      expect(restored.updatedAt, record.updatedAt);
      expect(restored.nextCheckAt, record.nextCheckAt);
    },
  );

  test('EdmJobRecord rejects malformed JSON', () {
    expect(
      () => EdmJobRecord.fromJson(const {'id': 'missing-fields'}),
      throwsFormatException,
    );
  });
}
