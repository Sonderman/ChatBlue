import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Scans every Dart file under `lib/` for GetX residue. Line comments are
/// stripped before matching and block comments are blanked out (newlines
/// preserved so reported line numbers stay accurate). String literals are
/// not parsed, so a `//` inside a string can still hide a match on that
/// line — acceptable for a tripwire.
void main() {
  test('lib/ is free of GetX (imports, API calls, tokens, .tr usage)', () {
    final getx = RegExp(
      r'package:get/'
      r'|\bGet\.[A-Za-z]'
      r'|\bObx\s*\('
      r'|\bGetMaterialApp\b'
      r'|\bGetxController\b'
      r'|\bGetBuilder\b'
      r'|\bGetxService\b'
      r'|\.tr\b|\.trParams',
    );
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final original = f.readAsLinesSync();
      final source = f.readAsStringSync().replaceAllMapped(
            RegExp(r'/\*.*?\*/', dotAll: true),
            (m) => m.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '),
          );
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (getx.hasMatch(code)) {
          offenders.add('${f.path}:${i + 1}: ${original[i]}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('pubspec has no get dependency', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^\s*get:', multiLine: true).hasMatch(pubspec), isFalse);
  });
}
