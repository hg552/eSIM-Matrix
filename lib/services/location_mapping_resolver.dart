class LocationCoordinate {
  final double latitude;
  final double longitude;
  final String cityName;
  final String countryCode;

  const LocationCoordinate({
    required this.latitude,
    required this.longitude,
    required this.cityName,
    required this.countryCode,
  });

  @override
  String toString() => '$cityName ($latitude, $longitude)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationCoordinate &&
          runtimeType == other.runtimeType &&
          (latitude - other.latitude).abs() < 0.0001 &&
          (longitude - other.longitude).abs() < 0.0001 &&
          countryCode == other.countryCode;

  @override
  int get hashCode => Object.hash(latitude, longitude, countryCode);
}

class LocationMatchResult {
  final LocationCoordinate? coordinate;
  final String confidence; // 'custom', 'exact_country', 'mcc', 'fallback', 'none'
  final String? matchedKey;

  const LocationMatchResult({
    required this.coordinate,
    required this.confidence,
    this.matchedKey,
  });

  bool get matched => coordinate != null;
}

class LocationMappingResolver {
  const LocationMappingResolver();

  static const Map<String, LocationCoordinate> standardCoordinates = {
    'HK': LocationCoordinate(
      latitude: 22.3193,
      longitude: 114.1694,
      cityName: 'Hong Kong (Tsim Sha Tsui)',
      countryCode: 'HK',
    ),
    'US': LocationCoordinate(
      latitude: 34.0522,
      longitude: -118.2437,
      cityName: 'Los Angeles, USA',
      countryCode: 'US',
    ),
    'EE': LocationCoordinate(
      latitude: 59.4370,
      longitude: 24.7536,
      cityName: 'Tallinn, Estonia',
      countryCode: 'EE',
    ),
    'GB': LocationCoordinate(
      latitude: 51.5074,
      longitude: -0.1278,
      cityName: 'London, UK',
      countryCode: 'GB',
    ),
    'JP': LocationCoordinate(
      latitude: 35.6762,
      longitude: 139.6503,
      cityName: 'Tokyo, Japan',
      countryCode: 'JP',
    ),
    'SG': LocationCoordinate(
      latitude: 1.3521,
      longitude: 103.8198,
      cityName: 'Singapore (Marina Bay)',
      countryCode: 'SG',
    ),
    'DE': LocationCoordinate(
      latitude: 50.1109,
      longitude: 8.6821,
      cityName: 'Frankfurt, Germany',
      countryCode: 'DE',
    ),
    'NL': LocationCoordinate(
      latitude: 52.3676,
      longitude: 4.9041,
      cityName: 'Amsterdam, Netherlands',
      countryCode: 'NL',
    ),
    'FR': LocationCoordinate(
      latitude: 48.8566,
      longitude: 2.3522,
      cityName: 'Paris, France',
      countryCode: 'FR',
    ),
    'TW': LocationCoordinate(
      latitude: 25.0330,
      longitude: 121.5654,
      cityName: 'Taipei, Taiwan',
      countryCode: 'TW',
    ),
    'MO': LocationCoordinate(
      latitude: 22.1987,
      longitude: 113.5439,
      cityName: 'Macau',
      countryCode: 'MO',
    ),
    'AU': LocationCoordinate(
      latitude: -33.8688,
      longitude: 151.2093,
      cityName: 'Sydney, Australia',
      countryCode: 'AU',
    ),
    'CA': LocationCoordinate(
      latitude: 43.6532,
      longitude: -79.3832,
      cityName: 'Toronto, Canada',
      countryCode: 'CA',
    ),
  };

  static const Map<String, String> mccToCountry = {
    '454': 'HK',
    '455': 'MO',
    '310': 'US',
    '311': 'US',
    '312': 'US',
    '313': 'US',
    '314': 'US',
    '315': 'US',
    '316': 'US',
    '248': 'EE',
    '234': 'GB',
    '235': 'GB',
    '440': 'JP',
    '441': 'JP',
    '525': 'SG',
    '262': 'DE',
    '204': 'NL',
    '208': 'FR',
    '466': 'TW',
    '505': 'AU',
    '302': 'CA',
  };

  static final Map<String, List<RegExp>> countryPatterns = {
    'HK': [
      RegExp(r'香港|🇭🇰|hong\s*kong|hkg|\+852\b|club\s*sim', caseSensitive: false),
    ],
    'CA': [
      RegExp(r'加拿大|🇨🇦|canada|toronto|\+1\b.*can', caseSensitive: false),
    ],
    'US': [
      RegExp(r'美国|美國|🇺🇸|\busa?\b|united\s*states|saily|\+1\b', caseSensitive: false),
    ],
    'EE': [
      RegExp(r'爱沙尼亚|愛沙尼亞|🇪🇪|estonia|\+372\b|elisa|乌龟卡|top_connect', caseSensitive: false),
    ],
    'GB': [
      RegExp(r'英国|英國|🇬🇧|\buk\b|britain|london|giffgaff|\+44\b', caseSensitive: false),
    ],
    'JP': [
      RegExp(r'日本|🇯🇵|japan|tokyo|docomo|softbank|\+81\b', caseSensitive: false),
    ],
    'SG': [
      RegExp(r'新加坡|🇸🇬|singapore|\+65\b', caseSensitive: false),
    ],
    'DE': [
      RegExp(r'德国|德國|🇩🇪|germany|frankfurt|\+49\b', caseSensitive: false),
    ],
    'NL': [
      RegExp(r'荷兰|荷蘭|🇳🇱|netherlands|amsterdam|\+31\b', caseSensitive: false),
    ],
    'FR': [
      RegExp(r'法国|法國|🇫🇷|france|paris|\+33\b', caseSensitive: false),
    ],
    'TW': [
      RegExp(r'台湾|台灣|🇹🇼|taiwan|\+886\b', caseSensitive: false),
    ],
    'MO': [
      RegExp(r'澳门|澳門|🇲🇴|macau|\+853\b', caseSensitive: false),
    ],
    'AU': [
      RegExp(r'澳大利亚|澳洲|🇦🇺|australia|sydney|\+61\b', caseSensitive: false),
    ],
  };

  LocationMatchResult resolveLocation({
    required String iccid,
    String? alias,
    String? mcc,
    Map<String, String>? customRules,
  }) {
    // 1. Check custom override rule by ICCID or alias
    if (customRules != null) {
      final customCoordStr = customRules[iccid] ?? (alias != null ? customRules[alias] : null);
      if (customCoordStr != null && customCoordStr.contains(',')) {
        final parts = customCoordStr.split(',');
        final lat = double.tryParse(parts[0].trim());
        final lng = double.tryParse(parts[1].trim());
        if (lat != null && lng != null) {
          final label = parts.length > 2 ? parts[2].trim() : 'Custom';
          return LocationMatchResult(
            coordinate: LocationCoordinate(
              latitude: lat,
              longitude: lng,
              cityName: label,
              countryCode: 'CUSTOM',
            ),
            confidence: 'custom',
            matchedKey: iccid,
          );
        }
      }
    }

    // 2. Exact country matching via Alias regex
    if (alias != null && alias.isNotEmpty) {
      for (final entry in countryPatterns.entries) {
        final code = entry.key;
        for (final reg in entry.value) {
          if (reg.hasMatch(alias)) {
            final coord = standardCoordinates[code];
            if (coord != null) {
              return LocationMatchResult(
                coordinate: coord,
                confidence: 'exact_country',
                matchedKey: code,
              );
            }
          }
        }
      }
    }

    // 3. Fallback to MCC
    if (mcc != null && mcc.isNotEmpty) {
      final code = mccToCountry[mcc];
      if (code != null) {
        final coord = standardCoordinates[code];
        if (coord != null) {
          return LocationMatchResult(
            coordinate: coord,
            confidence: 'mcc',
            matchedKey: code,
          );
        }
      }
    }

    // 4. Default fallback: Hong Kong
    return LocationMatchResult(
      coordinate: standardCoordinates['HK'],
      confidence: 'fallback',
      matchedKey: 'HK',
    );
  }
}
