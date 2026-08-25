import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _appId = String.fromEnvironment('FIREBASE_APP_ID');
const _messagingSenderId = String.fromEnvironment(
  'FIREBASE_MESSAGING_SENDER_ID',
);
const _storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
const _iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

void main() {
  runApp(const FirebaseExampleApp());
}

class FirebaseExampleApp extends StatelessWidget {
  const FirebaseExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Firebase + xcross',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      home: const FirebaseExamplePage(),
    );
  }
}

class FirebaseExamplePage extends StatefulWidget {
  const FirebaseExamplePage({super.key});

  @override
  State<FirebaseExamplePage> createState() => _FirebaseExamplePageState();
}

class _FirebaseExamplePageState extends State<FirebaseExamplePage> {
  String _status = 'Initializing Firebase…';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    try {
      await Firebase.initializeApp(
        options: _projectId.isEmpty
            ? null
            : FirebaseOptions(
                apiKey: _apiKey,
                appId: _appId,
                messagingSenderId: _messagingSenderId,
                projectId: _projectId,
                storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
              ),
      );
      if (mounted) {
        setState(() {
          _ready = true;
          _status = _projectId.isEmpty
              ? 'Firebase initialized from GoogleService-Info.plist'
              : 'Firebase initialized: $_projectId';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Firebase startup failed: $error');
    }
  }

  Future<void> _run(String label, Future<String> Function() operation) async {
    setState(() => _status = '$label…');
    try {
      final result = await operation();
      if (mounted) setState(() => _status = result);
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(
          () => _status = '${error.plugin}: ${error.message ?? error.code}',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    }
  }

  Future<String> _signInAnonymously() async {
    final credential = await FirebaseAuth.instance.signInAnonymously();
    return 'Anonymous user: ${credential.user?.uid}';
  }

  Future<String> _signInWithGoogle() async {
    if (_iosClientId.isEmpty) {
      return 'Set GOOGLE_IOS_CLIENT_ID with --dart-define first.';
    }
    final signIn = GoogleSignIn.instance;
    await signIn.initialize(clientId: _iosClientId);
    final account = await signIn.authenticate();
    final credential = GoogleAuthProvider.credential(
      idToken: account.authentication.idToken,
    );
    final result = await FirebaseAuth.instance.signInWithCredential(credential);
    return 'Google user: ${result.user?.email}';
  }

  Future<String> _writeFirestore() async {
    final document = FirebaseFirestore.instance.collection('xcross').doc();
    await document.set({
      'message': 'Hello from Flutter on xcross',
      'createdAt': FieldValue.serverTimestamp(),
    });
    return 'Firestore document: ${document.path}';
  }

  Future<String> _showStorageReference() async {
    final reference = FirebaseStorage.instance.ref('xcross/example.txt');
    return 'Storage reference: gs://${reference.bucket}/${reference.fullPath}';
  }

  Future<String> _requestMessagingPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    final token = await FirebaseMessaging.instance.getToken();
    return 'Messaging: ${settings.authorizationStatus}; token: ${token ?? 'none'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firebase + xcross')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(_status, key: const ValueKey('status')),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _ready
                ? () => _run('Anonymous sign-in', _signInAnonymously)
                : null,
            child: const Text('Firebase anonymous sign-in'),
          ),
          FilledButton(
            onPressed: _ready
                ? () => _run('Google sign-in', _signInWithGoogle)
                : null,
            child: const Text('Google sign-in'),
          ),
          FilledButton(
            onPressed: _ready
                ? () => _run('Firestore write', _writeFirestore)
                : null,
            child: const Text('Write Firestore document'),
          ),
          FilledButton(
            onPressed: _ready
                ? () => _run('Storage', _showStorageReference)
                : null,
            child: const Text('Create Storage reference'),
          ),
          FilledButton(
            onPressed: _ready
                ? () =>
                      _run('Messaging permission', _requestMessagingPermission)
                : null,
            child: const Text('Request messaging permission'),
          ),
        ],
      ),
    );
  }
}
