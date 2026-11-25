import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/profile/user_profile.dart';

class FirstRunGate extends StatefulWidget {
  const FirstRunGate({super.key, required this.store, required this.builder});
  final UserProfileStore store;
  final Widget Function(BuildContext context, LocalUserProfile profile) builder;

  @override
  State<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<FirstRunGate> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  LocalUserProfile? _profile;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final profile = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _name.text = profile.username;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Your profile could not be opened. Please retry.';
        });
      }
    }
  }

  Future<void> _finish(String name) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.store.complete(name);
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _profile = LocalUserProfile(username: name, configured: true);
        _saving = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError =
              'Your name could not be saved. Check available storage and retry.';
        });
      }
    }
  }

  void _submit() {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    unawaited(_finish(normalizeProfileName(_name.text)!));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_profile?.configured == true) return widget.builder(context, _profile!);
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            semanticsLabel: 'Opening your profile',
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('SkyChat')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_loadError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      Icons.forum_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome to SkyChat',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text('Chat with nearby people, even without internet.'),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _name,
                    enabled: !_saving,
                    maxLength: 32,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    keyboardType: TextInputType.name,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      hintText: 'How should others see you?',
                    ),
                    validator: (value) =>
                        normalizeProfileName(value ?? '') == null
                        ? 'Choose a name of up to 32 characters.'
                        : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const Text(
                    'People in your group can see this name. You can change it later in Contacts.',
                  ),
                  const SizedBox(height: 16),
                  if (_saveError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _saveError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: Text(_saving ? 'Saving…' : 'Start chatting'),
                  ),
                  TextButton(
                    onPressed: _saving ? null : () => _finish('Guest'),
                    child: const Text('Continue as Guest'),
                  ),
                  const SizedBox(height: 24),
                  const _WelcomeFact(
                    icon: Icons.wifi_tethering,
                    title: 'Keep Wi-Fi on',
                    text:
                        'Phones connect directly. You do not need a router or mobile data. A “No internet” notice for the group network is normal.',
                  ),
                  const _WelcomeFact(
                    icon: Icons.group_add_outlined,
                    title: 'Create or join a group',
                    text:
                        'Create a group on one phone, then join from the other. Public groups support nearby search, QR and NFC. Private groups automatically verify NFC contacts before admitting them.',
                  ),
                  const _WelcomeFact(
                    icon: Icons.tune,
                    title: 'Permissions when needed',
                    text:
                        'Android may ask for Nearby devices or Location when connecting, camera access for QR, and microphone access for calls.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeFact extends StatelessWidget {
  const _WelcomeFact({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(text),
            ],
          ),
        ),
      ],
    ),
  );
}
