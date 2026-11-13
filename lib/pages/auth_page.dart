import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../services/auth_service.dart';
import '../widgets/app_shell.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({required this.auth, super.key});

  final AuthService auth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registerMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 6) {
      setState(() => _error = '올바른 이메일과 6자 이상의 비밀번호를 입력해주세요.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_registerMode) {
        await widget.auth.register(email: email, password: password);
      } else {
        await widget.auth.signIn(email: email, password: password);
      }
    } on FirebaseAuthException catch (error) {
      setState(() => _error = _authErrorMessage(error.code));
    } catch (_) {
      setState(() => _error = '로그인 처리 중 오류가 발생했습니다.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 20 : 48,
              vertical: compact ? 40 : 72,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Flex(
                  direction: compact ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: compact ? 0 : 6,
                      child: _Intro(compact: compact),
                    ),
                    SizedBox(width: compact ? 0 : 72, height: compact ? 40 : 0),
                    Expanded(
                      flex: compact ? 0 : 4,
                      child: ShadCard(
                        padding: const EdgeInsets.all(28),
                        title: Text(_registerMode ? '계정 만들기' : '로그인'),
                        description: _registerMode
                            ? const Text(
                                'Outlook 계정(@outlook.com, @hotmail.com, @live.com)은 '
                                '제외하고 가입해주세요. 가입 후 받은 이메일에서 '
                                '인증을 완료해주세요.',
                              )
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text('이메일'),
                              const SizedBox(height: 7),
                              ShadInput(
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                placeholder: const Text('name@company.com'),
                                leading: const Icon(LucideIcons.mail, size: 17),
                              ),
                              const SizedBox(height: 18),
                              const Text('비밀번호'),
                              const SizedBox(height: 7),
                              ShadInput(
                                controller: _password,
                                obscureText: true,
                                autofillHints: const [AutofillHints.password],
                                placeholder: const Text('6자 이상'),
                                leading: const Icon(
                                  LucideIcons.lockKeyhole,
                                  size: 17,
                                ),
                                onSubmitted: (_) => _submit(),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 16),
                                _InlineMessage(message: _error!),
                              ],
                              const SizedBox(height: 22),
                              ShadButton(
                                height: 48,
                                enabled: !_busy,
                                onPressed: _submit,
                                child: Text(
                                  _busy
                                      ? '처리 중...'
                                      : (_registerMode ? '가입하기' : '로그인'),
                                ),
                              ),
                              const SizedBox(height: 10),
                              ShadButton.ghost(
                                enabled: !_busy,
                                onPressed: () => setState(() {
                                  _registerMode = !_registerMode;
                                  _error = null;
                                }),
                                child: Text(
                                  _registerMode
                                      ? '이미 계정이 있나요? 로그인'
                                      : '계정이 없나요? 회원가입',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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

class _Intro extends StatelessWidget {
  const _Intro({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '이미지 한 장에서\n완성된 eDM까지.',
          style: theme.textTheme.h1.copyWith(
            fontSize: compact ? 42 : 60,
            height: 1.04,
            fontWeight: FontWeight.w900,
            letterSpacing: -2.2,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '원본 이미지와 URL을 입력하면 Codex가 이미지를 분석하고 '
          'HTML · EML · OFT를 생성합니다.',
          style: theme.textTheme.large.copyWith(
            color: theme.colorScheme.mutedForeground,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = theme.colorScheme.destructive;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(message, style: theme.textTheme.small.copyWith(color: color)),
    );
  }
}

String _authErrorMessage(String code) {
  return switch (code) {
    'invalid-email' => '이메일 형식이 올바르지 않습니다.',
    'invalid-credential' => '이메일 또는 비밀번호를 확인해주세요.',
    'user-disabled' => '사용이 중지된 계정입니다.',
    'email-already-in-use' => '이미 가입된 이메일입니다.',
    'weak-password' => '더 안전한 비밀번호를 사용해주세요.',
    'too-many-requests' => '요청이 너무 많습니다. 잠시 후 다시 시도해주세요.',
    'operation-not-allowed' => 'Firebase에서 이메일 로그인을 먼저 활성화해주세요.',
    _ => '인증 처리에 실패했습니다. ($code)',
  };
}
