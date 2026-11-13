import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.child, super.key, this.email, this.onSignOut});

  final Widget child;
  final String? email;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ColoredBox(
      color: theme.colorScheme.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              height: 72,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.border),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;
                  return Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          LucideIcons.mailCheck,
                          size: 20,
                          color: theme.colorScheme.primaryForeground,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 12),
                        Text(
                          'eDM 자동 생성 프로그램',
                          style: theme.textTheme.large.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: email == null
                              ? const SizedBox.shrink()
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: compact ? 130 : 260,
                                      ),
                                      child: Text(
                                        email!,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.small.copyWith(
                                          color:
                                              theme.colorScheme.mutedForeground,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    ShadButton.ghost(
                                      onPressed: onSignOut,
                                      leading: const Icon(
                                        LucideIcons.logOut,
                                        size: 16,
                                      ),
                                      child: const Text('로그아웃'),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
