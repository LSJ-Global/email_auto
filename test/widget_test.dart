import 'package:edm_auto_web/app.dart';
import 'package:edm_auto_web/widgets/app_shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app renders the authentication entry', (tester) async {
    await tester.pumpWidget(
      const EdmAutoApp(
        home: AppShell(child: Center(child: Text('작업 공간 로그인'))),
      ),
    );
    await tester.pump();

    expect(find.text('eDM 자동 생성 프로그램'), findsOneWidget);
    expect(find.text('작업 공간 로그인'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('eDM 자동 생성 프로그램')).style?.fontFamily,
      'Pretendard',
    );
  });

  testWidgets('account controls are aligned to the right edge', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      EdmAutoApp(
        home: AppShell(
          email: 'user@example.com',
          onSignOut: () {},
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getCenter(find.text('로그아웃')).dx, greaterThan(1100));
  });
}
