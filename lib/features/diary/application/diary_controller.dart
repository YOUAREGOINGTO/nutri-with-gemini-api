import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/core/services/ai_service.dart';
import 'package:nutrinutri/core/utils/icon_utils.dart';
import 'package:nutrinutri/features/dashboard/presentation/dashboard_providers.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'diary_controller.g.dart';

@Riverpod(keepAlive: true)
class DiaryController extends _$DiaryController {
  @override
  FutureOr<void> build() {
    // No state needed initially
  }

  Future<void> addOptimisticEntry({
    required DateTime date,
    required TimeOfDay time,
    String? description,
    String? imagePath,
    List<String>? imagePaths,
    EntryType type = EntryType.food,
  }) async {
    final diaryService = ref.read(diaryServiceProvider);
    final allImagePaths = _normalizeImagePaths(imagePath, imagePaths);
    final timestamp = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    final entry = DiaryEntry(
      id: const Uuid().v4(),
      name: 'Analyzing...',
      type: type,
      metrics: const {NutritionMetricType.calories: 0},
      timestamp: timestamp,
      imagePath: allImagePaths.isEmpty ? null : allImagePaths.first,
      imagePaths: allImagePaths,
      description: description,
      status: FoodEntryStatus.processing,
      icon: _defaultIconForType(type),
    );

    await diaryService.addEntry(entry);
    if (type == EntryType.food) {
      await diaryService.addChatMessage(
        entryId: entry.id,
        role: 'user',
        content: description?.trim().isNotEmpty == true
            ? description!.trim()
            : 'Food log request with ${allImagePaths.length} image(s).',
        metadataJson: jsonEncode({
          'kind': 'initial_food_request',
          'image_paths': allImagePaths,
        }),
      );
    }
    _invalidateDay(timestamp);
    unawaited(_analyzeAndFill(entry));
  }

  Future<void> logWater(int amountInMl) async {
    final diaryService = ref.read(diaryServiceProvider);
    final now = DateTime.now();

    final entry = DiaryEntry(
      id: const Uuid().v4(),
      name: 'Water (${amountInMl}ml)',
      type: EntryType.food,
      metrics: {
        NutritionMetricType.water: amountInMl.toDouble(),
        NutritionMetricType.calories: 0,
      },
      timestamp: now,
      status: FoodEntryStatus.synced,
      icon: 'water_drop',
    );

    await diaryService.addEntry(entry);
    _invalidateDay(now);
  }

  Future<void> cancelAnalysis(DiaryEntry entry) async {
    final aiService = await ref.read(aiServiceProvider.future);
    aiService.cancelRequest(entry.id);

    final cancelledEntry = _entryWithStatus(
      entry,
      name: 'Analysis Cancelled',
      status: FoodEntryStatus.cancelled,
      icon: 'warning',
    );
    await ref.read(diaryServiceProvider).updateEntry(cancelledEntry);
    _invalidateDay(entry.timestamp);
  }

  Future<void> retryAnalysis(DiaryEntry entry) async {
    final processingEntry = _entryWithStatus(
      entry,
      name: 'Analyzing...',
      status: FoodEntryStatus.processing,
      icon: _defaultIconForType(entry.type),
    );
    await ref.read(diaryServiceProvider).updateEntry(processingEntry);
    _invalidateDay(entry.timestamp);
    unawaited(_analyzeAndFill(processingEntry));
  }

  Future<void> correctFoodEntry({
    required DiaryEntry entry,
    required String correctionMessage,
  }) async {
    if (entry.type != EntryType.food) {
      throw Exception('AI corrections are available for food entries only.');
    }

    final message = correctionMessage.trim();
    if (message.isEmpty) {
      throw Exception('Please describe the correction.');
    }

    final diaryService = ref.read(diaryServiceProvider);
    await diaryService.addChatMessage(
      entryId: entry.id,
      role: 'user',
      content: message,
      metadataJson: jsonEncode({'kind': 'food_correction'}),
    );

    final processingEntry = DiaryEntry(
      id: entry.id,
      name: entry.name,
      type: entry.type,
      metrics: entry.metrics,
      timestamp: entry.timestamp,
      imagePath: entry.imagePath,
      imagePaths: entry.imagePaths,
      icon: entry.icon,
      status: FoodEntryStatus.processing,
      description: entry.description,
      reasoning: entry.reasoning,
      durationMinutes: entry.durationMinutes,
    );
    await diaryService.updateEntry(processingEntry);
    _invalidateDay(entry.timestamp);

    final aiService = await ref.read(aiServiceProvider.future);
    final settingsService = ref.read(settingsServiceProvider);
    final fallbackModel = aiService.provider == AIProvider.gemini
        ? null
        : await settingsService.getFallbackModel();
    final base64Images = await _imagesToBase64(entry.imagePaths);

    try {
      final result = await _correctEntry(
        aiService: aiService,
        entry: entry,
        correctionMessage: message,
        base64Images: base64Images,
      );
      await _updateSuccess(entry, result);
      return;
    } catch (error) {
      if (_isCancellationError(error)) return;
    }

    if (fallbackModel != null && fallbackModel.isNotEmpty) {
      try {
        final result = await _correctEntry(
          aiService: aiService,
          entry: entry,
          correctionMessage: message,
          base64Images: base64Images,
          modelOverride: fallbackModel,
        );
        await _updateSuccess(entry, result);
        return;
      } catch (error) {
        if (_isCancellationError(error)) return;
      }
    }

    final failedEntry = DiaryEntry(
      id: entry.id,
      name: entry.name,
      type: entry.type,
      metrics: entry.metrics,
      timestamp: entry.timestamp,
      imagePath: entry.imagePath,
      imagePaths: entry.imagePaths,
      icon: 'warning',
      status: FoodEntryStatus.failed,
      description: entry.description,
      reasoning: entry.reasoning,
      durationMinutes: entry.durationMinutes,
    );
    await diaryService.updateEntry(failedEntry);
    _invalidateDay(entry.timestamp);
    throw Exception('AI correction failed');
  }

  Future<void> _analyzeAndFill(DiaryEntry entry) async {
    final aiService = await ref.read(aiServiceProvider.future);
    final settingsService = ref.read(settingsServiceProvider);
    final fallbackModel = aiService.provider == AIProvider.gemini
        ? null
        : await settingsService.getFallbackModel();
    final userProfile = await settingsService.getUserProfile();
    final base64Images = await _imagesToBase64(entry.imagePaths);

    try {
      final result = await _analyzeEntry(
        aiService: aiService,
        entry: entry,
        userProfile: userProfile,
        base64Images: base64Images,
      );
      await _updateSuccess(entry, result);
      return;
    } catch (error) {
      if (_isCancellationError(error)) {
        return;
      }
    }

    if (fallbackModel != null && fallbackModel.isNotEmpty) {
      try {
        final result = await _analyzeEntry(
          aiService: aiService,
          entry: entry,
          userProfile: userProfile,
          base64Images: base64Images,
          modelOverride: fallbackModel,
        );
        await _updateSuccess(entry, result);
        return;
      } catch (error) {
        if (_isCancellationError(error)) {
          return;
        }
      }
    }

    await _updateFailed(entry);
  }

  Future<void> _updateSuccess(
    DiaryEntry entry,
    Map<String, dynamic> result,
  ) async {
    final aiProvider = _stringValue(result['_ai_provider']);
    final aiKeySource = _stringValue(result['_ai_key_source']);
    final aiModel = _stringValue(result['_ai_model']);
    final aiModelSource = _stringValue(result['_ai_model_source']);
    final normalizedResult = entry.type == EntryType.food
        ? _normalizeFoodResult(result)
        : result;
    final metrics = entry.type == EntryType.exercise
        ? {
            NutritionMetricType.calories: _metricValue(
              normalizedResult,
              NutritionMetricType.calories,
            ),
          }
        : _extractFoodMetrics(normalizedResult);

    final updatedEntry = DiaryEntry(
      id: entry.id,
      name: _stringValue(normalizedResult['food_name']) ?? _fallbackName(entry.type),
      type: entry.type,
      metrics: metrics,
      timestamp: entry.timestamp,
      imagePath: entry.imagePath,
      imagePaths: entry.imagePaths,
      description: entry.description,
      reasoning: entry.type == EntryType.food
          ? _stringValue(normalizedResult['reasoning'])
          : entry.reasoning,
      status: FoodEntryStatus.synced,
      icon: _validateIcon(normalizedResult['icon'], entry.type),
      durationMinutes: entry.type == EntryType.exercise
          ? _toInt(normalizedResult['durationMinutes'])
          : null,
    );

    await ref.read(diaryServiceProvider).updateEntry(updatedEntry);
    if (entry.type == EntryType.food) {
      await ref.read(diaryServiceProvider).addChatMessage(
            entryId: entry.id,
            role: 'assistant',
            content: updatedEntry.reasoning ?? '',
            metadataJson: jsonEncode({
              'ai_result': normalizedResult,
              if (aiProvider != null || aiKeySource != null)
                'ai_request': {
                  if (aiProvider != null) 'provider': aiProvider,
                  if (aiKeySource != null) 'key_source': aiKeySource,
                  if (aiModel != null) 'model': aiModel,
                  if (aiModelSource != null) 'model_source': aiModelSource,
                },
            }),
          );
    }
    _invalidateDay(entry.timestamp);
  }

  Future<Map<String, dynamic>> _analyzeEntry({
    required AIService aiService,
    required DiaryEntry entry,
    required UserProfile? userProfile,
    required List<String> base64Images,
    String? modelOverride,
  }) {
    if (entry.type == EntryType.exercise) {
      return aiService.analyzeExercise(
        textDescription: entry.description ?? 'Unspecified exercise',
        userProfile: userProfile,
        requestId: entry.id,
        modelOverride: modelOverride,
      );
    }

    return aiService.analyzeFood(
      textDescription: entry.description,
      base64Images: base64Images,
      requestId: entry.id,
      modelOverride: modelOverride,
    );
  }

  Future<Map<String, dynamic>> _correctEntry({
    required AIService aiService,
    required DiaryEntry entry,
    required String correctionMessage,
    required List<String> base64Images,
    String? modelOverride,
  }) async {
    final previousAiJson = await _previousAiJson(entry);
    return aiService.correctFoodEntry(
      correctionMessage: correctionMessage,
      currentEntryJson: jsonEncode(_entryJson(entry)),
      previousAiJson: previousAiJson,
      previousReasoning: entry.reasoning ?? '',
      imageMetadataJson: jsonEncode(_imageMetadata(entry)),
      base64Images: base64Images,
      requestId: entry.id,
      modelOverride: modelOverride,
    );
  }

  Future<void> _updateFailed(DiaryEntry entry) async {
    final failedEntry = _entryWithStatus(
      entry,
      name: 'Analysis Failed',
      status: FoodEntryStatus.failed,
      icon: 'warning',
    );
    await ref.read(diaryServiceProvider).updateEntry(failedEntry);
    _invalidateDay(entry.timestamp);
  }

  DiaryEntry _entryWithStatus(
    DiaryEntry entry, {
    required String name,
    required FoodEntryStatus status,
    required String icon,
  }) {
    return DiaryEntry(
      id: entry.id,
      name: name,
      type: entry.type,
      metrics: const {NutritionMetricType.calories: 0},
      timestamp: entry.timestamp,
      imagePath: entry.imagePath,
      imagePaths: entry.imagePaths,
      description: entry.description,
      reasoning: entry.reasoning,
      status: status,
      icon: icon,
      durationMinutes: entry.durationMinutes,
    );
  }

  Future<String?> _imageToBase64(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) return null;
    final file = File(imagePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  Future<List<String>> _imagesToBase64(List<String> imagePaths) async {
    final images = <String>[];
    for (final path in imagePaths) {
      final encoded = await _imageToBase64(path);
      if (encoded != null) images.add(encoded);
    }
    return images;
  }

  List<String> _normalizeImagePaths(String? imagePath, List<String>? imagePaths) {
    final normalized = <String>[];
    final seen = <String>{};

    void add(String? path) {
      final trimmed = path?.trim();
      if (trimmed == null || trimmed.isEmpty || !seen.add(trimmed)) return;
      normalized.add(trimmed);
    }

    add(imagePath);
    if (imagePaths != null) {
      for (final path in imagePaths) {
        add(path);
      }
    }
    return normalized;
  }

  Future<String> _previousAiJson(DiaryEntry entry) async {
    final chats = await ref.read(diaryServiceProvider).getChatMessages(entry.id);
    for (final chat in chats.reversed) {
      if (chat.role != 'assistant' || chat.metadataJson == null) continue;
      try {
        final metadata = jsonDecode(chat.metadataJson!);
        if (metadata is! Map) continue;
        final aiResult = metadata['ai_result'];
        if (aiResult != null) return jsonEncode(aiResult);
      } catch (_) {
        continue;
      }
    }
    return jsonEncode(_entryJson(entry));
  }

  Map<String, Object?> _entryJson(DiaryEntry entry) {
    return {
      'id': entry.id,
      'food_name': entry.name,
      'description': entry.description,
      'reasoning': entry.reasoning,
      'timestamp': entry.timestamp.toIso8601String(),
      'metrics': {
        for (final metric in NutritionMetricType.values)
          metric.key: entry.metricValue(metric),
      },
      'icon': entry.icon,
      'image_paths': entry.imagePaths,
    };
  }

  List<Map<String, Object?>> _imageMetadata(DiaryEntry entry) {
    return [
      for (var i = 0; i < entry.imagePaths.length; i++)
        {
          'index': i + 1,
          'local_path': entry.imagePaths[i],
        },
    ];
  }

  Map<String, dynamic> _normalizeFoodResult(Map<String, dynamic> result) {
    return {
      'food_name': _stringValue(result['food_name']) ?? _fallbackName(EntryType.food),
      'estimated_quantity': _stringValue(result['estimated_quantity']) ?? '',
      'reasoning':
          _stringValue(result['reasoning']) ??
          'Estimated from the supplied food log evidence.',
      'metrics': {
        for (final metric in NutritionMetricType.values)
          metric.key: _safeMetricValue(result, metric),
      },
      'icon': _validateIcon(result['icon'], EntryType.food),
    };
  }

  double _safeMetricValue(
    Map<String, dynamic> result,
    NutritionMetricType type,
  ) {
    final value = _metricValue(result, type);
    if (!value.isFinite || value < 0) return 0;
    return value;
  }

  String? _stringValue(dynamic value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool _isCancellationError(Object error) {
    return error.toString().contains('Request cancelled');
  }

  void _invalidateDay(DateTime dateTime) {
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);
    ref.invalidate(dayEntriesProvider(date));
    ref.invalidate(dailySummaryProvider(date));
  }

  String _fallbackName(EntryType type) {
    return type == EntryType.exercise ? 'Unknown Exercise' : 'Unknown Food';
  }

  String _defaultIconForType(EntryType type) {
    return type == EntryType.exercise ? 'directions_run' : 'restaurant';
  }

  int _toInt(dynamic val) {
    if (val is int) return val;
    if (val is double) return val.round();
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }

  double _toDouble(dynamic val) {
    if (val is double) return val;
    if (val is int) return val.toDouble();
    if (val is String) return double.tryParse(val) ?? 0.0;
    return 0.0;
  }

  Map<NutritionMetricType, double> _extractFoodMetrics(
    Map<String, dynamic> result,
  ) {
    final metrics = <NutritionMetricType, double>{};
    for (final type in NutritionMetricType.values) {
      final value = _metricValue(result, type);
      if (value > 0 || type == NutritionMetricType.calories) {
        metrics[type] = value;
      }
    }
    return metrics;
  }

  double _metricValue(Map<String, dynamic> result, NutritionMetricType type) {
    final metrics = result['metrics'];
    final source = metrics is Map<String, dynamic>
        ? metrics
        : metrics is Map
        ? Map<String, dynamic>.from(metrics)
        : result;

    final value = switch (type) {
      NutritionMetricType.calories => source['calories'] ?? source['kcal'],
      NutritionMetricType.carbs => source['carbs'] ?? source['carb'],
      NutritionMetricType.sugars => source['sugars'] ?? source['sugar'],
      NutritionMetricType.fats => source['fats'] ?? source['fat'],
      NutritionMetricType.saturatedFats =>
        source['saturated_fats'] ??
            source['saturatedFats'] ??
            source['saturated_fat'] ??
            source['sat_fat'],
      NutritionMetricType.protein => source['protein'],
      NutritionMetricType.fiber => source['fiber'] ?? source['fibre'],
      NutritionMetricType.sodium => source['sodium'],
      NutritionMetricType.caffeine => source['caffeine'],
      NutritionMetricType.water => source['water'],
    };
    return _toDouble(value);
  }

  String _validateIcon(dynamic icon, EntryType type) {
    if (icon is String && IconUtils.availableIcons.contains(icon)) {
      return icon;
    }
    return _defaultIconForType(type);
  }
}
