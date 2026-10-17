// Native host: environment variables, stdout, files, process memory, exit.
import 'dart:io';
import 'dart:typed_data';

String? hostEnv(String key) => Platform.environment[key];

void out(String line) => stdout.writeln(line);

void saveFile(String path, Uint8List bytes) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

int rssMb() => ProcessInfo.currentRss ~/ (1 << 20);
int maxRssMb() => ProcessInfo.maxRss ~/ (1 << 20);

Future<void> quit() async {
  await stdout.flush();
  exit(0);
}
