import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

class ProfileSizePredictionService extends ChangeNotifier {
  static final Logger _log = Logger('ProfileSizePredictionService');
  static final ProfileSizePredictionService _instance =
      ProfileSizePredictionService._internal();
  factory ProfileSizePredictionService() => _instance;
  ProfileSizePredictionService._internal();

  Map<String, dynamic>? _data;
  final Map<String, List<dynamic>> _byRsp = {};
  Future<void>? _loading;
  final Map<(String?, String?, String?, String?), int?> _predictions = {};
  static const _maxCachedPredictions = 512;

  Future<void> ensureLoaded() {
    if (_data != null) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final jsonString = await rootBundle.loadString(
        'data/reference_sizes_simple.json',
      );
      // The reference file is about 735 KB. Parse it off the mobile UI isolate.
      _data = await compute(_decodeReference, jsonString);
      for (final row in _data!['results'] as List) {
        final rsp = row['rsp'];
        if (rsp is String) {
          (_byRsp[rsp.toLowerCase()] ??= []).add(row);
        }
      }
    } catch (error) {
      _log.severe('Failed to load reference sizes: $error');
      _data = {'results': []};
      _byRsp.clear();
    }
    notifyListeners();
  }

  static Map<String, dynamic> _decodeReference(String source) =>
      Map<String, dynamic>.from(jsonDecode(source) as Map);

  int? predictSize({
    required String? eid,
    String? smdpAddress,
    String? plmn,
    String? serviceProviderName,
  }) {
    if (_data == null) return null;
    final key = (
      eid != null && eid.length >= 8 ? eid.substring(0, 8) : null,
      smdpAddress?.toLowerCase(),
      plmn,
      serviceProviderName?.toLowerCase(),
    );
    if (_predictions.containsKey(key)) return _predictions[key];
    final prediction = _predictUncached(
      eid: eid,
      smdpAddress: smdpAddress,
      plmn: plmn,
      serviceProviderName: serviceProviderName,
    );
    if (_predictions.length >= _maxCachedPredictions) {
      _predictions.remove(_predictions.keys.first);
    }
    return _predictions[key] = prediction;
  }

  int? _predictUncached({
    required String? eid,
    String? smdpAddress,
    String? plmn,
    String? serviceProviderName,
  }) {
    if (_data == null) return null;

    final results = smdpAddress == null
        ? _data!['results'] as List<dynamic>
        : _byRsp[smdpAddress.toLowerCase()] ?? const <dynamic>[];
    final referenceEum = _data!['reference_eum'] as String?;

    // Get EUM prefix from EID (first 8 digits)
    String? eumPrefix;
    if (eid != null && eid.length >= 8) {
      eumPrefix = eid.substring(0, 8);
    }

    // Try to find matching results
    // Priority:
    // 1. RSP + Service Provider + PLMN
    // 2. RSP + Service Provider
    // 3. RSP + PLMN
    // 4. RSP (Fallback)
    // If SM-DP+ is unknown, we prioritize SPN + PLMN
    dynamic bestMatch;
    int bestScore = 0;

    for (final result in results) {
      final rsp = result['rsp'] as String?;
      if (rsp == null) continue;

      int score = 0;
      bool rspMatches = false;

      // Match RSP address (SM-DP+ address)
      if (smdpAddress != null) {
        if (rsp.toLowerCase() == smdpAddress.toLowerCase()) {
          score += 1; // Base score for RSP match
          rspMatches = true;
        } else {
          continue; // Mismatch on provided SMDP
        }
      } else {
        // No SMDP provided, so we treat it as neutral, but we need OTHER matches
        rspMatches = true;
      }

      if (rspMatches) {
        // Check PLMN match
        if (plmn != null && result['plmn'] == plmn) {
          score += 2;
        }

        // Check Service Provider Name match
        // We use a loose contains check or exact match
        if (serviceProviderName != null) {
          final resultSpn = result['serviceProviderName'] as String?;
          if (resultSpn != null &&
              (resultSpn.toLowerCase() == serviceProviderName.toLowerCase() ||
                  serviceProviderName.toLowerCase().contains(
                    resultSpn.toLowerCase(),
                  ))) {
            score += 3; // SPN is very specific
          }
        }

        // If we didn't match RSP explicitly (smdpAddress was null), we require at least one other strong match (SPN or PLMN)
        if (smdpAddress == null && score == 0) continue;

        if (score > bestScore) {
          bestScore = score;
          bestMatch = result;
        }
      }
    }

    if (bestMatch != null) {
      final eumSizes = bestMatch['eum_sizes'] as Map<String, dynamic>?;

      // If we have an EUM prefix and it exists in eum_sizes, use it
      if (eumPrefix != null &&
          eumSizes != null &&
          eumSizes.containsKey(eumPrefix)) {
        return eumSizes[eumPrefix] as int;
      }

      // Otherwise fallback to reference_size or the reference_eum entry if prefix matches reference
      if (eumPrefix != null && eumPrefix == referenceEum) {
        return bestMatch['reference_size'] as int;
      }

      // If no prefix match, still use reference_size as the best guess
      return bestMatch['reference_size'] as int;
    }

    return null;
  }
}
