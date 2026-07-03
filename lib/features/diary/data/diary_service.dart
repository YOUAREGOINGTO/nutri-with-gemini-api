import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:nutrinutri/core/db/app_database.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/services/device_id_service.dart';
import 'package:nutrinutri/core/services/sync_service.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class DiaryService {
  DiaryService(this._db, this._deviceId, this._syncService);
  final AppDatabase _db;
  final DeviceIdService _deviceId;
  final SyncService _syncService;
  static const _uuid = Uuid();

  ({int startMs, int endMsInclusive}) _dayBounds(DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final endExclusive = start.add(const Duration(days: 1));
    return (
      startMs: start.millisecondsSinceEpoch,
      endMsInclusive: endExclusive.millisecondsSinceEpoch - 1,
    );
  }

  DiaryEntriesCompanion _entryCompanion(
    DiaryEntry entry, {
    required String deviceId,
    required int now,
    required bool includeId,
  }) {
    final normalizedName = _normalize(entry.name);
    return DiaryEntriesCompanion(
      id: includeId ? Value(entry.id) : const Value.absent(),
      name: Value(entry.name),
      type: Value(entry.type.index),
      timestamp: Value(entry.timestamp.millisecondsSinceEpoch),
      normalizedName: Value(normalizedName),
      imagePath: Value(entry.imagePath),
      icon: Value(entry.icon),
      status: Value(entry.status.index),
      description: Value(entry.description),
      reasoning: Value(entry.reasoning),
      markedForAiReview: Value(entry.markedForAiReview),
      durationMinutes: Value(entry.durationMinutes),
      temperatureValue: Value(entry.temperatureValue),
      temperatureUnit: Value(entry.temperatureUnit),
      temperatureSite: Value(entry.temperatureSite),
      updatedAt: Value(now),
      updatedBy: Value(deviceId),
      deletedAt: const Value(null),
    );
  }

  DiaryEntriesCompanion _entryDeleteCompanion({
    required String deviceId,
    required int now,
  }) {
    return DiaryEntriesCompanion(
      updatedAt: Value(now),
      updatedBy: Value(deviceId),
      deletedAt: Value(now),
    );
  }

  Future<Map<String, Map<NutritionMetricType, double>>> _loadMetricsByEntryId(
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return const {};

    final rows = await (_db.select(
      _db.entryMetrics,
    )..where((t) => t.entryId.isIn(entryIds))).get();

    final metricsByEntryId = <String, Map<NutritionMetricType, double>>{};
    for (final row in rows) {
      if (row.type < 0 || row.type >= NutritionMetricType.values.length) {
        continue;
      }

      final metricType = NutritionMetricType.values[row.type];
      metricsByEntryId.putIfAbsent(
        row.entryId,
        () => <NutritionMetricType, double>{},
      )[metricType] = _roundMetricValue(
        row.value,
      );
    }
    return metricsByEntryId;
  }

  Future<Map<String, List<String>>> _loadImagePathsByEntryId(
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return const {};

    final rows =
        await (_db.select(_db.entryImages)
              ..where((t) => t.entryId.isIn(entryIds))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    final imagesByEntryId = <String, List<String>>{};
    for (final row in rows) {
      imagesByEntryId
          .putIfAbsent(row.entryId, () => <String>[])
          .add(row.localPath);
    }
    return imagesByEntryId;
  }

  Future<void> _replaceMetrics(
    String entryId,
    Map<NutritionMetricType, double> metrics,
  ) async {
    final nextMetrics = <NutritionMetricType, double>{};
    for (final metric in NutritionMetricType.values) {
      final raw = metrics[metric] ?? 0;
      final value = _roundMetricValue(raw);
      if (!value.isFinite) continue;
      if (metric != NutritionMetricType.calories && value == 0) {
        continue;
      }
      nextMetrics[metric] = value;
    }
    nextMetrics.putIfAbsent(NutritionMetricType.calories, () => 0);

    await (_db.delete(
      _db.entryMetrics,
    )..where((t) => t.entryId.equals(entryId))).go();

    if (nextMetrics.isEmpty) return;

    final companions = nextMetrics.entries
        .map(
          (entry) => EntryMetricsCompanion.insert(
            entryId: entryId,
            type: entry.key.index,
            value: entry.value,
          ),
        )
        .toList(growable: false);

    await _db.batch((batch) {
      batch.insertAll(_db.entryMetrics, companions);
    });
  }

  Future<void> _replaceImages(
    String entryId,
    List<String> imagePaths, {
    required int now,
  }) async {
    final uniquePaths = <String>[];
    final seen = <String>{};
    for (final path in imagePaths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      uniquePaths.add(trimmed);
    }

    await (_db.delete(
      _db.entryImages,
    )..where((t) => t.entryId.equals(entryId))).go();

    if (uniquePaths.isEmpty) return;

    final companions = <EntryImagesCompanion>[];
    for (var i = 0; i < uniquePaths.length; i++) {
      final path = uniquePaths[i];
      companions.add(
        EntryImagesCompanion.insert(
          id: '$entryId-image-${i + 1}',
          entryId: entryId,
          localPath: path,
          originalName: Value(p.basename(path)),
          createdAt: now + i,
        ),
      );
    }

    await _db.batch((batch) {
      batch.insertAll(_db.entryImages, companions);
    });
  }

  Future<List<DiaryEntry>> getEntriesForDate(DateTime date) async {
    final bounds = _dayBounds(date);

    final rows =
        await (_db.select(_db.diaryEntries)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.timestamp.isBetweenValues(
                      bounds.startMs,
                      bounds.endMsInclusive,
                    ),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
            .get();

    final metricsByEntryId = await _loadMetricsByEntryId(
      rows.map((row) => row.id).toList(growable: false),
    );
    final imagesByEntryId = await _loadImagePathsByEntryId(
      rows.map((row) => row.id).toList(growable: false),
    );

    return rows
        .map(
          (row) => _toDomain(
            row,
            metricsByEntryId[row.id] ?? const <NutritionMetricType, double>{},
            imagePaths: imagesByEntryId[row.id],
          ),
        )
        .toList(growable: false);
  }

  Future<void> addEntry(DiaryEntry entry) async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction(() async {
      await _db
          .into(_db.diaryEntries)
          .insert(
            _entryCompanion(
              entry,
              deviceId: deviceId,
              now: now,
              includeId: true,
            ),
            mode: InsertMode.insertOrReplace,
          );
      await _replaceMetrics(entry.id, entry.metrics);
      await _replaceImages(entry.id, entry.imagePaths, now: now);
    });
    unawaited(_syncService.requestSync());
  }

  Future<void> updateEntry(DiaryEntry entry) async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction(() async {
      await (_db.update(
        _db.diaryEntries,
      )..where((t) => t.id.equals(entry.id))).write(
        _entryCompanion(entry, deviceId: deviceId, now: now, includeId: false),
      );
      await _replaceMetrics(entry.id, entry.metrics);
      await _replaceImages(entry.id, entry.imagePaths, now: now);
    });
    unawaited(_syncService.requestSync());
  }

  Future<void> deleteEntry(DiaryEntry entry) async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;

    await (_db.update(_db.diaryEntries)..where((t) => t.id.equals(entry.id)))
        .write(_entryDeleteCompanion(deviceId: deviceId, now: now));
    unawaited(_syncService.requestSync());
  }

  Future<void> setAiReviewMark(DiaryEntry entry, bool marked) async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;

    await (_db.update(_db.diaryEntries)..where((t) => t.id.equals(entry.id)))
        .write(
          DiaryEntriesCompanion(
            markedForAiReview: Value(marked),
            updatedAt: Value(now),
            updatedBy: Value(deviceId),
          ),
        );
    unawaited(_syncService.requestSync());
  }

  Future<({int count, Set<DateTime> affectedDates})> clearAiReviewMarks() async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;
    final markedRows =
        await (_db.select(_db.diaryEntries)
              ..where(
                (t) => t.deletedAt.isNull() & t.markedForAiReview.equals(true),
              ))
            .get();
    final affectedDates = markedRows
        .map((row) {
          final timestamp = DateTime.fromMillisecondsSinceEpoch(row.timestamp);
          return DateTime(timestamp.year, timestamp.month, timestamp.day);
        })
        .toSet();

    final updated = await (_db.update(_db.diaryEntries)
          ..where(
            (t) => t.deletedAt.isNull() & t.markedForAiReview.equals(true),
          ))
        .write(
          DiaryEntriesCompanion(
            markedForAiReview: const Value(false),
            updatedAt: Value(now),
            updatedBy: Value(deviceId),
          ),
        );
    if (updated > 0) {
      unawaited(_syncService.requestSync());
    }
    return (count: updated, affectedDates: affectedDates);
  }

  Future<int> aiReviewMarkCount() async {
    final rows =
        await (_db.select(_db.diaryEntries)
              ..where(
                (t) => t.deletedAt.isNull() & t.markedForAiReview.equals(true),
              ))
            .get();
    return rows.length;
  }

  Future<Map<String, double>> getSummary(DateTime date) async {
    final bounds = _dayBounds(date);

    final rows =
        await (_db.select(_db.diaryEntries)..where(
              (t) =>
                  t.deletedAt.isNull() &
                  t.timestamp.isBetweenValues(
                    bounds.startMs,
                    bounds.endMsInclusive,
                  ),
            ))
            .get();

    final metricsByEntryId = await _loadMetricsByEntryId(
      rows.map((row) => row.id).toList(growable: false),
    );

    final summary = <String, double>{
      for (final metric in NutritionMetricType.values) metric.key: 0,
      'caloriesBurned': 0,
    };

    for (final row in rows) {
      final metrics =
          metricsByEntryId[row.id] ?? const <NutritionMetricType, double>{};

      if (row.type == EntryType.exercise.index) {
        summary['caloriesBurned'] =
            (summary['caloriesBurned'] ?? 0) +
            (metrics[NutritionMetricType.calories] ?? 0);
        continue;
      }

      if (row.type != EntryType.food.index) {
        continue;
      }

      for (final metric in NutritionMetricType.values) {
        summary[metric.key] =
            (summary[metric.key] ?? 0) + (metrics[metric] ?? 0);
      }
    }

    return summary;
  }

  Future<Set<NutritionMetricType>> getConfiguredMetricsForDate(
    DateTime date,
  ) async {
    final bounds = _dayBounds(date);

    final rows =
        await (_db.select(_db.diaryEntries)..where(
              (t) =>
                  t.deletedAt.isNull() &
                  t.timestamp.isBetweenValues(
                    bounds.startMs,
                    bounds.endMsInclusive,
                  ),
            ))
            .get();
    final foodRows = rows
        .where((row) => row.type == EntryType.food.index)
        .toList(growable: false);
    if (foodRows.isEmpty) return const <NutritionMetricType>{};

    final metricsByEntryId = await _loadMetricsByEntryId(
      foodRows.map((row) => row.id).toList(growable: false),
    );

    final configured = <NutritionMetricType>{};
    for (final metric in NutritionMetricType.values) {
      final isConfiguredForEveryFood = foodRows.every((row) {
        final metrics =
            metricsByEntryId[row.id] ?? const <NutritionMetricType, double>{};
        return metrics.containsKey(metric);
      });
      if (isConfiguredForEveryFood) {
        configured.add(metric);
      }
    }
    return configured;
  }

  Future<List<DiaryEntry>> searchEntrySuggestions(
    String query, {
    required EntryType type,
  }) async {
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) return const [];

    final t = _db.diaryEntries;
    final table = t.actualTableName;
    final idCol = t.id.$name;
    final nameCol = t.name.$name;
    final iconCol = t.icon.$name;
    final descriptionCol = t.description.$name;
    final normalizedNameCol = t.normalizedName.$name;
    final deletedAtCol = t.deletedAt.$name;
    final typeCol = t.type.$name;
    final statusCol = t.status.$name;
    final updatedAtCol = t.updatedAt.$name;

    final rows = await _db
        .customSelect(
          '''
SELECT
  $idCol AS id,
  $nameCol AS name,
  $descriptionCol AS description,
  $iconCol AS icon,
  $normalizedNameCol AS normalizedName
FROM $table
WHERE $deletedAtCol IS NULL
  AND $typeCol = ?
  AND $statusCol = ?
  AND (
    $normalizedNameCol LIKE ?
    OR LOWER(COALESCE($descriptionCol, '')) LIKE ?
  )
ORDER BY $updatedAtCol DESC
LIMIT 200
''',
          variables: [
            Variable.withInt(type.index),
            Variable.withInt(FoodEntryStatus.synced.index),
            Variable.withString('%$normalizedQuery%'),
            Variable.withString('%$normalizedQuery%'),
          ],
          readsFrom: {t},
        )
        .get();

    final entryIds = rows
        .map((row) => row.read<String>('id'))
        .toList(growable: false);
    final metricsByEntryId = await _loadMetricsByEntryId(entryIds);

    final seen = <String>{};
    final results = <DiaryEntry>[];
    for (final row in rows) {
      final id = row.read<String>('id');
      final name = row.read<String>('name');
      final description = row.readNullable<String>('description');

      final suggestionText = (description?.trim().isNotEmpty == true)
          ? description!.trim()
          : name;
      final suggestionKey = _normalize(suggestionText);

      if (seen.add(suggestionKey)) {
        results.add(
          DiaryEntry(
            id: '',
            name: name,
            metrics:
                metricsByEntryId[id] ?? const {NutritionMetricType.calories: 0},
            timestamp: DateTime.now(),
            type: type,
            icon: row.readNullable<String>('icon'),
            description: description,
          ),
        );
      }

      if (results.length >= 20) break;
    }

    return results;
  }

  DiaryEntry _toDomain(
    DiaryEntryRow row,
    Map<NutritionMetricType, double> metrics,
    {
    List<String>? imagePaths,
  }) {
    return DiaryEntry(
      id: row.id,
      name: row.name,
      type: _entryType(row.type),
      metrics: metrics,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row.timestamp),
      imagePath: row.imagePath,
      imagePaths: imagePaths,
      icon: row.icon,
      status: _entryStatus(row.status),
      description: row.description,
      reasoning: row.reasoning,
      markedForAiReview: row.markedForAiReview,
      durationMinutes: row.durationMinutes,
      temperatureValue: row.temperatureValue,
      temperatureUnit: row.temperatureUnit,
      temperatureSite: row.temperatureSite,
    );
  }

  Future<List<AiChatMessage>> getChatMessages(String entryId) async {
    final rows =
        await (_db.select(_db.aiChats)
              ..where((t) => t.entryId.equals(entryId))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    return rows.map(_chatToDomain).toList(growable: false);
  }

  Future<void> addChatMessage({
    required String entryId,
    required String role,
    required String content,
    String? metadataJson,
    DateTime? createdAt,
  }) async {
    final now = createdAt ?? DateTime.now();
    await _db
        .into(_db.aiChats)
        .insert(
          AiChatsCompanion.insert(
            id: _uuid.v4(),
            entryId: entryId,
            role: role,
            content: content,
            createdAt: now.millisecondsSinceEpoch,
            metadataJson: Value(metadataJson),
          ),
          mode: InsertMode.insertOrReplace,
        );
    unawaited(_syncService.requestSync());
  }

  Future<void> replaceFoodAnalysisRun({
    required String entryId,
    required String content,
    String? metadataJson,
  }) async {
    final chats = await getChatMessages(entryId);
    AiChatMessage? requestMessage;
    for (final chat in chats.reversed) {
      if (_isFoodAnalysisRequest(chat)) {
        requestMessage = chat;
        break;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final requestId = requestMessage?.id ?? _uuid.v4();

    await _db.transaction(() async {
      if (requestMessage == null) {
        await _db
            .into(_db.aiChats)
            .insert(
              AiChatsCompanion.insert(
                id: requestId,
                entryId: entryId,
                role: 'user',
                content: content,
                createdAt: now,
                metadataJson: Value(metadataJson),
              ),
              mode: InsertMode.insertOrReplace,
            );
      } else {
        await (_db.update(_db.aiChats)..where((t) => t.id.equals(requestId)))
            .write(
              AiChatsCompanion(
                content: Value(content),
                createdAt: Value(now),
                metadataJson: Value(metadataJson),
              ),
            );
      }

      for (final chat in chats) {
        if (chat.id == requestId) continue;
        await (_db.delete(_db.aiChats)..where((t) => t.id.equals(chat.id))).go();
      }
    });
    unawaited(_syncService.requestSync());
  }

  AiChatMessage _chatToDomain(AiChatRow row) {
    return AiChatMessage(
      id: row.id,
      entryId: row.entryId,
      role: row.role,
      content: row.content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      metadataJson: row.metadataJson,
    );
  }

  bool _isFoodAnalysisRequest(AiChatMessage chat) {
    if (chat.role != 'user') return false;
    final rawMetadata = chat.metadataJson;
    if (rawMetadata == null) return false;

    try {
      final metadata = jsonDecode(rawMetadata);
      if (metadata is! Map) return false;
      final kind = metadata['kind']?.toString();
      return kind == 'initial_food_request' || kind == 'rerun_food_request';
    } catch (_) {
      return false;
    }
  }

  double _roundMetricValue(double value) {
    return (value * 10).roundToDouble() / 10;
  }

  EntryType _entryType(int index) {
    if (index < 0 || index >= EntryType.values.length) {
      return EntryType.food;
    }
    return EntryType.values[index];
  }

  FoodEntryStatus _entryStatus(int index) {
    if (index < 0 || index >= FoodEntryStatus.values.length) {
      return FoodEntryStatus.synced;
    }
    return FoodEntryStatus.values[index];
  }

  String _normalize(String value) => value.trim().toLowerCase();
}
