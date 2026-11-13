import 'package:edm_auto_web/app.dart';
import 'package:edm_auto_web/widgets/edm_history_accordion.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens and closes the result file list when the card is tapped', (
    tester,
  ) async {
    var expanded = false;

    await tester.pumpWidget(
      EdmAutoApp(
        home: StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 420,
              child: EdmHistoryAccordion(
                expanded: expanded,
                toggleKey: const Key('test-history-card'),
                onToggle: () => setState(() => expanded = !expanded),
                header: const Text('테스트 eDM'),
                children: const [
                  Text('result.html'),
                  Text('result.eml'),
                  Text('result.oft'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('result.html'), findsNothing);
    expect(find.text('result.eml'), findsNothing);
    expect(find.text('result.oft'), findsNothing);

    await tester.tap(find.byKey(const Key('test-history-card')));
    await tester.pump();

    expect(find.text('result.html'), findsOneWidget);
    expect(find.text('result.eml'), findsOneWidget);
    expect(find.text('result.oft'), findsOneWidget);

    await tester.tap(find.byKey(const Key('test-history-card')));
    await tester.pump();

    expect(find.text('result.html'), findsNothing);
    expect(find.text('result.eml'), findsNothing);
    expect(find.text('result.oft'), findsNothing);
  });
}
