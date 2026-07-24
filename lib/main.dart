import 'package:flutter/material.dart';

import 'src/home_page.dart';
import 'src/theme.dart';

void main() {
  runApp(const PlaudDemoApp());
}

class PlaudDemoApp extends StatelessWidget {
  const PlaudDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The Plaud demo screen is dark-only, matching the RN demo.
    return MaterialApp(
      title: 'Plaud Flutter Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: PlaudColors.surface,
        colorScheme: const ColorScheme.dark(
          surface: PlaudColors.surface,
          primary: PlaudColors.accentBlue,
          error: PlaudColors.statusError,
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.white10,
      ),
      home: const HomePage(),
    );
  }
}
