// Location messages travel as PLAIN TEXT so they stay readable on builds
// without the rich bubble (and sync like any text message — no protocol
// addition): "📍 41.008237, 28.978358 ±12m" plus a maps link line. The
// parser is language-agnostic (no localized words in the encoded form).
import 'package:chatblue/core/models/location_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('location message encoding', () {
    test('encode/parse roundtrip keeps coordinates and accuracy', () {
      final text = encodeLocationMessage(
        lat: 41.008237,
        lng: 28.978358,
        accuracyMeters: 12,
      );
      expect(text, startsWith('📍'));
      expect(text, contains('https://maps.google.com/?q='));
      final decoded = parseLocationMessage(text);
      expect(decoded, isNotNull);
      expect(decoded!.lat, closeTo(41.008237, 1e-6));
      expect(decoded.lng, closeTo(28.978358, 1e-6));
      expect(decoded.accuracyMeters, 12);
    });

    test('parses the bare form without accuracy and negative coordinates',
        () {
      final decoded = parseLocationMessage('📍 -33.86882, 151.20929');
      expect(decoded, isNotNull);
      expect(decoded!.lat, closeTo(-33.86882, 1e-6));
      expect(decoded.lng, closeTo(151.20929, 1e-6));
      expect(decoded.accuracyMeters, isNull);
    });

    test('rejects plain and malformed texts', () {
      expect(parseLocationMessage('hello 📍 world'), isNull);
      expect(parseLocationMessage('📍 not coordinates'), isNull);
      expect(parseLocationMessage(''), isNull);
    });
  });
}
