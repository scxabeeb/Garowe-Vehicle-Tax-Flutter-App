
import 'package:flutter/material.dart';
import 'package:vehicle_tax_collector/screens/login_page.dart';
import 'package:vehicle_tax_collector/theme/brand_theme.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Garowe Vehicle Tax Collector',
      theme: AppBrandTheme.light(),
      home: const LoginPage(),
    );
  }
}
