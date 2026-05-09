import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:nutrinutri/core/db/app_database.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/services/device_id_service.dart';
import 'package:nutrinutri/core/services/sync_service.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:uuid/uuid.dart';

class DataPortabilityService {
  DataPortabilityService(this._db, this._deviceId, this._syncService);

  final AppDatabase _db;
  final DeviceIdService _deviceId;
  final SyncService _syncService;

  static const _uuid = Uuid();
  static const _baseHeaders = [
    'id',
    'timestamp',
    'date',
    'time',
    'type',
    'name',
    'description',
    'duration_minutes',
    'icon',
  ];

  Future<DataExportResult?> exportCsv() async {
    final rows =
        await (_db.select(_db.diaryEntries)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([
                (t) => OrderingTerm.asc(t.timestamp),
                (t) => OrderingTerm.asc(t.name),
              ]))
            .get();

    final entryIds = rows.map((row) => row.id).toList(growable: false);
    final metricsByEntryId = await _loadMetricsByEntryId(entryIds);
    final csv = _buildCsv(rows, metricsByEntryId);
    final now = DateTime.now();
    final fileName = 'nutrinutri-export-${_datePart(now)}-${_timePart(now)}.csv';

    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Export NutriNutri data',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      bytes: Uint8List.fromList(utf8.encode(csv)),
    );

    if (savedPath == null && !kIsWeb) {
      return null;
    }

    return DataExportResult(entryCount: rows.length, path: savedPath);
  }

  Future<DataImportResult?> importCsv() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import NutriNutri CSV',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw const DataPortabilityException(
        'Could not read the selected CSV file. Try choosing a local copy.',
      );
    }

    final parsedRows = _parseCsv(utf8.decode(bytes, allowMalformed: true));
    if (parsedRows.isEmpty) {
      throw const DataPortabilityException('The selected CSV file is empty.');
    }

    final headers = parsedRows.first.map(_normalizeHeader).toList();
    final headerIndex = <String, int>{
      for (var i = 0; i < headers.length; i++) headers[i]: i,
    };
    if (!headerIndex.containsKey('name')) {
      throw const DataPortabilityException(
        'The CSV must include a "name" column.',
      );
    }

    final entries = <_ImportedCsvEntry>[];
    var skippedRows = 0;
    for (final row in parsedRows.skip(1)) {
      if (row.every((cell) => cell.trim().isEmpty)) {
        continue;
      }

      final entry = _entryFromCsvRow(row, headerIndex);
      if (entry == null) {
        skippedRows++;
        continue;
      }
      entries.add(entry);
    }

    if (entries.isEmpty) {
      return DataImportResult(
        importedEntries: 0,
        skippedRows: skippedRows,
        affectedDates: const {},
      );
    }

    final existingRows =
        await (_db.select(_db.diaryEntries)..where(
              (t) => t.id.isIn(entries.map((entry) => entry.id)),
            ))
            .get();
    final existingImagePaths = {
      for (final row in existingRows) row.id: row.imagePath,
    };

    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;
    final affectedDates = <DateTime>{};

    await _db.transaction(() async {
      for (final entry in entries) {
        affectedDates.add(
          DateTime(
            entry.timestamp.year,
            entry.timestamp.month,
            entry.timestamp.day,
          ),
        );

        await _db
            .into(_db.diaryEntries)
            .insert(
              DiaryEntriesCompanion.insert(
                id: entry.id,
                name: entry.name,
                type: entry.type.index,
                timestamp: entry.timestamp.millisecondsSinceEpoch,
                normalizedName: _normalizeEntryName(entry.name),
                imagePath: Value(existingImagePaths[entry.id]),
                icon: Value(entry.icon),
                status: Value(FoodEntryStatus.synced.index),
                description: Value(entry.description),
                durationMinutes: Value(entry.durationMinutes),
                updatedAt: Value(now),
                updatedBy: Value(deviceId),
                deletedAt: const Value(null),
              ),
              mode: InsertMode.insertOrReplace,
            );

        await (_db.delete(
          _db.entryMetrics,
        )..where((t) => t.entryId.equals(entry.id))).go();

        final metricRows = _metricCompanions(entry.id, entry.metrics);
        if (metricRows.isNotEmpty) {
          await _db.batch((batch) {
            batch.insertAll(_db.entryMetrics, metricRows);
          });
        }
      }
    });

    unawaited(_syncService.requestSync());

    return DataImportResult(
      importedEntries: entries.length,
      skippedRows: skippedRows,
      affectedDates: affectedDates,
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
      )[metricType] = _roundMetric(row.value);
    }
    return metricsByEntryId;
  }

  String _buildCsv(
    List<DiaryEntryRow> rows,
    Map<String, Map<NutritionMetricType, double>> metricsByEntryId,
  ) {
    final headers = [
      ..._baseHeaders,
      ...NutritionMetricType.values.map((metric) => metric.key),
    ];
    final buffer = StringBuffer()..writeln(headers.map(_csvCell).join(','));

    for (final row in rows) {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(row.timestamp);
      final metrics =
          metricsByEntryId[row.id] ?? const <NutritionMetricType, double>{};
      final cells = [
        row.id,
        timestamp.toIso8601String(),
        _datePart(timestamp),
        _clockPart(timestamp),
        _entryTypeName(row.type),
        row.name,
        row.description ?? '',
        row.durationMinutes?.toString() ?? '',
        row.icon ?? '',
        ...NutritionMetricType.values.map(
          (metric) => _formatNumber(metrics[metric] ?? 0),
        ),
      ];
      buffer.writeln(cells.map(_csvCell).join(','));
    }

    return buffer.toString();
  }

  _ImportedCsvEntry? _entryFromCsvRow(
    List<String> row,
    Map<String, int> headerIndex,
  ) {
    final name = _cell(row, headerIndex, 'name').trim();
    if (name.isEmpty) return null;

    final id = _cell(row, headerIndex, 'id').trim();
    final timestamp = _parseTimestamp(row, headerIndex);
    final type = _parseEntryType(_cell(row, headerIndex, 'type'));
    final description = _blankToNull(_cell(row, headerIndex, 'description'));
    final icon = _blankToNull(_cell(row, headerIndex, 'icon'));
    final durationMinutes = _parseInt(
      _cell(row, headerIndex, 'duration_minutes'),
    );
    final metrics = <NutritionMetricType, double>{};

    for (final metric in NutritionMetricType.values) {
      final value = _parseDouble(_cell(row, headerIndex, metric.key));
      if (value != 0 || metric == NutritionMetricType.calories) {
        metrics[metric] = _roundMetric(value);
      }
    }
    metrics.putIfAbsent(NutritionMetricType.calories, () => 0);

    return _ImportedCsvEntry(
      id: id.isEmpty ? _uuid.v4() : id,
      name: name,
      type: type,
      timestamp: timestamp,
      description: description,
      durationMinutes: durationMinutes,
      icon: icon,
      metrics: metrics,
    );
  }

  List<EntryMetricsCompanion> _metricCompanions(
    String entryId,
    Map<NutritionMetricType, double> metrics,
  ) {
    return metrics.entries
        .where((entry) {
          final value = _roundMetric(entry.value);
          return value.isFinite &&
              (entry.key == NutritionMetricType.calories || value != 0);
        })
        .map(
          (entry) => EntryMetricsCompanion.insert(
            entryId: entryId,
            type: entry.key.index,
            value: _roundMetric(entry.value),
          ),
        )
        .toList(growable: false);
  }

  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);

      if (inQuotes) {
        if (code == 34) {
          final hasEscapedQuote =
              i + 1 < input.length && input.codeUnitAt(i + 1) == 34;
          if (hasEscapedQuote) {
            field.writeCharCode(34);
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.writeCharCode(code);
        }
        continue;
      }

      switch (code) {
        case 34:
          if (field.isEmpty) {
            inQuotes = true;
          } else {
            field.writeCharCode(code);
          }
          break;
        case 44:
          row.add(field.toString());
          field = StringBuffer();
          break;
        case 10:
          row.add(field.toString());
          rows.add(row);
          row = <String>[];
          field = StringBuffer();
          break;
        case 13:
          row.add(field.toString());
          rows.add(row);
          row = <String>[];
          field = StringBuffer();
          if (i + 1 < input.length && input.codeUnitAt(i + 1) == 10) {
            i++;
          }
          break;
        default:
          field.writeCharCode(code);
      }
    }

    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }

    return rows;
  }

  DateTime _parseTimestamp(List<String> row, Map<String, int> headerIndex) {
    final rawTimestamp = _cell(row, headerIndex, 'timestamp').trim();
    final timestamp = DateTime.tryParse(rawTimestamp);
    if (timestamp != null) return timestamp;

    final rawDate = _cell(row, headerIndex, 'date').trim();
    final rawTime = _cell(row, headerIndex, 'time').trim();
    final dateParts = rawDate.split('-').map(int.tryParse).toList();
    final timeParts = rawTime.split(':').map(int.tryParse).toList();

    if (dateParts.length >= 3 &&
        dateParts[0] != null &&
        dateParts[1] != null &&
        dateParts[2] != null) {
      return DateTime(
        dateParts[0]!,
        dateParts[1]!,
        dateParts[2]!,
        timeParts.isNotEmpty ? timeParts[0] ?? 0 : 0,
        timeParts.length > 1 ? timeParts[1] ?? 0 : 0,
      );
    }

    return DateTime.now();
  }

  EntryType _parseEntryType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'exercise':
      case 'workout':
      case '1':
        return EntryType.exercise;
      case 'food':
      case 'meal':
      case '0':
      default:
        return EntryType.food;
    }
  }

  String _cell(List<String> row, Map<String, int> headerIndex, String key) {
    final index = headerIndex[_normalizeHeader(key)];
    if (index == null || index < 0 || index >= row.length) return '';
    return row[index];
  }

  String _csvCell(Object? value) {
    final text = value?.toString() ?? '';
    const quote = '"';
    if (text.contains(',') ||
        text.contains(quote) ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '$quote${text.replaceAll(quote, quote + quote)}$quote';
    }
    return text;
  }

  String _entryTypeName(int type) {
    if (type >= 0 && type < EntryType.values.length) {
      return EntryType.values[type].name;
    }
    return EntryType.food.name;
  }

  String _normalizeHeader(String value) {
    return value
        .replaceAll(String.fromCharCode(0xfeff), '')
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
  }

  String _normalizeEntryName(String value) => value.trim().toLowerCase();

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _parseInt(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }

  double _parseDouble(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite) return 0;
    return parsed;
  }

  double _roundMetric(double value) => (value * 10).roundToDouble() / 10;

  String _formatNumber(double value) {
    final rounded = _roundMetric(value);
    if (rounded == rounded.truncateToDouble()) {
      return rounded.toInt().toString();
    }
    return rounded.toStringAsFixed(1);
  }

  String _datePart(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  String _timePart(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour$minute$second';
  }

  String _clockPart(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class DataExportResult {
  const DataExportResult({required this.entryCount, required this.path});

  final int entryCount;
  final String? path;
}

class DataImportResult {
  const DataImportResult({
    required this.importedEntries,
    required this.skippedRows,
    required this.affectedDates,
  });

  final int importedEntries;
  final int skippedRows;
  final Set<DateTime> affectedDates;
}

class DataPortabilityException implements Exception {
  const DataPortabilityException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ImportedCsvEntry {
  const _ImportedCsvEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.timestamp,
    required this.description,
    required this.durationMinutes,
    required this.icon,
    required this.metrics,
  });

  final String id;
  final String name;
  final EntryType type;
  final DateTime timestamp;
  final String? description;
  final int? durationMinutes;
  final String? icon;
  final Map<NutritionMetricType, double> metrics;
}
