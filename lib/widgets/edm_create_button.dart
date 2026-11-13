import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class EdmCreateButton extends StatelessWidget {
  const EdmCreateButton({
    required this.hasImage,
    required this.busy,
    required this.onPressed,
    super.key,
  });

  final bool hasImage;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = hasImage && !busy;
    return ShadButton(
      key: const Key('edm-create-button'),
      height: 52,
      enabled: enabled,
      onPressed: onPressed,
      leading: Icon(
        busy
            ? LucideIcons.loaderCircle
            : hasImage
            ? LucideIcons.sparkles
            : LucideIcons.imageUp,
        size: 18,
      ),
      child: Text(
        busy
            ? 'GitHub에 업로드하는 중...'
            : hasImage
            ? 'eDM 생성 시작'
            : '원본 이미지를 먼저 선택해주세요',
      ),
    );
  }
}
