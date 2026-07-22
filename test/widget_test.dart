import 'package:flutter_test/flutter_test.dart';

import 'package:control_gafas_eihfa/main.dart';

void main() {
  testWidgets('Muestra título y botones Encender/Apagar', (WidgetTester tester) async {
    await tester.pumpWidget(const GafasEihfaApp());

    expect(
      find.text('Control de gafas de entrenamientos de pilotos de la EIHFA'),
      findsOneWidget,
    );
    expect(find.text('Encender'), findsOneWidget);
    expect(find.text('Apagar'), findsOneWidget);
  });
}
