import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_selector/file_selector.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/edm_job_record.dart';
import '../services/auth_service.dart';
import '../services/edm_job_history_service.dart';
import '../services/edm_job_service.dart';
import '../services/file_download_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/edm_create_button.dart';
import '../widgets/edm_history_accordion.dart';

class JobPage extends StatefulWidget {
  const JobPage({required this.auth, required this.user, super.key});

  final AuthService auth;
  final User user;

  @override
  State<JobPage> createState() => _JobPageState();
}

class _JobPageState extends State<JobPage> with WidgetsBindingObserver {
  static const _maxBytes = 8 * 1024 * 1024;
  static const _statusInterval = Duration(minutes: 8);

  final _jobService = EdmJobService();
  final _historyService = EdmJobHistoryService();
  final _downloadService = FileDownloadService();
  final _urls = TextEditingController();
  XFile? _file;
  Uint8List? _bytes;
  bool _busy = false;
  String? _error;
  String? _expandedHistoryFolder;
  Timer? _statusTimer;
  final Map<String, DateTime> _nextStatusChecks = {};
  final Set<String> _checkingFolders = {};
  final Set<String> _deletingFolders = {};
  StreamSubscription<List<EdmJobRecord>>? _historySubscription;
  List<EdmJobRecord> _history = const [];
  bool _historyLoading = true;
  String? _historyError;
  String? _downloadingFileName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _historySubscription = _historyService
        .watchJobs(widget.user.uid)
        .listen(
          _handleHistory,
          onError: (_) {
            if (!mounted) return;
            setState(() {
              _historyLoading = false;
              _historyError = _history.isEmpty ? null : '작업 내역을 불러오지 못했습니다.';
            });
          },
        );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _historySubscription?.cancel();
    _urls.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    _resumeStatusPolling();
  }

  void _resumeStatusPolling() {
    _pollDueJobs();
    if (mounted) setState(() {});
  }

  void _handleHistory(List<EdmJobRecord> jobs) {
    if (!mounted) return;
    setState(() {
      _history = jobs;
      _historyLoading = false;
      _historyError = null;
    });
    _syncStatusPolling(jobs);
  }

  Future<void> _pickImage() async {
    const types = XTypeGroup(
      label: 'eDM image',
      extensions: ['png', 'jpg', 'jpeg', 'webp'],
      mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
      webWildCards: ['image/*'],
    );
    final selected = await openFile(acceptedTypeGroups: [types]);
    if (selected == null) return;
    final bytes = await selected.readAsBytes();
    if (bytes.isEmpty || bytes.length > _maxBytes) {
      setState(() {
        _error = '이미지는 8MB 이하여야 합니다.';
        _file = null;
        _bytes = null;
      });
      return;
    }
    setState(() {
      _file = selected;
      _bytes = bytes;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final file = _file;
    final bytes = _bytes;
    if (file == null || bytes == null) {
      setState(() => _error = '먼저 원본 이미지를 선택해주세요.');
      return;
    }

    final urls = _urls.text
        .split(RegExp(r'[\n,]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (urls.length > 20) {
      setState(() => _error = 'URL은 최대 20개까지 입력할 수 있습니다.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _jobService.submit(
        fileName: file.name,
        bytes: bytes,
        landingUrls: urls,
      );
      if (mounted) {
        setState(() {
          _expandedHistoryFolder = result.targetFolder;
        });
        try {
          await _historyService.saveSubmission(
            userId: widget.user.uid,
            submission: result,
          );
        } catch (_) {
          if (mounted) {
            setState(() {
              _historyError = '작업은 시작됐지만 작업 내역 저장에 실패했습니다.';
            });
          }
        }
        _registerStatusPolling(result.targetFolder);
        if (mounted) {
          setState(() {
            _file = null;
            _bytes = null;
          });
          _urls.clear();
        }
      }
    } on FirebaseFunctionsException catch (error) {
      if (mounted) setState(() => _error = _functionsErrorMessage(error));
    } catch (_) {
      if (mounted) {
        setState(() => _error = '작업 요청 중 예상하지 못한 오류가 발생했습니다.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _syncStatusPolling(List<EdmJobRecord> jobs) {
    final activeFolders = jobs
        .where(
          (job) =>
              !job.isComplete &&
              !_deletingFolders.contains(job.submission.targetFolder),
        )
        .map((job) => job.submission.targetFolder)
        .toSet();
    _nextStatusChecks.removeWhere(
      (folder, _) => !activeFolders.contains(folder),
    );

    for (final job in jobs.where(
      (job) =>
          !job.isComplete &&
          !_deletingFolders.contains(job.submission.targetFolder),
    )) {
      final folder = job.submission.targetFolder;
      if (_nextStatusChecks.containsKey(folder)) continue;
      final savedTime = job.nextCheckAt;
      if (savedTime != null && savedTime.isAfter(DateTime.now())) {
        _nextStatusChecks[folder] = savedTime;
      } else {
        _registerStatusPolling(folder);
      }
    }

    if (_nextStatusChecks.isEmpty) {
      _statusTimer?.cancel();
      _statusTimer = null;
    } else {
      _ensureStatusTimer();
    }
  }

  void _registerStatusPolling(String targetFolder) {
    if (_nextStatusChecks.containsKey(targetFolder)) return;
    _scheduleNextStatusCheck(targetFolder);
    _ensureStatusTimer();
    unawaited(_checkStatus(targetFolder, resetCountdown: false));
  }

  void _ensureStatusTimer() {
    if (_statusTimer != null) return;
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollDueJobs();
    });
  }

  void _pollDueJobs() {
    final now = DateTime.now();
    final dueFolders = _nextStatusChecks.entries
        .where(
          (entry) =>
              !now.isBefore(entry.value) &&
              !_checkingFolders.contains(entry.key) &&
              !_deletingFolders.contains(entry.key),
        )
        .map((entry) => entry.key)
        .toList();
    for (final folder in dueFolders) {
      _scheduleNextStatusCheck(folder);
      unawaited(_checkStatus(folder, resetCountdown: false));
    }
  }

  void _scheduleNextStatusCheck(String targetFolder) {
    final nextCheckAt = DateTime.now().add(_statusInterval);
    _nextStatusChecks[targetFolder] = nextCheckAt;
    if (mounted) setState(() {});
    unawaited(_persistNextStatusCheck(targetFolder, nextCheckAt));
  }

  Future<void> _persistNextStatusCheck(
    String targetFolder,
    DateTime nextCheckAt,
  ) async {
    try {
      await _historyService.saveNextCheckAt(
        userId: widget.user.uid,
        targetFolder: targetFolder,
        nextCheckAt: nextCheckAt,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _historyError = '자동 확인 시간 저장에 실패했습니다.');
      }
    }
  }

  Future<void> _clearPersistedNextCheck(String targetFolder) async {
    try {
      await _historyService.saveNextCheckAt(
        userId: widget.user.uid,
        targetFolder: targetFolder,
        nextCheckAt: null,
      );
    } catch (_) {
      // The completed status remains saved even if timer cleanup is delayed.
    }
  }

  Future<void> _checkStatus(
    String targetFolder, {
    bool resetCountdown = true,
  }) async {
    if (_checkingFolders.contains(targetFolder) ||
        _deletingFolders.contains(targetFolder)) {
      return;
    }
    if (resetCountdown) _scheduleNextStatusCheck(targetFolder);
    _checkingFolders.add(targetFolder);
    if (mounted) setState(() {});
    try {
      final status = await _jobService.getStatus(targetFolder: targetFolder);
      if (!mounted) return;
      if (_deletingFolders.contains(targetFolder)) return;
      try {
        await _historyService.saveStatus(
          userId: widget.user.uid,
          targetFolder: targetFolder,
          status: status,
        );
      } catch (_) {
        if (mounted) {
          setState(() => _historyError = '최신 작업 상태 저장에 실패했습니다.');
        }
      }
      if (status.isComplete) {
        _nextStatusChecks.remove(targetFolder);
        unawaited(_clearPersistedNextCheck(targetFolder));
      }
    } on FirebaseFunctionsException catch (error) {
      if (mounted) setState(() => _error = _functionsErrorMessage(error));
    } finally {
      _checkingFolders.remove(targetFolder);
      if (mounted) setState(() {});
    }
  }

  void _selectHistoryJob(EdmJobRecord job) {
    final folder = job.submission.targetFolder;
    setState(() {
      final expanding = _expandedHistoryFolder != folder;
      _expandedHistoryFolder = expanding ? folder : null;
      _error = null;
    });
  }

  Future<void> _confirmDeleteJob(EdmJobRecord job) async {
    final folder = job.submission.targetFolder;
    final label = job.submission.label;
    final deletesGitHubFiles = job.submission.isAccountScoped;
    if (_deletingFolders.contains(folder)) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ShadDialog.alert(
        title: const Text('작업을 삭제할까요?'),
        description: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            deletesGitHubFiles
                ? '$label 작업 내역과 GitHub의 원본 이미지 및 생성된 폴더가 '
                      '영구적으로 삭제됩니다. 이 작업은 되돌릴 수 없습니다.'
                : '$label 작업은 기존 저장 방식으로 생성되어 계정별 소유권을 '
                      '확인할 수 없습니다. 다른 계정의 파일을 보호하기 위해 '
                      '작업 내역만 삭제하고 GitHub 파일은 유지합니다.',
          ),
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(deletesGitHubFiles ? 'GitHub에서도 삭제' : '작업 내역만 삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _deletingFolders.add(folder);
      _historyError = null;
    });
    try {
      if (deletesGitHubFiles) {
        await _jobService.deleteJob(
          targetFolder: folder,
          imagePath: job.submission.imagePath,
        );
      }
      await _historyService.deleteJob(
        userId: widget.user.uid,
        targetFolder: folder,
      );
      if (!mounted) return;
      setState(() {
        _nextStatusChecks.remove(folder);
        if (_expandedHistoryFolder == folder) {
          _expandedHistoryFolder = null;
        }
      });
    } on FirebaseFunctionsException catch (error) {
      if (mounted) {
        setState(() => _historyError = _functionsErrorMessage(error));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _historyError = '작업을 삭제하지 못했습니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _deletingFolders.remove(folder));
    }
  }

  Future<void> _downloadFile(EdmResultFile file) async {
    if (_downloadingFileName != null) return;
    setState(() {
      _downloadingFileName = file.name;
      _error = null;
    });
    try {
      await _downloadService.download(file);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '${file.displayName} 파일을 다운로드하지 못했습니다.');
      }
    } finally {
      if (mounted) setState(() => _downloadingFileName = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      email: widget.user.email,
      onSignOut: widget.auth.signOut,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 920;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 20 : 40,
              vertical: compact ? 30 : 48,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _PageHeading(),
                    const SizedBox(height: 36),
                    Flex(
                      direction: compact ? Axis.vertical : Axis.horizontal,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: compact ? 0 : 7,
                          child: _UploadPanel(
                            file: _file,
                            bytes: _bytes,
                            urls: _urls,
                            busy: _busy,
                            error: _error,
                            onPick: _pickImage,
                            onSubmit: _submit,
                          ),
                        ),
                        SizedBox(
                          width: compact ? 0 : 24,
                          height: compact ? 24 : 0,
                        ),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _HistoryPanel(
                                jobs: _history,
                                loading: _historyLoading,
                                error: _historyError,
                                expandedFolder: _expandedHistoryFolder,
                                downloadingFileName: _downloadingFileName,
                                checkingFolders: _checkingFolders,
                                deletingFolders: _deletingFolders,
                                onSelect: _selectHistoryJob,
                                onRefresh: (job) =>
                                    _checkStatus(job.submission.targetFolder),
                                onDelete: _confirmDeleteJob,
                                onDownloadFile: _downloadFile,
                              ),
                              const SizedBox(height: 24),
                              const _ProcessPanel(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'eDM 생성',
          style: theme.textTheme.h1.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -1.4,
          ),
        ),
      ],
    );
  }
}

class _UploadPanel extends StatelessWidget {
  const _UploadPanel({
    required this.file,
    required this.bytes,
    required this.urls,
    required this.busy,
    required this.error,
    required this.onPick,
    required this.onSubmit,
  });

  final XFile? file;
  final Uint8List? bytes;
  final TextEditingController urls;
  final bool busy;
  final String? error;
  final VoidCallback onPick;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('01 / 원본 이미지', style: theme.textTheme.large),
          const SizedBox(height: 6),
          Text(
            'PNG, JPG, WEBP · 최대 8MB',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: busy ? null : onPick,
            child: Container(
              height: bytes == null ? 220 : 360,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.colorScheme.muted.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: bytes == null
                      ? theme.colorScheme.border
                      : theme.colorScheme.primary.withValues(alpha: .55),
                  width: 1.2,
                ),
              ),
              child: bytes == null
                  ? const _EmptyDropZone()
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(bytes!, fit: BoxFit.contain),
                        Positioned(
                          right: 12,
                          top: 12,
                          child: ShadButton.secondary(
                            size: ShadButtonSize.sm,
                            onPressed: busy ? null : onPick,
                            child: const Text('이미지 변경'),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          if (file != null && bytes != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  LucideIcons.fileImage,
                  size: 17,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file!.name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.small,
                  ),
                ),
                Text(
                  _formatBytes(bytes!.length),
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 30),
          Text('02 / URL', style: theme.textTheme.large),
          const SizedBox(height: 6),
          Text(
            'URL이 여러 개면 줄바꿈으로 구분하세요. 버튼이 없으면 비워둘 수 있습니다.',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          const SizedBox(height: 14),
          ShadTextarea(
            controller: urls,
            minHeight: 110,
            maxHeight: 180,
            enabled: !busy,
            placeholder: const Text('https://www.naver.com'),
          ),
          const SizedBox(height: 24),
          EdmCreateButton(
            hasImage: file != null && bytes != null,
            busy: busy,
            onPressed: onSubmit,
          ),
          if (error != null) ...[
            const SizedBox(height: 18),
            _StatusBox(message: error!),
          ],
        ],
      ),
    );
  }
}

class _EmptyDropZone extends StatelessWidget {
  const _EmptyDropZone();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: .11),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              LucideIcons.imageUp,
              color: theme.colorScheme.primary,
              size: 24,
            ),
          ),
          const SizedBox(height: 16),
          Text('클릭해서 원본 이미지 선택', style: theme.textTheme.large),
        ],
      ),
    );
  }
}

// Kept as a private reference layout while the result UI lives in history cards.
// ignore: unused_element
class _SuccessBox extends StatelessWidget {
  const _SuccessBox({
    required this.submission,
    required this.status,
    required this.checkingStatus,
    required this.downloadingFileName,
    required this.onRefreshStatus,
    required this.onDownloadFile,
  });

  final EdmJobSubmission submission;
  final EdmJobStatus? status;
  final bool checkingStatus;
  final String? downloadingFileName;
  final VoidCallback onRefreshStatus;
  final ValueChanged<EdmResultFile> onDownloadFile;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final resultFiles =
        status?.files.where((file) => !_isLocalHtml(file)).toList() ??
        const <EdmResultFile>[];
    final progress = _jobProgress(status);
    final progressLabel = _jobProgressLabel(status);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.circleCheck,
                size: 19,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  status?.isComplete == true ? '결과 생성 완료' : '결과 생성 중',
                  style: theme.textTheme.large.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            status?.isComplete == true
                ? 'GitHub에서 생성된 파일 주소를 확인했습니다.'
                : '${submission.label} 작업을 8분마다 확인합니다.',
            style: theme.textTheme.small,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(progressLabel, style: theme.textTheme.small),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: theme.textTheme.large.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Container(
              height: 9,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(999),
              ),
              alignment: Alignment.centerLeft,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: progress),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Container(
                  width: constraints.maxWidth * value,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
          if (status?.isComplete != true) ...[
            const SizedBox(height: 8),
            Text(
              '진행률은 확인된 처리 단계 기준입니다.',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
          ],
          if (resultFiles.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...resultFiles.map(
              (file) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ResultFileButton(
                  file: file,
                  downloading: downloadingFileName == file.name,
                  onDownload: () => onDownloadFile(file),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: !checkingStatus,
                onPressed: onRefreshStatus,
                leading: const Icon(LucideIcons.refreshCw, size: 14),
                child: Text(checkingStatus ? '확인 중...' : '지금 확인'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultFileButton extends StatelessWidget {
  const _ResultFileButton({
    required this.file,
    required this.downloading,
    required this.onDownload,
  });

  final EdmResultFile file;
  final bool downloading;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadButton.secondary(
      width: double.infinity,
      height: 44,
      enabled: !downloading,
      onPressed: onDownload,
      leading: Icon(
        downloading ? LucideIcons.loaderCircle : _fileIcon(file.type),
        size: 17,
      ),
      trailing: Icon(
        downloading ? LucideIcons.loaderCircle : LucideIcons.download,
        size: 16,
      ),
      mainAxisAlignment: MainAxisAlignment.start,
      child: Expanded(
        child: Row(
          children: [
            Expanded(
              child: Text(
                file.displayName,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatBytes(file.size),
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _fileIcon(String type) {
  return switch (type) {
    'html' => LucideIcons.codeXml,
    'eml' => LucideIcons.mail,
    'oft' => LucideIcons.fileArchive,
    'zip' => LucideIcons.fileArchive,
    _ => LucideIcons.file,
  };
}

bool _isLocalHtml(EdmResultFile file) =>
    file.type == 'html' && file.name.toLowerCase().endsWith('_local.html');

double _jobProgress(EdmJobStatus? status) {
  if (status?.isComplete == true) return 1;
  if (status == null) return .2;

  final generatedTypes = status.files
      .map((file) => file.type)
      .where(const {'html', 'eml', 'oft'}.contains)
      .toSet()
      .length;
  return switch (generatedTypes) {
    0 => .45,
    1 => .65,
    2 => .82,
    _ => .95,
  };
}

String _jobProgressLabel(EdmJobStatus? status) {
  if (status?.isComplete == true) return 'eDM 생성 완료';
  if (status == null) return '작업 요청 접수';

  final generatedTypes = status.files
      .map((file) => file.type)
      .where(const {'html', 'eml', 'oft'}.contains)
      .toSet()
      .length;
  return generatedTypes == 0
      ? '이미지 분석 및 eDM 생성 중'
      : '결과 파일 생성 중 ($generatedTypes/3)';
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = theme.colorScheme.destructive;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, size: 18, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.small.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.jobs,
    required this.loading,
    required this.error,
    required this.expandedFolder,
    required this.downloadingFileName,
    required this.checkingFolders,
    required this.deletingFolders,
    required this.onSelect,
    required this.onRefresh,
    required this.onDelete,
    required this.onDownloadFile,
  });

  final List<EdmJobRecord> jobs;
  final bool loading;
  final String? error;
  final String? expandedFolder;
  final String? downloadingFileName;
  final Set<String> checkingFolders;
  final Set<String> deletingFolders;
  final ValueChanged<EdmJobRecord> onSelect;
  final ValueChanged<EdmJobRecord> onRefresh;
  final ValueChanged<EdmJobRecord> onDelete;
  final ValueChanged<EdmResultFile> onDownloadFile;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      padding: const EdgeInsets.all(24),
      title: const Text('생성 내역'),
      description: const Text('작업 내역을 누르면 결과를 바로 확인할 수 있습니다.'),
      child: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: loading
            ? Row(
                children: [
                  Icon(
                    LucideIcons.loaderCircle,
                    size: 17,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 9),
                  const Text('작업 내역을 불러오는 중...'),
                ],
              )
            : error != null && jobs.isEmpty
            ? Text(
                error!,
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.destructive,
                ),
              )
            : jobs.isEmpty
            ? Text(
                '아직 생성한 작업이 없습니다.',
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.mutedForeground,
                ),
              )
            : Column(
                children: [
                  if (error != null) ...[
                    Text(
                      error!,
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.destructive,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ...jobs.map((job) {
                    final folder = job.submission.targetFolder;
                    final expanded = expandedFolder == folder;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _HistoryItem(
                        job: job,
                        expanded: expanded,
                        downloadingFileName: downloadingFileName,
                        checking: checkingFolders.contains(folder),
                        deleting: deletingFolders.contains(folder),
                        onSelect: () => onSelect(job),
                        onRefresh: () => onRefresh(job),
                        onDelete: () => onDelete(job),
                        onDownloadFile: onDownloadFile,
                      ),
                    );
                  }),
                ],
              ),
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    required this.job,
    required this.expanded,
    required this.downloadingFileName,
    required this.checking,
    required this.deleting,
    required this.onSelect,
    required this.onRefresh,
    required this.onDelete,
    required this.onDownloadFile,
  });

  final EdmJobRecord job;
  final bool expanded;
  final String? downloadingFileName;
  final bool checking;
  final bool deleting;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;
  final ValueChanged<EdmResultFile> onDownloadFile;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final status = job.status;
    final complete = job.isComplete;
    final resultFiles =
        status?.files.where((file) => !_isLocalHtml(file)).toList() ??
        const <EdmResultFile>[];
    final progress = _jobProgress(status);
    final progressLabel = _jobProgressLabel(status);

    return EdmHistoryAccordion(
      expanded: expanded,
      onToggle: onSelect,
      toggleKey: ValueKey('history-${job.submission.targetFolder}'),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                complete ? LucideIcons.circleCheck : LucideIcons.clock3,
                size: 16,
                color: complete
                    ? theme.colorScheme.primary
                    : theme.colorScheme.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.submission.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 16,
                color: expanded
                    ? theme.colorScheme.primary
                    : theme.colorScheme.mutedForeground,
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${complete ? '완료' : '진행 중'} · ${_formatDateTime(job.createdAt)}',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
      ),
      children: [
        Row(
          children: [
            Expanded(child: Text(progressLabel, style: theme.textTheme.small)),
            Text(
              '${(progress * 100).round()}%',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => Container(
            height: 7,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: .15),
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              width: constraints.maxWidth * progress,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        if (resultFiles.isNotEmpty) ...[
          const SizedBox(height: 14),
          ...resultFiles.map(
            (file) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ResultFileButton(
                file: file,
                downloading: downloadingFileName == file.name,
                onDownload: () => onDownloadFile(file),
              ),
            ),
          ),
        ] else if (complete) ...[
          const SizedBox(height: 14),
          Text(
            '다운로드할 결과 파일을 찾지 못했습니다.',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            if (!complete)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: !checking,
                onPressed: onRefresh,
                leading: Icon(
                  checking ? LucideIcons.loaderCircle : LucideIcons.refreshCw,
                  size: 14,
                ),
                child: Text(checking ? '확인 중...' : '상태 확인'),
              ),
            ShadButton.destructive(
              size: ShadButtonSize.sm,
              enabled: !checking && !deleting,
              onPressed: onDelete,
              leading: Icon(
                deleting ? LucideIcons.loaderCircle : LucideIcons.trash2,
                size: 14,
              ),
              child: Text(deleting ? '삭제 중...' : '삭제'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProcessPanel extends StatelessWidget {
  const _ProcessPanel();

  @override
  Widget build(BuildContext context) {
    return const ShadCard(
      padding: EdgeInsets.all(24),
      title: Text('자동화 흐름'),
      child: Padding(
        padding: EdgeInsets.only(top: 18),
        child: Column(
          children: [
            _ProcessStep(number: '01', title: 'GitHub 업로드'),
            _ProcessStep(number: '02', title: 'Codex 처리'),
            _ProcessStep(number: '03', title: 'eDM 생성'),
            _ProcessStep(number: '04', title: '결과 다운로드', last: true),
          ],
        ),
      ),
    );
  }
}

class _ProcessStep extends StatelessWidget {
  const _ProcessStep({
    required this.number,
    required this.title,
    this.last = false,
  });

  final String number;
  final String title;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                number,
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (!last)
              Container(width: 1, height: 24, color: theme.colorScheme.border),
          ],
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(title, style: theme.textTheme.p),
          ),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}.${twoDigits(local.month)}.${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

String _functionsErrorMessage(FirebaseFunctionsException error) {
  return switch (error.code) {
    'unauthenticated' => '로그인 세션이 만료되었습니다. 다시 로그인해주세요.',
    'permission-denied' => '이메일 인증이 완료된 계정만 작업을 생성할 수 있습니다.',
    'already-exists' => 'GitHub에 같은 이름의 파일이 이미 존재합니다.',
    'invalid-argument' => error.message ?? '입력값을 확인해주세요.',
    'resource-exhausted' => '요청 한도를 초과했습니다. 잠시 후 다시 시도해주세요.',
    _ => error.message ?? '서버에서 작업을 처리하지 못했습니다.',
  };
}
