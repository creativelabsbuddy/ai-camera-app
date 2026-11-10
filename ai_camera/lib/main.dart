import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_camera_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const AiCameraApp());
}

class AiCameraApp extends StatelessWidget {
  const AiCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Camera',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeCameraScreen(),
    );
  }
}
