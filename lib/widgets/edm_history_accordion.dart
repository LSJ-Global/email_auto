import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class EdmHistoryAccordion extends StatelessWidget {
  const EdmHistoryAccordion({
    required this.expanded,
    required this.onToggle,
    required this.header,
    required this.children,
    this.toggleKey,
    super.key,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final Widget header;
  final List<Widget> children;
  final Key? toggleKey;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: toggleKey,
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: expanded
                ? theme.colorScheme.primary.withValues(alpha: .1)
                : theme.colorScheme.muted.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: expanded
                  ? theme.colorScheme.primary.withValues(alpha: .45)
                  : theme.colorScheme.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (expanded) ...[
                const SizedBox(height: 12),
                Container(height: 1, color: theme.colorScheme.border),
                const SizedBox(height: 12),
                ...children,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
