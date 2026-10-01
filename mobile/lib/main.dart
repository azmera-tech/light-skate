import 'package:flutter/material.dart';
import 'api/api_client.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'theme.dart';

void main() {
  runApp(const LightSkateApp());
}

class LightSkateApp extends StatelessWidget {
  const LightSkateApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Light Skate',
      debugShowCheckedModeBanner: false,
      theme: buildLsTheme(),
      home: const _Bootstrap(),
    );
  }
}

/// Decides Login vs Dashboard based on whether a token is already stored (the user stays
/// signed in between app launches, like the web app does via localStorage).
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiClient>(
      future: ApiClient.instance(),
      builder: (context, snap) {
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        return snap.data!.isAuthenticated ? const DashboardScreen() : const LoginScreen();
      },
    );
  }
}
