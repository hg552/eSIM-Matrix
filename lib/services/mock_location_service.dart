import 'dart:async';
import 'package:flutter/services.dart';

class MockLocationStatus {
  final bool isMocking;
  final String mode; // 'system' or 'shizuku'
  final double latitude;
  final double longitude;
  final double accuracy;
  final bool isMockApp;
  final bool isShizukuAvailable;

  /// Test providers actually registered with LocationManager. Empty while
  /// mocking means the injection is not reaching any app.
  final List<String> providers;

  const MockLocationStatus({
    required this.isMocking,
    required this.mode,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.isMockApp,
    required this.isShizukuAvailable,
    this.providers = const <String>[],
  });

  factory MockLocationStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const MockLocationStatus(
        isMocking: false,
        mode: 'system',
        latitude: 0.0,
        longitude: 0.0,
        accuracy: 0.0,
        isMockApp: false,
        isShizukuAvailable: false,
      );
    }
    return MockLocationStatus(
      isMocking: map['isMocking'] as bool? ?? false,
      mode: map['mode'] as String? ?? 'system',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      accuracy: (map['accuracy'] as num?)?.toDouble() ?? 0.0,
      isMockApp: map['isMockApp'] as bool? ?? false,
      isShizukuAvailable: map['isShizukuAvailable'] as bool? ?? false,
      providers: (map['providers'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const <String>[],
    );
  }
}

class MockLocationService {
  static const MethodChannel _channel = MethodChannel('ee.nekoko.mock_location');

  const MockLocationService();

  Future<bool> isMockApp() async {
    try {
      final res = await _channel.invokeMethod<bool>('isMockApp');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isShizukuAvailable() async {
    try {
      final res = await _channel.invokeMethod<bool>('isShizukuAvailable');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> grantMockViaShizuku() async {
    try {
      final res = await _channel.invokeMethod<bool>('grantMockViaShizuku');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startMockLocation({
    required double latitude,
    required double longitude,
    String mode = 'system',
    double accuracy = 3.0,
    double altitude = 15.0,
    String label = '',
  }) async {
    try {
      final res = await _channel.invokeMethod<bool>('startMockLocation', {
        'mode': mode,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'label': label,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopMockLocation() async {
    try {
      final res = await _channel.invokeMethod<bool>('stopMockLocation');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<MockLocationStatus> getStatus() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
      return MockLocationStatus.fromMap(map);
    } catch (_) {
      return const MockLocationStatus(
        isMocking: false,
        mode: 'system',
        latitude: 0.0,
        longitude: 0.0,
        accuracy: 0.0,
        isMockApp: false,
        isShizukuAvailable: false,
      );
    }
  }
}
