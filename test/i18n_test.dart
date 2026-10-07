import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the l10n contract: en (template) and tr ARB files must expose the
/// same key set, so no locale can silently miss a string after translations
/// move from GetX Translations to gen_l10n.
void main() {
  test('en and tr ARB files expose the same key set', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final tr = jsonDecode(File('lib/l10n/app_tr.arb').readAsStringSync())
        as Map<String, dynamic>;

    final enKeys = en.keys.where((k) => !k.startsWith('@')).toSet();
    final trKeys = tr.keys.where((k) => !k.startsWith('@')).toSet();

    expect(
      trKeys.difference(enKeys),
      isEmpty,
      reason: 'TR contains keys missing from the EN template',
    );
    expect(
      enKeys.difference(trKeys),
      isEmpty,
      reason: 'EN contains keys missing from the TR translation',
    );
  });

  test('placeholder keys appear in both locales for parameterized strings', () {
    Map<String, dynamic> load(String file) =>
        jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
    final en = load('lib/l10n/app_en.arb');
    final tr = load('lib/l10n/app_tr.arb');

    final paramKeys = en.keys
        .where((k) => !k.startsWith('@') && en[k].toString().contains('{'))
        .toList();
    expect(paramKeys, isNotEmpty);
    for (final key in paramKeys) {
      // NOTE: Dart Set equality is identity-based — compare via difference.
      final enParams = RegExp(r'\{(\w+)\}')
          .allMatches(en[key].toString())
          .map((m) => m.group(1))
          .toSet();
      final trParams = RegExp(r'\{(\w+)\}')
          .allMatches(tr[key].toString())
          .map((m) => m.group(1))
          .toSet();
      expect(trParams.difference(enParams), isEmpty,
          reason: 'TR has extra placeholders for key $key');
      expect(enParams.difference(trParams), isEmpty,
          reason: 'TR is missing placeholders for key $key');
    }
  });
}