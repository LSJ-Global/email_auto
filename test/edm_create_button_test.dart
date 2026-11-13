import 'package:edm_auto_web/app.dart';
import 'package:edm_auto_web/widgets/edm_create_button.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('requires an image before starting eDM generation', (
    tester,
  ) async {
    var pressed = false;
    await tester.pumpWidget(
      EdmAutoApp(
        home: Center(
          child: SizedBox(
            width: 420,
            child: EdmCreateButton(
              hasImage: false,
              busy: false,
              onPressed: () => pressed = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('원본 이미지를 먼저 선택해주세요'), findsOneWidget);
    expect(
      tester
          .widget<ShadButton>(find.byKey(const Key('edm-create-button')))
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('edm-create-button')));
    expect(pressed, isFalse);
  });

  testWidgets('starts generation with one click when an image is ready', (
    tester,
  ) async {
    var pressCount = 0;
    await tester.pumpWidget(
      EdmAutoApp(
        home: Center(
          child: SizedBox(
            width: 420,
            child: EdmCreateButton(
              hasImage: true,
              busy: false,
              onPressed: () => pressCount++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('eDM 생성 시작'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edm-create-button')));
    expect(pressCount, 1);
  });
}
