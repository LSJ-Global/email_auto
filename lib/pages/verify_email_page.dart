import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../services/auth_service.dart';
import '../widgets/app_shell.dart';

class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({required this.auth, required this.email, super.key});

  final AuthService auth;
  final String email;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  bool _busy = false;
  String? _message;

  Future<void> _run(Future<void> Function() action, String message) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = message);
    } catch (_) {
      if (mounted) setState(() => _message = '요청을 처리하지 못했습니다.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return AppShell(
      email: widget.email,
      onSignOut: widget.auth.signOut,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: ShadCard(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      LucideIcons.mailCheck,
                      color: theme.colorScheme.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('이메일을 확인해주세요', style: theme.textTheme.h2),
                  const SizedBox(height: 10),
                  Text(
                    '${widget.email} 주소로 인증 링크를 보냈습니다. '
                    '인증을 마친 뒤 아래 버튼을 눌러주세요.',
                    style: theme.textTheme.p.copyWith(
                      color: theme.colorScheme.mutedForeground,
                      height: 1.55,
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _message!,
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ShadButton(
                    height: 48,
                    enabled: !_busy,
                    onPressed: () =>
                        _run(widget.auth.refreshUser, '인증 상태를 새로 확인했습니다.'),
                    child: Text(_busy ? '확인 중...' : '인증 완료 확인'),
                  ),
                  const SizedBox(height: 10),
                  ShadButton.outline(
                    enabled: !_busy,
                    onPressed: () => _run(
                      widget.auth.sendVerificationEmail,
                      '인증 메일을 다시 보냈습니다.',
                    ),
                    child: const Text('인증 메일 다시 보내기'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
