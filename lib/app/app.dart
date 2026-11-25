import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_connectivity/offline_connectivity.dart';

import '../features/home/home_screen.dart';
import 'theme.dart';
import '../core/history/chat_history_repository.dart';
import '../core/profile/user_profile.dart';
import '../features/onboarding/first_run_gate.dart';

class MessengerApp extends StatelessWidget {
  const MessengerApp({
    super.key,
    this.connectivity = const OfflineConnectivity(),
    this.historyStorage = const AndroidChatHistoryStorage(),
    this.profileStore = const AndroidUserProfileStore(),
  });

  final OfflineConnectivity connectivity;
  final ChatHistoryStorage? historyStorage;
  final UserProfileStore profileStore;

  @override
  Widget build(BuildContext context) {
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    Widget home({String? username}) => HomeScreen(
      connectivity: connectivity,
      historyStorage: android ? historyStorage : null,
      initialUsername: username,
    );
    return MaterialApp(
      title: 'SkyChat',
      debugShowCheckedModeBanner: false,
      theme: messengerTheme(Brightness.light),
      darkTheme: messengerTheme(Brightness.dark),
      home: android
          ? FirstRunGate(
              store: profileStore,
              builder: (_, profile) => home(username: profile.username),
            )
          : home(),
    );
  }
}
