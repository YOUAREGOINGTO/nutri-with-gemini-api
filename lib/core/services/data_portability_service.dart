import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:nutrinutri/core/db/app_database.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/services/device_id_service.dart';
import 'package:nutrinutri/core/services/sync_service.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class DataPortabilityService {
  DataPortabilityService(this._db, this._deviceId, this._syncService);

  final AppDatabase _db;
  final DeviceIdService _deviceId;
  final SyncService _syncService;

  static const _uuid = Uuid();
  static const _backupVersion = 1;
  static const _appVersion = '0.1.1+2';
  static const _baseHeaders = [
    'id',
    'timestamp',
    'date',
    'time',
    'type',
    'name',
    'description',
    'reasoning',
    'duration_minutes',
    'temperature_value',
    'temperature_unit',
    'temperature_site',
    'temperature_comment',
    'icon',
  ];
  static const _dailyXlsxBaseHeaders = [
    'ID',
    'Timestamp',
    'Date',
    'Time',
    'Type',
    'Name',
    'Description',
    'Reasoning',
    'Duration Minutes',
    'Temperature Value',
    'Temperature Unit',
    'Temperature Site',
    'Temperature Comment',
    'Icon',
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

  Future<DataExportResult?> exportDailyXlsxZip() async {
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
    final rowsByDate = <String, List<DiaryEntryRow>>{};

    for (final row in rows) {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(row.timestamp);
      rowsByDate.putIfAbsent(_datePart(timestamp), () => []).add(row);
    }

    final now = DateTime.now();
    final archive = Archive();

    for (final entry in rowsByDate.entries) {
      final xlsxBytes = _buildDailyXlsx(
        date: entry.key,
        rows: entry.value,
        metricsByEntryId: metricsByEntryId,
        createdAt: now,
      );
      archive.addFile(
        _archiveBytesFile('daily-xlsx/nutrinutri-${entry.key}.xlsx', xlsxBytes),
      );
    }

    if (rowsByDate.isEmpty) {
      archive.addFile(
        _archiveStringFile(
          'README.txt',
          'No diary entries were available when this daily XLSX export was created.',
        ),
      );
    }

    final zipBytes = ZipEncoder().encode(archive);
    final fileName =
        'nutrinutri-daily-xlsx-${_datePart(now)}-${_timePart(now)}.zip';
    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Export NutriNutri daily XLSX files',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      bytes: Uint8List.fromList(zipBytes),
    );

    if (savedPath == null && !kIsWeb) {
      return null;
    }

    return DataExportResult(
      entryCount: rows.length,
      fileCount: rowsByDate.length,
      path: savedPath,
    );
  }

  Future<DataExportResult?> exportBackupZip() async {
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
    final imageRowsByEntryId = await _loadImagesByEntryId(entryIds);
    final chatRowsByEntryId = await _loadChatsByEntryId(entryIds);

    final archive = Archive();
    final manifestEntries = <Map<String, Object?>>[];
    final backupEntries = <Map<String, Object?>>[];

    for (final row in rows) {
      final imageEntries = <Map<String, Object?>>[];
      final imageZipPaths = <String>[];
      final imageRows = imageRowsByEntryId[row.id] ?? const <EntryImageRow>[];

      for (var i = 0; i < imageRows.length; i++) {
        final imageRow = imageRows[i];
        final file = File(imageRow.localPath);
        if (!await file.exists()) continue;

        final bytes = await file.readAsBytes();
        final extension = _safeImageExtension(imageRow.localPath);
        final zipPath = 'images/${row.id}/image-${i + 1}$extension';
        archive.addFile(_archiveBytesFile(zipPath, bytes));
        imageZipPaths.add(zipPath);
        imageEntries.add({
          'id': imageRow.id,
          'entry_id': imageRow.entryId,
          'zip_path': zipPath,
          'original_name': imageRow.originalName ?? p.basename(imageRow.localPath),
          'mime_type': imageRow.mimeType ?? lookupMimeType(imageRow.localPath),
          'created_at': imageRow.createdAt,
        });
      }

      final chats = chatRowsByEntryId[row.id] ?? const <AiChatRow>[];
      final chatPath = chats.isEmpty ? null : 'chats/${row.id}.json';
      if (chatPath != null) {
        archive.addFile(
          _archiveStringFile(
            chatPath,
            _prettyJson(chats.map((chat) => chat.toJson()).toList()),
          ),
        );
      }

      manifestEntries.add({
        'entry_id': row.id,
        'image_file_paths': imageZipPaths,
        'chat_file_path': chatPath,
      });

      backupEntries.add({
        'row': row.toJson(),
        'metrics': (metricsByEntryId[row.id] ?? const {})
            .entries
            .map(
              (entry) => {
                'entry_id': row.id,
                'type': entry.key.index,
                'value': entry.value,
              },
            )
            .toList(growable: false),
        'images': imageEntries,
        'chat_file_path': chatPath,
      });
    }

    final createdAt = DateTime.now();
    final manifest = {
      'backup_version': _backupVersion,
      'app_version': _appVersion,
      'created_at': createdAt.toIso8601String(),
      'entries': manifestEntries,
    };

    archive.addFile(_archiveStringFile('manifest.json', _prettyJson(manifest)));
    archive.addFile(
      _archiveStringFile(
        'entries.json',
        _prettyJson({'entries': backupEntries}),
      ),
    );
    archive.addFile(
      _archiveStringFile('entries.csv', _buildCsv(rows, metricsByEntryId)),
    );

    final zipBytes = ZipEncoder().encode(archive);

    final fileName =
        'nutrinutri-backup-${_datePart(createdAt)}-${_timePart(createdAt)}.zip';
    final savedPath = await FilePicker.saveFile(
      dialogTitle: 'Export NutriNutri backup',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      bytes: Uint8List.fromList(zipBytes),
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
                reasoning: Value(entry.reasoning),
                durationMinutes: Value(entry.durationMinutes),
                temperatureValue: Value(entry.temperatureValue),
                temperatureUnit: Value(entry.temperatureUnit),
                temperatureSite: Value(entry.temperatureSite),
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

  Future<DataImportResult?> importBackupZip() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import NutriNutri backup',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw const DataPortabilityException(
        'Could not read the selected ZIP file. Try choosing a local copy.',
      );
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    final entriesJson = _decodeArchiveJson(archive, 'entries.json');
    final rawEntries = entriesJson is Map ? entriesJson['entries'] : null;
    if (rawEntries is! List) {
      throw const DataPortabilityException(
        'The ZIP backup is missing entries.json.',
      );
    }

    final importedEntries = <_ImportedBackupEntry>[];
    var skippedRows = 0;
    for (final rawEntry in rawEntries) {
      final parsed = await _backupEntryFromJson(archive, rawEntry);
      if (parsed == null) {
        skippedRows++;
        continue;
      }
      importedEntries.add(parsed);
    }

    if (importedEntries.isEmpty) {
      return DataImportResult(
        importedEntries: 0,
        skippedRows: skippedRows,
        affectedDates: const {},
      );
    }

    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;
    final affectedDates = <DateTime>{};

    await _db.transaction(() async {
      for (final entry in importedEntries) {
        final row = entry.row;
        final timestamp = DateTime.fromMillisecondsSinceEpoch(row.timestamp);
        affectedDates.add(
          DateTime(timestamp.year, timestamp.month, timestamp.day),
        );

        final firstImagePath = entry.images.isEmpty
            ? null
            : entry.images.first.localPath.value;
        await _db
            .into(_db.diaryEntries)
            .insert(
              row.copyWith(
                imagePath: Value(firstImagePath),
                updatedAt: now,
                updatedBy: deviceId,
                deletedAt: const Value(null),
              ).toCompanion(false),
              mode: InsertMode.insertOrReplace,
            );

        await (_db.delete(
          _db.entryMetrics,
        )..where((t) => t.entryId.equals(row.id))).go();
        await (_db.delete(
          _db.entryImages,
        )..where((t) => t.entryId.equals(row.id))).go();
        await (_db.delete(
          _db.aiChats,
        )..where((t) => t.entryId.equals(row.id))).go();

        if (entry.metrics.isNotEmpty) {
          await _db.batch((batch) {
            batch.insertAll(_db.entryMetrics, entry.metrics);
          });
        }
        if (entry.images.isNotEmpty) {
          await _db.batch((batch) {
            batch.insertAll(_db.entryImages, entry.images);
          });
        }
        if (entry.chats.isNotEmpty) {
          await _db.batch((batch) {
            batch.insertAll(_db.aiChats, entry.chats);
          });
        }
      }
    });

    unawaited(_syncService.requestSync());

    return DataImportResult(
      importedEntries: importedEntries.length,
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

  Future<Map<String, List<EntryImageRow>>> _loadImagesByEntryId(
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return const {};

    final rows =
        await (_db.select(_db.entryImages)
              ..where((t) => t.entryId.isIn(entryIds))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    final imagesByEntryId = <String, List<EntryImageRow>>{};
    for (final row in rows) {
      imagesByEntryId.putIfAbsent(row.entryId, () => <EntryImageRow>[]).add(row);
    }
    return imagesByEntryId;
  }

  Future<Map<String, List<AiChatRow>>> _loadChatsByEntryId(
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return const {};

    final rows =
        await (_db.select(_db.aiChats)
              ..where((t) => t.entryId.isIn(entryIds))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    final chatsByEntryId = <String, List<AiChatRow>>{};
    for (final row in rows) {
      chatsByEntryId.putIfAbsent(row.entryId, () => <AiChatRow>[]).add(row);
    }
    return chatsByEntryId;
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
        row.reasoning ?? '',
        row.durationMinutes?.toString() ?? '',
        row.temperatureValue == null
            ? ''
            : _formatNumber(row.temperatureValue!),
        row.temperatureUnit ?? '',
        row.temperatureSite ?? '',
        _temperatureComment(row),
        row.icon ?? '',
        ...NutritionMetricType.values.map(
          (metric) => _formatNumber(metrics[metric] ?? 0),
        ),
      ];
      buffer.writeln(cells.map(_csvCell).join(','));
    }

    return buffer.toString();
  }

  Uint8List _buildDailyXlsx({
    required String date,
    required List<DiaryEntryRow> rows,
    required Map<String, Map<NutritionMetricType, double>> metricsByEntryId,
    required DateTime createdAt,
  }) {
    final workbook = Archive();
    final sheetRows = <List<_XlsxCell>>[
      [
        ..._dailyXlsxBaseHeaders.map(_XlsxCell.text),
        ...NutritionMetricType.values.map(
          (metric) => _XlsxCell.text('${metric.label} (${metric.unit})'),
        ),
      ],
    ];

    for (final row in rows) {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(row.timestamp);
      final metrics =
          metricsByEntryId[row.id] ?? const <NutritionMetricType, double>{};
      sheetRows.add([
        _XlsxCell.text(row.id),
        _XlsxCell.text(timestamp.toIso8601String()),
        _XlsxCell.text(_datePart(timestamp)),
        _XlsxCell.text(_clockPart(timestamp)),
        _XlsxCell.text(_entryTypeName(row.type)),
        _XlsxCell.text(row.name),
        _XlsxCell.text(row.description ?? ''),
        _XlsxCell.text(row.reasoning ?? ''),
        _XlsxCell.number(row.durationMinutes),
        _XlsxCell.number(row.temperatureValue),
        _XlsxCell.text(row.temperatureUnit ?? ''),
        _XlsxCell.text(row.temperatureSite ?? ''),
        _XlsxCell.text(_temperatureComment(row)),
        _XlsxCell.text(row.icon ?? ''),
        ...NutritionMetricType.values.map(
          (metric) => _XlsxCell.number(metrics[metric] ?? 0),
        ),
      ]);
    }

    final createdAtUtc = createdAt.toUtc().toIso8601String();
    workbook
      ..addFile(
        _archiveStringFile(
          '[Content_Types].xml',
          _xlsxContentTypesXml(),
        ),
      )
      ..addFile(_archiveStringFile('_rels/.rels', _xlsxRootRelsXml()))
      ..addFile(
        _archiveStringFile(
          'docProps/app.xml',
          _xlsxAppPropertiesXml(),
        ),
      )
      ..addFile(
        _archiveStringFile(
          'docProps/core.xml',
          _xlsxCorePropertiesXml(createdAtUtc),
        ),
      )
      ..addFile(
        _archiveStringFile(
          'xl/_rels/workbook.xml.rels',
          _xlsxWorkbookRelsXml(),
        ),
      )
      ..addFile(_archiveStringFile('xl/workbook.xml', _xlsxWorkbookXml()))
      ..addFile(_archiveStringFile('xl/styles.xml', _xlsxStylesXml()))
      ..addFile(
        _archiveStringFile(
          'xl/worksheets/sheet1.xml',
          _xlsxWorksheetXml(date, sheetRows),
        ),
      );

    return Uint8List.fromList(ZipEncoder().encode(workbook));
  }

  String _xlsxContentTypesXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''';
  }

  String _xlsxRootRelsXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>''';
  }

  String _xlsxWorkbookRelsXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''';
  }

  String _xlsxWorkbookXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Entries" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>''';
  }

  String _xlsxAppPropertiesXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>NutriNutri</Application>
</Properties>''';
  }

  String _xlsxCorePropertiesXml(String createdAtUtc) {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:creator>NutriNutri</dc:creator>
  <cp:lastModifiedBy>NutriNutri</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">$createdAtUtc</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">$createdAtUtc</dcterms:modified>
</cp:coreProperties>''';
  }

  String _xlsxStylesXml() {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font>
    <font><b/><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font>
  </fonts>
  <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFD9EAD3"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1">
    <border><left/><right/><top/><bottom/><diagonal/></border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="2">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
  </cellXfs>
  <cellStyles count="1">
    <cellStyle name="Normal" xfId="0" builtinId="0"/>
  </cellStyles>
</styleSheet>''';
  }

  String _xlsxWorksheetXml(String date, List<List<_XlsxCell>> rows) {
    final columnCount = rows.isEmpty
        ? 1
        : rows.map((row) => row.length).reduce((a, b) => a > b ? a : b);
    final rowCount = rows.length;
    final lastCellRef = '${_xlsxColumnName(columnCount - 1)}$rowCount';
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..writeln(
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
      )
      ..writeln('  <dimension ref="A1:$lastCellRef"/>')
      ..writeln(
        '  <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>',
      )
      ..writeln('  <sheetFormatPr defaultRowHeight="15"/>')
      ..writeln('  <cols>')
      ..writeln('    <col min="1" max="1" width="30" customWidth="1"/>')
      ..writeln('    <col min="2" max="4" width="18" customWidth="1"/>')
      ..writeln('    <col min="5" max="5" width="14" customWidth="1"/>')
      ..writeln('    <col min="6" max="8" width="28" customWidth="1"/>')
      ..writeln('    <col min="9" max="$columnCount" width="16" customWidth="1"/>')
      ..writeln('  </cols>')
      ..writeln('  <sheetData>');

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final excelRowIndex = rowIndex + 1;
      final row = rows[rowIndex];
      buffer.writeln('    <row r="$excelRowIndex">');
      for (var columnIndex = 0; columnIndex < row.length; columnIndex++) {
        final cell = row[columnIndex];
        if (cell.isBlank) continue;

        final ref = '${_xlsxColumnName(columnIndex)}$excelRowIndex';
        final style = rowIndex == 0 ? ' s="1"' : '';
        if (cell.isNumber) {
          buffer.writeln('      <c r="$ref"$style><v>${cell.value}</v></c>');
        } else {
          buffer.writeln(
            '      <c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${_xmlText(cell.value)}</t></is></c>',
          );
        }
      }
      buffer.writeln('    </row>');
    }

    buffer
      ..writeln('  </sheetData>')
      ..writeln('  <autoFilter ref="A1:$lastCellRef"/>')
      ..writeln('  <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>')
      ..writeln('  <headerFooter><oddHeader>&amp;L$date&amp;RNutriNutri</oddHeader></headerFooter>')
      ..writeln('</worksheet>');
    return buffer.toString();
  }

  String _xlsxColumnName(int zeroBasedIndex) {
    var index = zeroBasedIndex + 1;
    final chars = <String>[];
    while (index > 0) {
      final remainder = (index - 1) % 26;
      chars.insert(0, String.fromCharCode(65 + remainder));
      index = (index - remainder - 1) ~/ 26;
    }
    return chars.join();
  }

  String _xmlText(Object? value) {
    final raw = value?.toString() ?? '';
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      if (rune != 0x09 && rune != 0x0A && rune != 0x0D && rune < 0x20) {
        continue;
      }

      switch (rune) {
        case 0x22:
          buffer.write('&quot;');
          break;
        case 0x26:
          buffer.write('&amp;');
          break;
        case 0x27:
          buffer.write('&apos;');
          break;
        case 0x3C:
          buffer.write('&lt;');
          break;
        case 0x3E:
          buffer.write('&gt;');
          break;
        default:
          buffer.writeCharCode(rune);
      }
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
    final reasoning = _blankToNull(_cell(row, headerIndex, 'reasoning'));
    final icon = _blankToNull(_cell(row, headerIndex, 'icon'));
    final durationMinutes = _parseInt(
      _cell(row, headerIndex, 'duration_minutes'),
    );
    final temperatureValue = _parseNullableDouble(
      _cell(row, headerIndex, 'temperature_value'),
    );
    final temperatureUnit = _blankToNull(
      _cell(row, headerIndex, 'temperature_unit'),
    );
    final temperatureSite = _blankToNull(
      _cell(row, headerIndex, 'temperature_site'),
    );
    final description = _entryDescriptionFromCsv(row, headerIndex, type);
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
      reasoning: reasoning,
      durationMinutes: durationMinutes,
      temperatureValue: temperatureValue,
      temperatureUnit: temperatureUnit,
      temperatureSite: temperatureSite,
      icon: icon,
      metrics: metrics,
    );
  }

  String _temperatureComment(DiaryEntryRow row) {
    if (row.type != EntryType.temperature.index) return '';
    return row.description ?? '';
  }

  String? _entryDescriptionFromCsv(
    List<String> row,
    Map<String, int> headerIndex,
    EntryType type,
  ) {
    final description = _blankToNull(_cell(row, headerIndex, 'description'));
    if (type != EntryType.temperature) return description;

    return _blankToNull(_cell(row, headerIndex, 'temperature_comment')) ??
        description;
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

  Future<_ImportedBackupEntry?> _backupEntryFromJson(
    Archive archive,
    Object? raw,
  ) async {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final rowRaw = map['row'];
    if (rowRaw is! Map) return null;

    final DiaryEntryRow row;
    try {
      row = DiaryEntryRow.fromJson(Map<String, dynamic>.from(rowRaw));
    } catch (_) {
      return null;
    }

    final images = await _backupImageCompanions(
      archive,
      row.id,
      map['images'],
    );
    final chats = _backupChatCompanions(
      archive,
      row.id,
      map['chat_file_path']?.toString(),
    );

    return _ImportedBackupEntry(
      row: row,
      metrics: _backupMetricCompanions(row.id, map['metrics']),
      images: images,
      chats: chats,
    );
  }

  List<EntryMetricsCompanion> _backupMetricCompanions(
    String entryId,
    Object? raw,
  ) {
    if (raw is! List) return const [];

    final metrics = <EntryMetricsCompanion>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final type = _jsonInt(map['type']);
      final value = _jsonDouble(map['value']);
      if (type == null || value == null) continue;
      if (type < 0 || type >= NutritionMetricType.values.length) continue;
      metrics.add(
        EntryMetricsCompanion.insert(
          entryId: entryId,
          type: type,
          value: _roundMetric(value),
        ),
      );
    }
    return metrics;
  }

  Future<List<EntryImagesCompanion>> _backupImageCompanions(
    Archive archive,
    String entryId,
    Object? raw,
  ) async {
    if (raw is! List) return const [];

    final images = <EntryImagesCompanion>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final zipPath = map['zip_path']?.toString();
      if (zipPath == null || zipPath.trim().isEmpty) continue;

      final file = _archiveFile(archive, zipPath);
      if (file == null || !file.isFile) continue;
      final bytes = file.readBytes();
      if (bytes == null) continue;

      final localPath = await _restoreBackupImage(
        entryId: entryId,
        index: images.length + 1,
        zipPath: zipPath,
        bytes: bytes,
      );
      images.add(
        EntryImagesCompanion.insert(
          id: _stringOrNull(map['id']) ?? '$entryId-image-${images.length + 1}',
          entryId: entryId,
          localPath: localPath,
          originalName: Value(_stringOrNull(map['original_name'])),
          mimeType: Value(_stringOrNull(map['mime_type'])),
          createdAt:
              _jsonInt(map['created_at']) ??
              DateTime.now().millisecondsSinceEpoch + images.length,
        ),
      );
    }
    return images;
  }

  List<AiChatsCompanion> _backupChatCompanions(
    Archive archive,
    String entryId,
    String? chatPath,
  ) {
    if (chatPath == null || chatPath.trim().isEmpty) return const [];

    final raw = _decodeArchiveJson(archive, chatPath);
    if (raw is! List) return const [];

    final chats = <AiChatsCompanion>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final role = _stringOrNull(map['role']);
      final content = _stringOrNull(map['content']);
      if (role == null || content == null) continue;

      chats.add(
        AiChatsCompanion.insert(
          id: _stringOrNull(map['id']) ?? _uuid.v4(),
          entryId: entryId,
          role: role,
          content: content,
          createdAt:
              _jsonInt(map['createdAt']) ??
              _jsonInt(map['created_at']) ??
              DateTime.now().millisecondsSinceEpoch + chats.length,
          metadataJson: Value(
            _stringOrNull(map['metadataJson']) ??
                _stringOrNull(map['metadata_json']),
          ),
        ),
      );
    }
    return chats;
  }

  Future<String> _restoreBackupImage({
    required String entryId,
    required int index,
    required String zipPath,
    required List<int> bytes,
  }) async {
    final appDirectory = await getApplicationDocumentsDirectory();
    final imageDirectory = Directory(
      p.join(appDirectory.path, 'entry_images', entryId),
    );
    await imageDirectory.create(recursive: true);

    final extension = _safeImageExtension(zipPath);
    final outputFile = File(p.join(imageDirectory.path, 'image-$index$extension'));
    await outputFile.writeAsBytes(bytes, flush: true);
    return outputFile.path;
  }

  Object? _decodeArchiveJson(Archive archive, String path) {
    final file = _archiveFile(archive, path);
    if (file == null || !file.isFile) return null;
    final bytes = file.readBytes();
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  }

  ArchiveFile? _archiveFile(Archive archive, String path) {
    final normalized = path.replaceAll('\\', '/');
    for (final file in archive.files) {
      if (file.name.replaceAll('\\', '/') == normalized) {
        return file;
      }
    }
    return null;
  }

  ArchiveFile _archiveStringFile(String path, String content) {
    final bytes = Uint8List.fromList(utf8.encode(content));
    return ArchiveFile(path, bytes.length, bytes);
  }

  ArchiveFile _archiveBytesFile(String path, List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    return ArchiveFile(path, data.length, data);
  }

  String _safeImageExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    switch (extension) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.webp':
      case '.heic':
        return extension;
      default:
        return '.jpg';
    }
  }

  String _prettyJson(Object? value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String? _stringOrNull(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _jsonInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? _jsonDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
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
      case 'temperature':
      case 'temp':
      case '2':
        return EntryType.temperature;
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

  double? _parseNullableDouble(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite) return null;
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
  const DataExportResult({
    required this.entryCount,
    required this.path,
    this.fileCount,
  });

  final int entryCount;
  final int? fileCount;
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

class _XlsxCell {
  const _XlsxCell._(this.value, {required this.isNumber});

  factory _XlsxCell.text(String value) {
    return _XlsxCell._(value, isNumber: false);
  }

  factory _XlsxCell.number(num? value) {
    if (value == null || !value.isFinite) {
      return const _XlsxCell._('', isNumber: false);
    }
    return _XlsxCell._(value, isNumber: true);
  }

  final Object value;
  final bool isNumber;

  bool get isBlank => value is String && (value as String).isEmpty;
}

class _ImportedCsvEntry {
  const _ImportedCsvEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.timestamp,
    required this.description,
    required this.reasoning,
    required this.durationMinutes,
    required this.temperatureValue,
    required this.temperatureUnit,
    required this.temperatureSite,
    required this.icon,
    required this.metrics,
  });

  final String id;
  final String name;
  final EntryType type;
  final DateTime timestamp;
  final String? description;
  final String? reasoning;
  final int? durationMinutes;
  final double? temperatureValue;
  final String? temperatureUnit;
  final String? temperatureSite;
  final String? icon;
  final Map<NutritionMetricType, double> metrics;
}

class _ImportedBackupEntry {
  const _ImportedBackupEntry({
    required this.row,
    required this.metrics,
    required this.images,
    required this.chats,
  });

  final DiaryEntryRow row;
  final List<EntryMetricsCompanion> metrics;
  final List<EntryImagesCompanion> images;
  final List<AiChatsCompanion> chats;
}
