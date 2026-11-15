import 'package:flutter/services.dart';

/// Bridges SkyChat's foreground-service lifecycle and message notifications to Android.
class BackgroundService {
  const BackgroundService();

  static const MethodChannel _channel = MethodChannel('com.skychat/background');

  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> start({
    String title = 'SkyChat',
    String body = 'Connected to offline group',
  }) async {
    try {
      await _channel.invokeMethod<void>('startBackgroundService', {
        'title': title,
        'body': body,
      });
    } on MissingPluginException {
      // Ignored in tests or platforms without the native handler.
    } on PlatformException {
      // Avoid breaking chat flow if background service cannot start.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopBackgroundService');
    } on MissingPluginException {
      // Ignored in tests or platforms without the native handler.
    } on PlatformException {
      // Best-effort cleanup.
    }
  }

  Future<void> showMessageNotification({
    required String sender,
    required String text,
  }) async {
    try {
      await _channel.invokeMethod<void>('showMessageNotification', {
        'sender': sender,
        'text': text,
      });
    } on MissingPluginException {
      // Ignored in tests or platforms without the native handler.
    } on PlatformException {
      // Best-effort notification.
    }
  }

  Future<void> moveToBackground() async {
    try {
      await _channel.invokeMethod<void>('moveToBackground');
    } on MissingPluginException {
      // Ignored in tests or platforms without the native handler.
    } on PlatformException {
      // Best-effort.
    }
  }
}
