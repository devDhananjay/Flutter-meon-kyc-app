import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStore()),
      ],
      child: const MeonKycApp(),
    ),
  );
}
