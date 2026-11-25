import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:offline_connectivity/offline_connectivity.dart';

import '../features/home/home_screen.dart';
import 'theme.dart';
import '../core/history/chat_history_repository.dart';

class MessengerApp extends StatelessWidget {
  const MessengerApp({
    super.key,
    this.connectivity = const OfflineConnectivity(),
    this.historyStorage = const AndroidChatHistoryStorage(),
  });

  final OfflineConnectivity connectivity;
  final ChatHistoryStorage? historyStorage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkyChat',
      debugShowCheckedModeBanner: false,
      theme: messengerTheme(Brightness.light),
      darkTheme: messengerTheme(Brightness.dark),
      home: HomeScreen(
        connectivity: connectivity,
        historyStorage:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? historyStorage
            : null,
      ),
    );
  }
}
