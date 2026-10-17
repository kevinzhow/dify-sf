// Web host: the URL query stands in for environment variables, lines go to the browser console (the test driver
// reads them there), there is no file system or process memory.
import 'dart:typed_data';

String? hostEnv(String key) => Uri.base.queryParameters[key];

// ignore: avoid_print
void out(String line) => print(line);

void saveFile(String path, Uint8List bytes) {}

int rssMb() => 0;
int maxRssMb() => 0;

Future<void> quit() async => out('DONE');
