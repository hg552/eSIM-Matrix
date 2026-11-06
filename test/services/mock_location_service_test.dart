import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/mock_location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ee.nekoko.mock_location');

  group('MockLocationStatus', () {
    test('fromMap returns default instance when map is null', () {
      final status = MockLocationStatus.fromMap(null);
      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });

    test('fromMap returns default instance when map is empty', () {
      final status = MockLocationStatus.fromMap(<dynamic, dynamic>{});
      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });

    test('fromMap parses valid map with double coordinates correctly', () {
      final status = MockLocationStatus.fromMap(<dynamic, dynamic>{
        'isMocking': true,
        'mode': 'shizuku',
        'latitude': 22.3193,
        'longitude': 114.1694,
        'accuracy': 3.5,
        'isMockApp': true,
        'isShizukuAvailable': true,
      });

      expect(status.isMocking, isTrue);
      expect(status.mode, equals('shizuku'));
      expect(status.latitude, closeTo(22.3193, 0.0001));
      expect(status.longitude, closeTo(114.1694, 0.0001));
      expect(status.accuracy, closeTo(3.5, 0.0001));
      expect(status.isMockApp, isTrue);
      expect(status.isShizukuAvailable, isTrue);
    });

    test('fromMap parses integer coordinates and accuracy as doubles', () {
      final status = MockLocationStatus.fromMap(<dynamic, dynamic>{
        'isMocking': false,
        'mode': 'system',
        'latitude': 34,
        'longitude': -118,
        'accuracy': 5,
        'isMockApp': true,
        'isShizukuAvailable': false,
      });

      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(34.0));
      expect(status.longitude, equals(-118.0));
      expect(status.accuracy, equals(5.0));
      expect(status.isMockApp, isTrue);
      expect(status.isShizukuAvailable, isFalse);
    });

    test('fromMap falls back to defaults for individual missing or null fields', () {
      final status = MockLocationStatus.fromMap(<dynamic, dynamic>{
        'isMocking': null,
        'mode': null,
        'latitude': null,
        'longitude': null,
        'accuracy': null,
        'isMockApp': null,
        'isShizukuAvailable': null,
      });

      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });
  });

  group('MockLocationService - MethodChannel Invocations', () {
    const service = MockLocationService();
    final List<MethodCall> log = <MethodCall>[];

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      log.clear();
    });

    test('isMockApp invokes isMockApp and returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'isMockApp') {
          return true;
        }
        return null;
      });

      final result = await service.isMockApp();

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('isMockApp'));
      expect(log.single.arguments, isNull);
    });

    test('isMockApp invokes isMockApp and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'isMockApp') {
          return false;
        }
        return null;
      });

      final result = await service.isMockApp();

      expect(result, isFalse);
      expect(log, hasLength(1));
      expect(log.single.method, equals('isMockApp'));
      expect(log.single.arguments, isNull);
    });

    test('isShizukuAvailable invokes isShizukuAvailable and returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'isShizukuAvailable') {
          return true;
        }
        return null;
      });

      final result = await service.isShizukuAvailable();

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('isShizukuAvailable'));
      expect(log.single.arguments, isNull);
    });

    test('isShizukuAvailable invokes isShizukuAvailable and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'isShizukuAvailable') {
          return false;
        }
        return null;
      });

      final result = await service.isShizukuAvailable();

      expect(result, isFalse);
      expect(log, hasLength(1));
      expect(log.single.method, equals('isShizukuAvailable'));
      expect(log.single.arguments, isNull);
    });

    test('grantMockViaShizuku invokes grantMockViaShizuku and returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'grantMockViaShizuku') {
          return true;
        }
        return null;
      });

      final result = await service.grantMockViaShizuku();

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('grantMockViaShizuku'));
      expect(log.single.arguments, isNull);
    });

    test('grantMockViaShizuku invokes grantMockViaShizuku and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'grantMockViaShizuku') {
          return false;
        }
        return null;
      });

      final result = await service.grantMockViaShizuku();

      expect(result, isFalse);
      expect(log, hasLength(1));
      expect(log.single.method, equals('grantMockViaShizuku'));
      expect(log.single.arguments, isNull);
    });

    test('startMockLocation invokes startMockLocation with default arguments', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'startMockLocation') {
          return true;
        }
        return null;
      });

      final result = await service.startMockLocation(
        latitude: 34.0522,
        longitude: -118.2437,
      );

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('startMockLocation'));
      expect(log.single.arguments, equals({
        'mode': 'system',
        'latitude': 34.0522,
        'longitude': -118.2437,
        'accuracy': 3.0,
        'altitude': 15.0,
      }));
    });

    test('startMockLocation invokes startMockLocation with custom arguments', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'startMockLocation') {
          return true;
        }
        return null;
      });

      final result = await service.startMockLocation(
        latitude: 59.4370,
        longitude: 24.7536,
        mode: 'shizuku',
        accuracy: 1.5,
        altitude: 42.0,
      );

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('startMockLocation'));
      expect(log.single.arguments, equals({
        'mode': 'shizuku',
        'latitude': 59.4370,
        'longitude': 24.7536,
        'accuracy': 1.5,
        'altitude': 42.0,
      }));
    });

    test('stopMockLocation invokes stopMockLocation and returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'stopMockLocation') {
          return true;
        }
        return null;
      });

      final result = await service.stopMockLocation();

      expect(result, isTrue);
      expect(log, hasLength(1));
      expect(log.single.method, equals('stopMockLocation'));
      expect(log.single.arguments, isNull);
    });

    test('stopMockLocation invokes stopMockLocation and returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'stopMockLocation') {
          return false;
        }
        return null;
      });

      final result = await service.stopMockLocation();

      expect(result, isFalse);
      expect(log, hasLength(1));
      expect(log.single.method, equals('stopMockLocation'));
      expect(log.single.arguments, isNull);
    });

    test('getStatus invokes getStatus and returns parsed MockLocationStatus', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'getStatus') {
          return <dynamic, dynamic>{
            'isMocking': true,
            'mode': 'shizuku',
            'latitude': 22.3193,
            'longitude': 114.1694,
            'accuracy': 3.0,
            'isMockApp': true,
            'isShizukuAvailable': true,
          };
        }
        return null;
      });

      final status = await service.getStatus();

      expect(log, hasLength(1));
      expect(log.single.method, equals('getStatus'));
      expect(log.single.arguments, isNull);

      expect(status.isMocking, isTrue);
      expect(status.mode, equals('shizuku'));
      expect(status.latitude, closeTo(22.3193, 0.0001));
      expect(status.longitude, closeTo(114.1694, 0.0001));
      expect(status.accuracy, closeTo(3.0, 0.0001));
      expect(status.isMockApp, isTrue);
      expect(status.isShizukuAvailable, isTrue);
    });
  });

  group('MockLocationService - Error and Null Handling', () {
    const service = MockLocationService();

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('handles null return values gracefully by returning default values', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      expect(await service.isMockApp(), isFalse);
      expect(await service.isShizukuAvailable(), isFalse);
      expect(await service.grantMockViaShizuku(), isFalse);
      expect(
        await service.startMockLocation(latitude: 10.0, longitude: 20.0),
        isFalse,
      );
      expect(await service.stopMockLocation(), isFalse);

      final status = await service.getStatus();
      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });

    test('handles PlatformException gracefully by returning false or default status', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        throw PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'Mock location permission not granted',
        );
      });

      expect(await service.isMockApp(), isFalse);
      expect(await service.isShizukuAvailable(), isFalse);
      expect(await service.grantMockViaShizuku(), isFalse);
      expect(
        await service.startMockLocation(latitude: 10.0, longitude: 20.0),
        isFalse,
      );
      expect(await service.stopMockLocation(), isFalse);

      final status = await service.getStatus();
      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });

    test('handles MissingPluginException or generic Exception gracefully', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        throw MissingPluginException('No implementation found for method ${methodCall.method}');
      });

      expect(await service.isMockApp(), isFalse);
      expect(await service.isShizukuAvailable(), isFalse);
      expect(await service.grantMockViaShizuku(), isFalse);
      expect(
        await service.startMockLocation(latitude: 10.0, longitude: 20.0),
        isFalse,
      );
      expect(await service.stopMockLocation(), isFalse);

      final status = await service.getStatus();
      expect(status.isMocking, isFalse);
      expect(status.mode, equals('system'));
      expect(status.latitude, equals(0.0));
      expect(status.longitude, equals(0.0));
      expect(status.accuracy, equals(0.0));
      expect(status.isMockApp, isFalse);
      expect(status.isShizukuAvailable, isFalse);
    });
  });
}
