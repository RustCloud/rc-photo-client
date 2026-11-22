import 'package:flutter/material.dart';

import 'auth/controller.dart';
import 'auth/native.dart';
import 'auth/session_store.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = AuthController(
    native: const AndroidBridge(),
    store: SessionStore(),
  );
  runApp(RcPhotoApp(auth: auth));
  await auth.start();
}
