import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../demo/demo_mode.dart';
import '../theme.dart';
import '../app_shell.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(text: kDemoMode ? '' : 'frontdesk@lightskate.demo');
  final _password = TextEditingController(text: kDemoMode ? '' : 'LightSkate-Demo-2026!');
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = await ApiClient.instance();
      if (kDemoMode) {
        // Demo mode: any email/password is accepted, nothing is validated against a backend.
        await api.loginDemo(_email.text.trim());
      } else {
        await api.login(_email.text.trim(), _password.text);
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AppShell()));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: LsColors.brand, borderRadius: BorderRadius.circular(12)),
                    alignment: Alignment.center,
                    child: const Icon(Icons.ice_skating, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Light Skate', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    Text('Venue operations', style: TextStyle(color: LsColors.muted)),
                  ]),
                ]),
                const SizedBox(height: 28),
                if (kDemoMode) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(8)),
                    child: const Text(
                      'Demo mode — enter any email and password and tap Sign in.',
                      style: TextStyle(color: LsColors.brandStrong, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: _email,
                  decoration: InputDecoration(labelText: 'Email', hintText: kDemoMode ? 'anything@example.com' : null),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _password,
                  decoration: InputDecoration(labelText: 'Password', hintText: kDemoMode ? 'anything' : null),
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: LsColors.red)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Signing in…' : 'Sign in')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
