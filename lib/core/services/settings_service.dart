import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:nutrinutri/core/db/app_database.dart';
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/core/services/device_id_service.dart';

class SettingsService {
  SettingsService(this._db, this._deviceId);
  final AppDatabase _db;
  final DeviceIdService _deviceId;

  static const _settingsId = 1;
  static const _profileId = 1;
  static const _prefAIProvider = 'ai_provider';
  static const _prefGeminiApiKey = 'gemini_api_key';
  static const _geminiBackupApiKeyId = 'gemini_backup';
  static const _providerModelSeparator = ':';
  static const dailyCalculationExportIneligibleDatesPrefKey =
      'daily_calculation_export_ineligible_dates';

  Future<({String deviceId, int now})> _audit() async {
    final deviceId = await _deviceId.getOrCreate();
    final now = DateTime.now().millisecondsSinceEpoch;
    return (deviceId: deviceId, now: now);
  }

  Future<void> saveApiKey(String key) async {
    await saveApiKeyForProvider(AIProvider.openRouter, key);
  }

  Future<String?> getApiKey() async {
    return getApiKeyForProvider(await getAIProvider());
  }

  Future<String?> getOpenRouterApiKey() async {
    return getApiKeyForProvider(AIProvider.openRouter);
  }

  Future<void> saveGeminiBackupApiKey(String key) async {
    final keys = _decodeApiKeys((await _settings())?.apiKey);
    final normalized = key.trim();
    if (normalized.isEmpty) {
      keys.remove(_geminiBackupApiKeyId);
    } else {
      keys[_geminiBackupApiKeyId] = normalized;
    }

    await _updateSettings(apiKey: Value(_encodeApiKeys(keys)));
  }

  Future<String?> getGeminiBackupApiKey() async {
    final keys = _decodeApiKeys((await _settings())?.apiKey);
    final key = keys[_geminiBackupApiKeyId];
    return key?.isNotEmpty == true ? key : null;
  }

  Future<void> saveApiKeyForProvider(AIProvider provider, String key) async {
    final keys = _decodeApiKeys((await _settings())?.apiKey);
    final normalized = key.trim();
    if (normalized.isEmpty) {
      keys.remove(provider.id);
    } else {
      keys[provider.id] = normalized;
    }

    await _updateSettings(apiKey: Value(_encodeApiKeys(keys)));
  }

  Future<String?> getApiKeyForProvider(AIProvider provider) async {
    final keys = _decodeApiKeys((await _settings())?.apiKey);
    final key = keys[provider.id];
    if (key != null && key.isNotEmpty) return key;

    if (provider == AIProvider.gemini) {
      return _localPref(_prefGeminiApiKey);
    }

    return null;
  }

  Future<void> saveAIProvider(AIProvider provider) async {
    await _saveLocalPref(_prefAIProvider, provider.id);
  }

  Future<AIProvider> getAIProvider() async {
    final savedProvider = await _localPref(_prefAIProvider);
    if (savedProvider?.trim().isNotEmpty == true) {
      return AIProvider.fromId(savedProvider);
    }

    final settings = await _settings();
    final modelProvider = _providerFromModelSetting(settings?.aiModel);
    if (modelProvider != null) return modelProvider;

    return AIProvider.openRouter;
  }

  Future<void> saveAIModel(String model) async {
    await saveAIModelForProvider(await getAIProvider(), model);
  }

  Future<void> saveAIModelForProvider(AIProvider provider, String model) async {
    await _updateSettings(aiModel: Value(_encodeModel(provider, model.trim())));
  }

  Future<String> getAIModel() async {
    final settings = await _settings();
    final rawModel = settings?.aiModel;
    final savedProvider = await _localPref(_prefAIProvider);
    final explicitProvider = savedProvider?.trim().isNotEmpty == true
        ? AIProvider.fromId(savedProvider)
        : null;
    final modelProvider = _providerFromModelSetting(rawModel);
    final provider = explicitProvider ?? modelProvider ?? AIProvider.openRouter;

    if (rawModel == null) return provider.defaultModel;
    if (modelProvider != null && modelProvider != provider) {
      return provider.defaultModel;
    }

    return _modelFromSetting(rawModel);
  }

  Future<void> saveFallbackModel(String? model) async {
    await saveFallbackModelForProvider(await getAIProvider(), model);
  }

  Future<void> saveFallbackModelForProvider(
    AIProvider provider,
    String? model,
  ) async {
    final normalized = model?.trim();
    await _updateSettings(
      fallbackModel: Value(
        normalized == null || normalized.isEmpty
            ? null
            : _encodeModel(provider, normalized),
      ),
    );
  }

  Future<String?> getFallbackModel() async {
    return getFallbackModelForProvider(await getAIProvider());
  }

  Future<String?> getFallbackModelForProvider(AIProvider provider) async {
    final settings = await _settings();
    final rawModel = settings?.fallbackModel;
    if (rawModel == null) return null;

    final fallbackProvider = _providerFromModelSetting(rawModel);
    if (fallbackProvider != null && fallbackProvider != provider) {
      return null;
    }

    if (fallbackProvider == null && provider != await getAIProvider()) {
      return null;
    }

    return _modelFromSetting(rawModel);
  }

  Future<void> saveUserProfile({
    required int age,
    required double weight, // kg
    required double height, // cm
    required String gender,
    required String activityLevel,
    required double calorieGoal,
    required Map<NutritionMetricType, double> metricGoals,
    required List<NutritionMetricType> homeMetricTypes,
  }) async {
    final audit = await _audit();

    final goals = <NutritionMetricType, double>{
      ...metricGoals,
      NutritionMetricType.calories: calorieGoal,
    };

    await _db.transaction(() async {
      await _db
          .into(_db.userProfiles)
          .insert(
            UserProfilesCompanion.insert(
              id: Value(_profileId),
              age: age,
              weightKg: weight,
              heightCm: height,
              gender: gender,
              activityLevel: activityLevel,
              homeMetricTypes: Value(serializeHomeMetricTypes(homeMetricTypes)),
              isConfigured: const Value(true),
              updatedAt: Value(audit.now),
              updatedBy: Value(audit.deviceId),
              deletedAt: Value<int?>(null),
            ),
            mode: InsertMode.insertOrReplace,
          );

      await (_db.delete(
        _db.metricGoals,
      )..where((t) => t.profileId.equals(_profileId))).go();

      final goalRows = <MetricGoalsCompanion>[];
      for (final entry in goals.entries) {
        final rounded = _roundMetricValue(entry.value);
        if (rounded <= 0) continue;
        goalRows.add(
          MetricGoalsCompanion.insert(
            profileId: _profileId,
            type: entry.key.index,
            value: rounded,
          ),
        );
      }

      if (goalRows.isEmpty) return;
      await _db.batch((batch) {
        batch.insertAll(_db.metricGoals, goalRows);
      });
    });
  }

  Future<UserProfile?> getUserProfile() async {
    final row =
        await (_db.select(_db.userProfiles)
              ..where((t) => t.id.equals(_profileId) & t.deletedAt.isNull()))
            .getSingleOrNull();

    if (row == null || !row.isConfigured) return null;

    final goalRows = await (_db.select(
      _db.metricGoals,
    )..where((t) => t.profileId.equals(_profileId))).get();

    final goals = <NutritionMetricType, double>{};
    for (final goalRow in goalRows) {
      if (goalRow.type < 0 ||
          goalRow.type >= NutritionMetricType.values.length) {
        continue;
      }
      goals[NutritionMetricType.values[goalRow.type]] = _roundMetricValue(
        goalRow.value,
      );
    }

    return UserProfile(
      age: row.age,
      weightKg: row.weightKg,
      heightCm: row.heightCm,
      gender: row.gender,
      activityLevel: row.activityLevel,
      metricGoals: Map.unmodifiable(goals),
      homeMetricTypes: parseHomeMetricTypes(row.homeMetricTypes),
      isConfigured: row.isConfigured,
    );
  }

  Future<bool> isOnboarded() async {
    final profile = await getUserProfile();
    return profile != null && profile.isConfigured;
  }

  Future<Set<String>> getDailyCalculationExportIneligibleDateKeys() async {
    return parseDailyCalculationExportIneligibleDateKeys(
      await _localPref(dailyCalculationExportIneligibleDatesPrefKey),
    );
  }

  Future<bool> isDailyCalculationExportIneligible(DateTime date) async {
    final dateKeys = await getDailyCalculationExportIneligibleDateKeys();
    return dateKeys.contains(calculationExportDateKey(date));
  }

  Future<void> setDailyCalculationExportIneligible(
    DateTime date, {
    required bool ineligible,
  }) async {
    final dateKeys = await getDailyCalculationExportIneligibleDateKeys();
    final dateKey = calculationExportDateKey(date);
    if (ineligible) {
      dateKeys.add(dateKey);
    } else {
      dateKeys.remove(dateKey);
    }

    await _saveLocalPref(
      dailyCalculationExportIneligibleDatesPrefKey,
      dateKeys.isEmpty
          ? null
          : encodeDailyCalculationExportIneligibleDateKeys(dateKeys),
    );
  }

  static String calculationExportDateKey(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  static Set<String> parseDailyCalculationExportIneligibleDateKeys(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return <String>{};

    Iterable<Object?> values;
    try {
      final decoded = jsonDecode(trimmed);
      values = decoded is List ? decoded : const <Object?>[];
    } catch (_) {
      values = trimmed.split(RegExp(r'[\s,]+'));
    }

    return values
        .map(
          (value) => _normalizeCalculationExportDateKey(
            value?.toString() ?? '',
          ),
        )
        .whereType<String>()
        .toSet();
  }

  static String encodeDailyCalculationExportIneligibleDateKeys(
    Set<String> dateKeys,
  ) {
    final normalized = dateKeys
        .map(_normalizeCalculationExportDateKey)
        .whereType<String>()
        .toList()
      ..sort();
    return jsonEncode(normalized);
  }

  static String? _normalizeCalculationExportDateKey(String value) {
    final match = RegExp(
      r'^(\d{4})-(\d{1,2})-(\d{1,2})$',
    ).firstMatch(value.trim());
    if (match == null) return null;

    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || month == null || day == null) return null;

    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return calculationExportDateKey(parsed);
  }

  Future<AppSettingsRow?> _settings() async {
    return (_db.select(_db.appSettings)
          ..where((t) => t.id.equals(_settingsId) & t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<void> _updateSettings({
    Value<String?> apiKey = const Value.absent(),
    Value<String> aiModel = const Value.absent(),
    Value<String?> fallbackModel = const Value.absent(),
  }) async {
    final audit = await _audit();
    final existing = await _settings();

    final nextApiKey = apiKey.present ? apiKey.value : existing?.apiKey;
    final provider = await getAIProvider();
    final nextAiModel = aiModel.present
        ? aiModel.value
        : (existing?.aiModel ?? _encodeModel(provider, provider.defaultModel));
    final nextFallbackModel = fallbackModel.present
        ? fallbackModel.value
        : existing?.fallbackModel;

    await _db
        .into(_db.appSettings)
        .insert(
          AppSettingsCompanion(
            id: const Value(_settingsId),
            apiKey: Value(nextApiKey),
            aiModel: Value(nextAiModel),
            fallbackModel: Value(nextFallbackModel),
            updatedAt: Value(audit.now),
            updatedBy: Value(audit.deviceId),
            deletedAt: const Value(null),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  double _roundMetricValue(double value) {
    return (value * 10).roundToDouble() / 10;
  }

  Future<String?> _localPref(String key) async {
    final row =
        await (_db.select(_db.localPrefs)..where((t) => t.key.equals(key)))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> _saveLocalPref(String key, String? value) async {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      await (_db.delete(_db.localPrefs)..where((t) => t.key.equals(key))).go();
      return;
    }

    await _db
        .into(_db.localPrefs)
        .insertOnConflictUpdate(
          LocalPrefsCompanion.insert(key: key, value: normalized),
        );
  }

  Map<String, String> _decodeApiKeys(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return {};

    if (!trimmed.startsWith('{')) {
      return {AIProvider.openRouter.id: trimmed};
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String &&
              entry.value is String &&
              (entry.value as String).trim().isNotEmpty)
            entry.key as String: (entry.value as String).trim(),
      };
    } catch (_) {
      return {AIProvider.openRouter.id: trimmed};
    }
  }

  String? _encodeApiKeys(Map<String, String> keys) {
    final normalized = {
      for (final entry in keys.entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    return normalized.isEmpty ? null : jsonEncode(normalized);
  }

  String _encodeModel(AIProvider provider, String model) {
    return '${provider.id}$_providerModelSeparator$model';
  }

  String _modelFromSetting(String raw) {
    for (final provider in AIProvider.values) {
      final prefix = '${provider.id}$_providerModelSeparator';
      if (raw.startsWith(prefix)) return raw.substring(prefix.length);
    }
    return raw;
  }

  AIProvider? _providerFromModelSetting(String? raw) {
    if (raw == null || raw.isEmpty) return null;

    for (final provider in AIProvider.values) {
      if (raw.startsWith('${provider.id}$_providerModelSeparator')) {
        return provider;
      }
    }

    if (raw.startsWith('gemini-') || raw.startsWith('models/gemini-')) {
      return AIProvider.gemini;
    }

    if (raw.contains('/')) return AIProvider.openRouter;

    return null;
  }
}
