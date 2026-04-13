import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/app.dart';
import 'package:meon_kyc/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStore()),
      ],
      child: const MeonKycApp(),
    ),
  );
}
