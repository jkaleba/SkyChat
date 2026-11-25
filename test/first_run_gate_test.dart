import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/app/app.dart';
import 'package:offline_group_messenger/core/profile/user_profile.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';
import 'package:offline_group_messenger/features/onboarding/first_run_gate.dart';

import 'chat_session_controller_test.dart' show ControlledTransport;
import 'connection_flow_test.dart' show FakeConnection;

class MemoryProfileStore implements UserProfileStore {
  LocalUserProfile profile = const LocalUserProfile(
    username: '',
    configured: false,
  );
  bool failLoad = false;
  bool failSave = false;
  Completer<LocalUserProfile>? loading;
  Completer<void>? saving;
  int loads = 0;
  final savedNames = <String>[];

  @override
  Future<LocalUserProfile> load() async {
    loads++;
    if (failLoad) throw PlatformException(code: 'profile_storage_failed');
    return loading == null ? profile : loading!.future;
  }

  @override
  Future<void> complete(String username) async {
    savedNames.add(username);
    if (failSave) throw PlatformException(code: 'profile_storage_failed');
    await saving?.future;
    profile = LocalUserProfile(username: username, configured: true);
  }
}

Widget gate(MemoryProfileStore store) => MaterialApp(
  home: FirstRunGate(
    store: store,
    builder: (_, profile) =>
        Scaffold(body: Text('Ready as ${profile.username}')),
  ),
);

void main() {
  testWidgets('setup remains usable on a small screen with large system text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryProfileStore();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: FirstRunGate(
          store: store,
          builder: (_, profile) =>
              Scaffold(body: Text('Ready as ${profile.username}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TextFormField),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextFormField), 'Alice');
    await tester.scrollUntilVisible(
      find.text('Start chatting'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(find.text('Ready as Alice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'fresh setup explains offline use before constructing the connection screen',
    (tester) async {
      final store = MemoryProfileStore()
        ..loading = Completer<LocalUserProfile>();
      final connection = FakeConnection();
      await tester.pumpWidget(
        MessengerApp(
          connectivity: connection,
          profileStore: store,
          historyStorage: null,
        ),
      );
      await tester.pump();
      expect(find.byType(HomeScreen), findsNothing);
      store.loading!.complete(store.profile);
      await tester.pumpAndSettle();
      expect(find.text('Welcome to SkyChat'), findsOneWidget);
      expect(find.text('Keep Wi-Fi on'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Permissions when needed'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Permissions when needed'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(connection.creates, 0);
      expect(connection.joined, isNull);
      expect(store.savedNames, isEmpty);
    },
  );

  testWidgets(
    'choosing a name persists it and setup is skipped after a restart',
    (tester) async {
      final store = MemoryProfileStore();
      await tester.pumpWidget(gate(store));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '  Żaneta  ');
      await tester.tap(find.text('Start chatting'));
      await tester.pumpAndSettle();
      expect(store.savedNames, ['Żaneta']);
      expect(find.text('Ready as Żaneta'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(gate(store));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to SkyChat'), findsNothing);
      expect(find.text('Ready as Żaneta'), findsOneWidget);
      expect(store.savedNames, ['Żaneta']);
    },
  );

  testWidgets('continuing as Guest is explicit and remembered', (tester) async {
    final store = MemoryProfileStore();
    await tester.pumpWidget(gate(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue as Guest'));
    await tester.pumpAndSettle();
    expect(store.savedNames, ['Guest']);
    expect(find.text('Ready as Guest'), findsOneWidget);
  });

  testWidgets('invalid names stay on the form without writes', (tester) async {
    final store = MemoryProfileStore();
    await tester.pumpWidget(gate(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a name of up to 32 characters.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '📨' * 17);
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(store.savedNames, isEmpty);
    expect(find.text('Welcome to SkyChat'), findsOneWidget);
  });

  testWidgets('a failed save preserves input and allows retry', (tester) async {
    final store = MemoryProfileStore()..failSave = true;
    await tester.pumpWidget(gate(store));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Alice');
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Your name could not be saved. Check available storage and retry.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'Alice',
    );
    expect(find.text('Ready as Alice'), findsNothing);
    store.failSave = false;
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(find.text('Ready as Alice'), findsOneWidget);
  });

  testWidgets('a failed load offers retry instead of opening connections', (
    tester,
  ) async {
    final store = MemoryProfileStore()..failLoad = true;
    await tester.pumpWidget(gate(store));
    await tester.pumpAndSettle();
    expect(
      find.text('Your profile could not be opened. Please retry.'),
      findsOneWidget,
    );
    store.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to SkyChat'), findsOneWidget);
  });

  testWidgets(
    'only one save is accepted and the home screen waits for completion',
    (tester) async {
      final store = MemoryProfileStore()..saving = Completer<void>();
      await tester.pumpWidget(gate(store));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Alice');
      await tester.tap(find.text('Start chatting'));
      await tester.tap(find.text('Start chatting'));
      await tester.pumpAndSettle();
      expect(find.text('Ready as Alice'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Continue as Guest'),
            )
            .onPressed,
        isNull,
      );
      expect(store.savedNames, ['Alice']);
      store.saving!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Ready as Alice'), findsOneWidget);
    },
  );

  testWidgets(
    'an existing valid nickname bypasses setup without being rewritten',
    (tester) async {
      final store = MemoryProfileStore()
        ..profile = const LocalUserProfile(username: 'Janek', configured: true);
      await tester.pumpWidget(gate(store));
      await tester.pumpAndSettle();
      expect(find.text('Ready as Janek'), findsOneWidget);
      expect(store.savedNames, isEmpty);
    },
  );

  testWidgets(
    'the chosen name reaches the chat transport before connection setup',
    (tester) async {
      final chat = ChatSessionController(transport: ControlledTransport());
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            connectivity: FakeConnection(),
            chat: chat,
            initialUsername: 'Alice',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(chat.transport.displayName, 'Alice');
      await tester.pumpWidget(const SizedBox.shrink());
      chat.dispose();
    },
  );

  testWidgets(
    'non-Android apps keep their existing entry flow',
    (tester) async {
      final store = MemoryProfileStore()..failLoad = true;
      await tester.pumpWidget(
        MessengerApp(
          connectivity: FakeConnection(),
          profileStore: store,
          historyStorage: null,
        ),
      );
      await tester.pumpAndSettle();
      expect(store.loads, 0);
      expect(find.text('Welcome to SkyChat'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
