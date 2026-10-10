// Location messages travel as PLAIN TEXT so builds without the rich bubble
// still render them readably (and they sync like any text message — no
// protocol addition). The encoded form is language-agnostic — no localized
// words — so any receiver parses it regardless of its UI language:
//
//   📍 41.008237, 28.978358 ±12m
//   https://maps.google.com/?q=41.008237,28.978358
//
// [parseLocationMessage] matches the leading pin + coordinates (±accuracy
// optional) and returns null for everything else, so plain chats are never
// mistaken for locations.

/// Pin emoji that prefixes every encoded location message.
const String locationMessagePrefix = '📍';

/// Decoded coordinates of a location message.
class DecodedLocation {
  const DecodedLocation({
    required this.lat,
    required this.lng,
    this.accuracyMeters,
  });

  final double lat;
  final double lng;
  final int? accuracyMeters;
}

final RegExp _locationPattern = RegExp(
  r'^📍\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)'
  r'(?:\s*±\s*(\d+(?:\.\d+)?)\s*m)?',
);

/// Encodes coordinates as a location message (see the file header).
String encodeLocationMessage({
  required double lat,
  required double lng,
  int? accuracyMeters,
}) {
  final coords = '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
  final accuracy = accuracyMeters == null ? '' : ' ±${accuracyMeters}m';
  return '$locationMessagePrefix $coords$accuracy\n'
      'https://maps.google.com/?q=$lat,$lng';
}

/// Parses [text] as a location message; null when it is not one.
DecodedLocation? parseLocationMessage(String text) {
  final match = _locationPattern.firstMatch(text);
  if (match == null) return null;
  final lat = double.tryParse(match.group(1)!);
  final lng = double.tryParse(match.group(2)!);
  if (lat == null || lng == null) return null;
  final accuracy = match.group(3);
  return DecodedLocation(
    lat: lat,
    lng: lng,
    accuracyMeters:
        accuracy == null ? null : double.tryParse(accuracy)?.round(),
  );
}
