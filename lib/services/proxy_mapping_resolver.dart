import '../utils/mcc_mapper.dart';

/// Result of matching a profile to a proxy node.
class ProxyMatchResult {
  const ProxyMatchResult({
    required this.matched,
    this.nodeName,
    this.countryCode,
    this.confidence = 'unmatched',
    this.reason = '',
  });

  final bool matched;
  final String? nodeName;
  final String? countryCode;
  final String confidence; // 'custom_rule', 'exact_country', 'regional_fallback', 'unmatched'
  final String reason;

  Map<String, dynamic> toJson() => {
    'matched': matched,
    if (nodeName != null) 'nodeName': nodeName,
    if (countryCode != null) 'countryCode': countryCode,
    'confidence': confidence,
    'reason': reason,
  };
}

/// Resolves the best matching proxy node for a given eSIM profile.
class ProxyMappingResolver {
  const ProxyMappingResolver();

  static final RegExp _metaNodePattern = RegExp(
    r'(?i)(direct|reject|compatible|traffic|expire|官网|剩余|到期|重置|套餐|群|发布|维护|故障|测试|test|auto|fallback|loadbalance|urltest|roundrobin)',
  );

  /// Standard country keyword regexes used to match node names in Clash subscriptions.
  static final Map<String, RegExp> _countryNodePatterns = {
    'US': RegExp(r'(?i)(us|united\s*states|america|美国|美|洛杉矶|硅谷|波特兰|西雅图|芝加哥|纽约|达拉斯|圣何塞|凤凰城|迈阿密|休斯顿)'),
    'HK': RegExp(r'(?i)(hk|hong\s*kong|hongkong|香港|港)'),
    'TW': RegExp(r'(?i)(tw|taiwan|台湾|台|台北|新北|台中|高雄)'),
    'JP': RegExp(r'(?i)(jp|japan|日本|日|东京|大阪|名古屋|福冈|埼玉)'),
    'SG': RegExp(r'(?i)(sg|singapore|新加坡|狮城|新)'),
    'GB': RegExp(r'(?i)(gb|uk|united\s*kingdom|britain|英国|英|伦敦|曼彻斯特)'),
    'EE': RegExp(r'(?i)(ee|estonia|爱沙尼亚)'),
    'DE': RegExp(r'(?i)(de|germany|德国|德|法兰克福|柏林|慕尼黑)'),
    'CA': RegExp(r'(?i)(ca|canada|加拿大|加|多伦多|温哥华|蒙特利尔)'),
    'AU': RegExp(r'(?i)(au|australia|澳大利亚|澳洲|澳|悉尼|墨尔本|布里斯班)'),
    'FR': RegExp(r'(?i)(fr|france|法国|法|巴黎)'),
    'KR': RegExp(r'(?i)(kr|korea|韩国|韩|首尔)'),
    'NL': RegExp(r'(?i)(nl|netherlands|荷兰|阿姆斯特丹)'),
    'TH': RegExp(r'(?i)(th|thailand|泰国|泰|曼谷)'),
    'MY': RegExp(r'(?i)(my|malaysia|马来西亚|吉隆坡)'),
    'PH': RegExp(r'(?i)(ph|philippines|菲律宾|马尼拉)'),
    'VN': RegExp(r'(?i)(vn|vietnam|越南|河内|胡志明)'),
    'TR': RegExp(r'(?i)(tr|turkey|土耳其|伊斯坦布尔)'),
    'IN': RegExp(r'(?i)(in|india|印度|孟买)'),
    'BR': RegExp(r'(?i)(br|brazil|巴西|圣保罗)'),
    'RU': RegExp(r'(?i)(ru|russia|俄罗斯|莫斯科)'),
    'EU': RegExp(r'(?i)(eu|europe|欧洲|欧)'),
  };

  /// Fallback regional hierarchy when exact country node does not exist in subscription.
  static final Map<String, List<String>> _regionalFallbacks = {
    'EE': ['DE', 'NL', 'GB', 'EU'], // Estonia (EU) -> Germany, Netherlands, UK, Europe
    'MC': ['FR', 'EU'],
    'LI': ['CH', 'DE', 'EU'],
    'NZ': ['AU'],
    'MO': ['HK'],
  };

  /// Decodes Unicode regional indicator flag emojis (e.g. 🇺🇸 -> US).
  static String? decodeFlagEmoji(String text) {
    final runes = text.runes.toList(growable: false);
    for (var i = 0; i < runes.length - 1; i++) {
      final r1 = runes[i];
      final r2 = runes[i + 1];
      if (r1 >= 0x1F1E6 && r1 <= 0x1F1FF && r2 >= 0x1F1E6 && r2 <= 0x1F1FF) {
        final c1 = String.fromCharCode(r1 - 0x1F1E6 + 65);
        final c2 = String.fromCharCode(r2 - 0x1F1E6 + 65);
        return '$c1$c2';
      }
    }
    return null;
  }

  /// Extracts ISO 3166-1 alpha-2 country code from profile metadata.
  String? extractCountryCode({
    String? iccid,
    String? alias,
    String? mcc,
    String? carrierName,
  }) {
    // 1. Check MCC if available
    if (mcc != null && mcc.isNotEmpty) {
      final fromMcc = MccMapper.mccToCountryCode(mcc, iccid: iccid);
      if (fromMcc.isNotEmpty && fromMcc != 'UN') {
        return fromMcc.toUpperCase();
      }
    }

    final searchTarget = '${alias ?? ''} ${carrierName ?? ''}'.trim();
    if (searchTarget.isEmpty) return null;

    // 2. Emoji Flag in alias (e.g. 🇺🇸 -> US)
    final fromFlag = decodeFlagEmoji(searchTarget);
    if (fromFlag != null) return fromFlag.toUpperCase();

    // 3. Dialing prefix in alias
    if (RegExp(r'(?:^|[^\d+])\+1\b').hasMatch(searchTarget)) return 'US';
    if (RegExp(r'(?:^|[^\d+])\+852\b').hasMatch(searchTarget)) return 'HK';
    if (RegExp(r'(?:^|[^\d+])\+372\b').hasMatch(searchTarget)) return 'EE';
    if (RegExp(r'(?:^|[^\d+])\+44\b').hasMatch(searchTarget)) return 'GB';
    if (RegExp(r'(?:^|[^\d+])\+81\b').hasMatch(searchTarget)) return 'JP';
    if (RegExp(r'(?:^|[^\d+])\+65\b').hasMatch(searchTarget)) return 'SG';
    if (RegExp(r'(?:^|[^\d+])\+886\b').hasMatch(searchTarget)) return 'TW';
    if (RegExp(r'(?:^|[^\d+])\+49\b').hasMatch(searchTarget)) return 'DE';
    if (RegExp(r'(?:^|[^\d+])\+61\b').hasMatch(searchTarget)) return 'AU';
    if (RegExp(r'(?:^|[^\d+])\+33\b').hasMatch(searchTarget)) return 'FR';
    if (RegExp(r'(?:^|[^\d+])\+82\b').hasMatch(searchTarget)) return 'KR';
    if (RegExp(r'(?:^|[^\d+])\+66\b').hasMatch(searchTarget)) return 'TH';
    if (RegExp(r'(?:^|[^\d+])\+60\b').hasMatch(searchTarget)) return 'MY';
    if (RegExp(r'(?:^|[^\d+])\+63\b').hasMatch(searchTarget)) return 'PH';
    if (RegExp(r'(?:^|[^\d+])\+84\b').hasMatch(searchTarget)) return 'VN';

    // 4. Keyword / Brand regex
    if (RegExp(r'\b(US|USA|United\s*States|America|Saily|T-Mobile|AT&T|Verizon|Ultra|Mint)\b|美国|美卡|美区', caseSensitive: false).hasMatch(searchTarget)) return 'US';
    if (RegExp(r'\b(HK|Hong\s*Kong|HongKong|CSL|ClubSim|CMHK|Smartone|3HK)\b|香港|港卡', caseSensitive: false).hasMatch(searchTarget)) return 'HK';
    if (RegExp(r'\b(EE|Estonia|Elisa|Tele2)\b|爱沙尼亚', caseSensitive: false).hasMatch(searchTarget)) return 'EE';
    if (RegExp(r'\b(GB|UK|United\s*Kingdom|Giffgaff|Vodafone|O2|EE\s*UK)\b|英国|英卡', caseSensitive: false).hasMatch(searchTarget)) return 'GB';
    if (RegExp(r'\b(JP|Japan|SoftBank|Docomo|Rakuten|IIJmio)\b|日本|日卡', caseSensitive: false).hasMatch(searchTarget)) return 'JP';
    if (RegExp(r'\b(SG|Singapore|Singtel|StarHub|M1)\b|新加坡|狮城', caseSensitive: false).hasMatch(searchTarget)) return 'SG';
    if (RegExp(r'\b(TW|Taiwan|Chunghwa|FarEasTone|TaiwanMobile)\b|台湾|台卡', caseSensitive: false).hasMatch(searchTarget)) return 'TW';
    if (RegExp(r'\b(DE|Germany|Telekom|O2\s*DE)\b|德国', caseSensitive: false).hasMatch(searchTarget)) return 'DE';
    if (RegExp(r'\b(CA|Canada|Rogers|Bell|Telus)\b|加拿大', caseSensitive: false).hasMatch(searchTarget)) return 'CA';
    if (RegExp(r'\b(AU|Australia|Telstra|Optus)\b|澳大利亚|澳洲', caseSensitive: false).hasMatch(searchTarget)) return 'AU';
    if (RegExp(r'\b(FR|France|Orange|SFR|Free)\b|法国', caseSensitive: false).hasMatch(searchTarget)) return 'FR';

    return null;
  }

  /// Finds the best matching node from [candidates] for the given profile attributes.
  ProxyMatchResult resolveNode({
    required List<String> candidates,
    String? iccid,
    String? alias,
    String? mcc,
    String? carrierName,
    Map<String, String>? customRules,
  }) {
    if (candidates.isEmpty) {
      return const ProxyMatchResult(
        matched: false,
        confidence: 'unmatched',
        reason: 'Candidate node list is empty',
      );
    }

    // 1. Check custom overrides (by ICCID or Alias)
    if (customRules != null && customRules.isNotEmpty) {
      final overrideKey = iccid != null && customRules.containsKey(iccid)
          ? iccid
          : (alias != null && customRules.containsKey(alias) ? alias : null);
      if (overrideKey != null) {
        final targetRule = customRules[overrideKey]!.trim();
        // Exact match in candidates
        if (candidates.contains(targetRule)) {
          return ProxyMatchResult(
            matched: true,
            nodeName: targetRule,
            confidence: 'custom_rule',
            reason: 'Matched exact custom rule for $overrideKey',
          );
        }
        // Regex match in candidates
        try {
          final regex = RegExp(targetRule, caseSensitive: false);
          final matchedCandidate = candidates.firstWhere(
            (c) => regex.hasMatch(c),
            orElse: () => '',
          );
          if (matchedCandidate.isNotEmpty) {
            return ProxyMatchResult(
              matched: true,
              nodeName: matchedCandidate,
              confidence: 'custom_rule',
              reason: 'Matched regex rule "$targetRule" for $overrideKey',
            );
          }
        } catch (_) {}
      }
    }

    // Filter candidate nodes to exclude status/meta nodes
    final validCandidates = candidates
        .where((c) => !_metaNodePattern.hasMatch(c))
        .toList(growable: false);
    final pool = validCandidates.isNotEmpty ? validCandidates : candidates;

    // 2. Extract country code
    final country = extractCountryCode(
      iccid: iccid,
      alias: alias,
      mcc: mcc,
      carrierName: carrierName,
    );

    if (country == null) {
      return const ProxyMatchResult(
        matched: false,
        confidence: 'unmatched',
        reason: 'Could not determine country code from profile info',
      );
    }

    // 3. Exact country match
    final pattern = _countryNodePatterns[country];
    if (pattern != null) {
      for (final candidate in pool) {
        if (pattern.hasMatch(candidate)) {
          return ProxyMatchResult(
            matched: true,
            nodeName: candidate,
            countryCode: country,
            confidence: 'exact_country',
            reason: 'Matched country $country node via keyword pattern',
          );
        }
      }
    }

    // 4. Regional fallback (e.g. Estonia -> Germany / Europe)
    final fallbacks = _regionalFallbacks[country] ?? const <String>[];
    for (final fbCountry in fallbacks) {
      final fbPattern = _countryNodePatterns[fbCountry];
      if (fbPattern == null) continue;
      for (final candidate in pool) {
        if (fbPattern.hasMatch(candidate)) {
          return ProxyMatchResult(
            matched: true,
            nodeName: candidate,
            countryCode: country,
            confidence: 'regional_fallback',
            reason: 'Country $country fell back to regional $fbCountry node: $candidate',
          );
        }
      }
    }

    return ProxyMatchResult(
      matched: false,
      countryCode: country,
      confidence: 'unmatched',
      reason: 'No proxy nodes in pool matched country $country or its regional fallbacks',
    );
  }
}
