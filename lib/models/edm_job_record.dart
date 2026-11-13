import '../services/edm_job_service.dart';

class EdmJobRecord {
  const EdmJobRecord({
    required this.id,
    required this.submission,
    required this.createdAt,
    required this.updatedAt,
    this.status,
    this.nextCheckAt,
  });

  final String id;
  final EdmJobSubmission submission;
  final EdmJobStatus? status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? nextCheckAt;

  bool get isComplete => status?.isComplete == true;

  factory EdmJobRecord.fromJson(Map<String, dynamic> json) {
    return switch (json) {
      {
        'id': String id,
        'submission': Map submission,
        'createdAt': int createdAt,
        'updatedAt': int updatedAt,
      } =>
        EdmJobRecord(
          id: id,
          submission: EdmJobSubmission.fromJson(
            Map<String, dynamic>.from(submission),
          ),
          status: switch (json['jobStatus']) {
            Map status => EdmJobStatus.fromJson(
              Map<String, dynamic>.from(status),
            ),
            _ => null,
          },
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
          nextCheckAt: switch (json['nextCheckAt']) {
            int value => DateTime.fromMillisecondsSinceEpoch(value),
            _ => null,
          },
        ),
      _ => throw const FormatException('Invalid eDM job record.'),
    };
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'submission': submission.toJson(),
    'jobStatus': status?.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (nextCheckAt != null) 'nextCheckAt': nextCheckAt!.millisecondsSinceEpoch,
  };
}
