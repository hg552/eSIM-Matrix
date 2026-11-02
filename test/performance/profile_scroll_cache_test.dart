import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:nlpa2/services/database_service.dart';
import 'package:nlpa2/services/operator_icon_service.dart';
import 'package:nlpa2/services/profile_size_prediction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CountingDatabase database;
  late DatabaseService sizes;
  late OperatorIconService icons;
  setUp(() {
    database = _CountingDatabase();
    sizes = DatabaseService.withDatabase(database);
    icons = OperatorIconService.withDatabase(sizes);
  });

  test(
    'unknown profile size is queried once and becomes a synchronous cache hit',
    () async {
      final db = sizes;
      expect(await db.getProfileSize('test-eid', 'test-iccid'), isNull);
      expect(db.hasCachedProfileSize('test-eid', 'test-iccid'), isTrue);
      expect(await db.getProfileSize('test-eid', 'test-iccid'), isNull);
      expect(database.sizeQueries, 1);
      await db.saveProfileSize('test-eid', 'test-iccid', 12345);
      expect(db.getProfileSizeSync('test-eid', 'test-iccid'), 12345);
      expect(await db.getProfileSize('test-eid', 'test-iccid'), 12345);
      expect(database.sizeQueries, 1);
    },
  );

  test(
    'missing operator icon is not queried again when a card re-enters view',
    () async {
      expect(await icons.getIcon(mcc: '999', mnc: '99'), isNull);
      final initialQueries = database.iconQueries;
      expect(initialQueries, greaterThan(0));
      expect(icons.hasCachedIcon(mcc: '999', mnc: '99'), isTrue);
      expect(await icons.getIcon(mcc: '999', mnc: '99'), isNull);
      expect(database.iconQueries, initialQueries);
    },
  );

  test(
    'reference loading is coalesced and cached predictions retain matching behavior',
    () async {
      final service = ProfileSizePredictionService();
      final first = service.ensureLoaded();
      expect(identical(first, service.ensureLoaded()), isTrue);
      await first;
      final data = jsonDecode(
        await rootBundle.loadString('data/reference_sizes_simple.json'),
      );
      final row = (data['results'] as List).first as Map;
      final rsp = row['rsp'] as String;
      final expected = row['reference_size'] as int;
      expect(service.predictSize(eid: null, smdpAddress: rsp), expected);
      expect(
        service.predictSize(eid: null, smdpAddress: rsp.toUpperCase()),
        expected,
      );
      expect(
        service.predictSize(eid: null, smdpAddress: 'missing.example.invalid'),
        isNull,
      );
      expect(
        service.predictSize(eid: null, smdpAddress: 'MISSING.EXAMPLE.INVALID'),
        isNull,
      );
      final sizes = row['eum_sizes'] as Map?;
      if (sizes != null && sizes.isNotEmpty) {
        final prefix = sizes.keys.first as String;
        expect(
          service.predictSize(
            eid: '${prefix}000000000000000000000000',
            smdpAddress: rsp,
          ),
          sizes[prefix],
        );
      }
    },
  );
}

class _CountingDatabase extends Fake implements Database {
  int sizeQueries = 0;
  int iconQueries = 0;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    if (table == 'profile_storage') sizeQueries++;
    if (table == 'operator_icons') iconQueries++;
    return [];
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async => 1;
}
