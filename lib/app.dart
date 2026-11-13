import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'pages/auth_gate.dart';

class EdmAutoApp extends StatelessWidget {
  const EdmAutoApp({super.key, this.home});

  final Widget? home;

  static const _accent = Color(0xFFCAFF4A);
  static const _background = Color(0xFF0A0B0D);
  static const _foreground = Color(0xFFF7F8FA);

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      title: 'EDM Auto',
      debugShowCheckedModeBanner: false,
      backgroundColor: _background,
      theme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: const ShadZincColorScheme.dark(
          primary: _accent,
          primaryForeground: Color(0xFF111409),
          background: _background,
          foreground: _foreground,
          card: Color(0xFF111317),
          cardForeground: _foreground,
          popover: Color(0xFF15181D),
          popoverForeground: _foreground,
          muted: Color(0xFF1A1D22),
          mutedForeground: Color(0xFF969DA8),
          accent: Color(0xFF22262D),
          accentForeground: _foreground,
          border: Color(0xFF2A2E35),
          input: Color(0xFF2A2E35),
          ring: _accent,
        ),
        textTheme: ShadTextTheme(family: 'Pretendard'),
        radius: const BorderRadius.all(Radius.circular(14)),
      ),
      home: home ?? const AuthGate(),
    );
  }
}
