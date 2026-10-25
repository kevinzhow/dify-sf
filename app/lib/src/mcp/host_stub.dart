import '../auth/auth_controller.dart';

Future<void> startReadonlyMcp({required int port, required String tokenFile, required AuthController auth}) =>
    throw UnsupportedError('MCP listening is available only in the native client');

Never failReadonlyMcpStartup() => throw UnsupportedError('Native MCP startup failed');
