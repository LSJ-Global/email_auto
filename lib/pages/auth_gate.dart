import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import '../services/auth_service.dart';
import 'auth_page.dart';
import 'job_page.dart';
import 'verify_email_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _auth = AuthService();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _auth.userChanges,
      initialData: _auth.currentUser,
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (user == null) {
          return AuthPage(auth: _auth);
        }
        if (!user.emailVerified) {
          return VerifyEmailPage(auth: _auth, email: user.email ?? '');
        }
        return JobPage(auth: _auth, user: user);
      },
    );
  }
}
