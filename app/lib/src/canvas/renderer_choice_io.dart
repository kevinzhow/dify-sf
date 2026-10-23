import 'dart:io';

bool preferWidgets() =>
    Platform.environment['FLUTTER_TEST'] == 'true' || Platform.environment['DIFYSF_CANVAS'] == 'widgets';
