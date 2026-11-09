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
class LocationTemplate {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String countryCode;
  final bool isCustom;

  const LocationTemplate({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.countryCode,
    this.isCustom = false,
  });

  String get formattedValue => '$latitude, $longitude, $name';

  String get flagEmoji {
    final code = countryCode.toUpperCase();
    if (code.length != 2) return '📍';
    final first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'countryCode': countryCode,
    'isCustom': isCustom,
  };

  factory LocationTemplate.fromJson(Map<String, dynamic> json) {
    return LocationTemplate(
      id: json['id'] as String? ?? 'tpl_${DateTime.now().microsecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Custom',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      countryCode: json['countryCode'] as String? ?? 'XX',
      isCustom: json['isCustom'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocationTemplate &&
          runtimeType == other.runtimeType &&
          (latitude - other.latitude).abs() < 0.0001 &&
          (longitude - other.longitude).abs() < 0.0001 &&
          name == other.name;

  @override
  int get hashCode => Object.hash(latitude, longitude, name);
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

  static List<LocationTemplate> get builtInTemplates => const [
    LocationTemplate(
      id: 'hk_tst',
      name: '中国香港 · 尖沙咀海旁',
      latitude: 22.3193,
      longitude: 114.1694,
      countryCode: 'HK',
    ),
    LocationTemplate(
      id: 'hk_central',
      name: '中国香港 · 中环金融街',
      latitude: 22.2820,
      longitude: 114.1583,
      countryCode: 'HK',
    ),
    LocationTemplate(
      id: 'us_la',
      name: '美国 · 洛杉矶市政中心',
      latitude: 34.0522,
      longitude: -118.2437,
      countryCode: 'US',
    ),
    LocationTemplate(
      id: 'us_nyc',
      name: '美国 · 纽约曼哈顿时代广场',
      latitude: 40.7580,
      longitude: -73.9855,
      countryCode: 'US',
    ),
    LocationTemplate(
      id: 'us_sf',
      name: '美国 · 旧金山硅谷科技区',
      latitude: 37.7749,
      longitude: -122.4194,
      countryCode: 'US',
    ),
    LocationTemplate(
      id: 'ee_tallinn',
      name: '爱沙尼亚 · 塔林老城中心',
      latitude: 59.4370,
      longitude: 24.7536,
      countryCode: 'EE',
    ),
    LocationTemplate(
      id: 'gb_london',
      name: '英国 · 伦敦特拉法加广场',
      latitude: 51.5074,
      longitude: -0.1278,
      countryCode: 'GB',
    ),
    LocationTemplate(
      id: 'jp_tokyo',
      name: '日本 · 东京新宿商业区',
      latitude: 35.6938,
      longitude: 139.7034,
      countryCode: 'JP',
    ),
    LocationTemplate(
      id: 'jp_osaka',
      name: '日本 · 大阪心斋桥/道顿堀',
      latitude: 34.6687,
      longitude: 135.5013,
      countryCode: 'JP',
    ),
    LocationTemplate(
      id: 'sg_marina',
      name: '新加坡 · 滨海湾金融中心',
      latitude: 1.3521,
      longitude: 103.8198,
      countryCode: 'SG',
    ),
    LocationTemplate(
      id: 'de_frankfurt',
      name: '德国 · 法兰克福欧洲央行',
      latitude: 50.1109,
      longitude: 8.6821,
      countryCode: 'DE',
    ),
    LocationTemplate(
      id: 'fr_paris',
      name: '法国 · 巴黎香榭丽舍大街',
      latitude: 48.8566,
      longitude: 2.3522,
      countryCode: 'FR',
    ),
    LocationTemplate(
      id: 'nl_ams',
      name: '荷兰 · 阿姆斯特丹水坝广场',
      latitude: 52.3676,
      longitude: 4.9041,
      countryCode: 'NL',
    ),
    LocationTemplate(
      id: 'tw_taipei',
      name: '中国台湾 · 台北 101 信义区',
      latitude: 25.0330,
      longitude: 121.5654,
      countryCode: 'TW',
    ),
    LocationTemplate(
      id: 'mo_macau',
      name: '中国澳门 · 路氹城新濠天地',
      latitude: 22.1987,
      longitude: 113.5439,
      countryCode: 'MO',
    ),
    LocationTemplate(
      id: 'au_sydney',
      name: '澳大利亚 · 悉尼歌剧院环形码头',
      latitude: -33.8688,
      longitude: 151.2093,
      countryCode: 'AU',
    ),
    LocationTemplate(
      id: 'ca_toronto',
      name: '加拿大 · 多伦多 CN 塔市中心',
      latitude: 43.6532,
      longitude: -79.3832,
      countryCode: 'CA',
    ),
  ];

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
        if (lat != null &&
            lng != null &&
            lat.isFinite &&
            lng.isFinite &&
            lat >= -90.0 &&
            lat <= 90.0 &&
            lng >= -180.0 &&
            lng <= 180.0) {
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
