import 'package:flutter/material.dart';

import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/core/services/ai_service.dart';
import 'package:nutrinutri/core/services/sync_service.dart';
import 'package:nutrinutri/core/utils/calorie_calculator.dart';
import 'package:nutrinutri/features/settings/domain/ai_model_info.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'settings_controller.g.dart';

const Object _unset = Object();

class SettingsState {
  SettingsState({
    this.isLoading = false,
    this.isSyncing = false,
    this.isLoadingModels = false,
    this.provider = AIProvider.openRouter,
    String? selectedModel,
    this.fallbackModel,
    this.modelLoadError,
    this.geminiModels = const [],
    this.gender = 'male',
    this.activityLevel = 'sedentary',
    this.homeMetricTypes = defaultHomeMetricTypes,
  }) : selectedModel = selectedModel ?? provider.defaultModel;

  final bool isLoading;
  final bool isSyncing;
  final bool isLoadingModels;
  final AIProvider provider;
  final String selectedModel;
  final String? fallbackModel;
  final String? modelLoadError;
  final List<AIModelInfo> geminiModels;
  final String gender;
  final String activityLevel;
  final List<NutritionMetricType> homeMetricTypes;

  SettingsState copyWith({
    bool? isLoading,
    bool? isSyncing,
    bool? isLoadingModels,
    AIProvider? provider,
    String? selectedModel,
    Object? fallbackModel = _unset,
    Object? modelLoadError = _unset,
    List<AIModelInfo>? geminiModels,
    String? gender,
    String? activityLevel,
    List<NutritionMetricType>? homeMetricTypes,
  }) {
    return SettingsState(
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      isLoadingModels: isLoadingModels ?? this.isLoadingModels,
      provider: provider ?? this.provider,
      selectedModel: selectedModel ?? this.selectedModel,
      fallbackModel: identical(fallbackModel, _unset)
          ? this.fallbackModel
          : fallbackModel as String?,
      modelLoadError: identical(modelLoadError, _unset)
          ? this.modelLoadError
          : modelLoadError as String?,
      geminiModels: geminiModels ?? this.geminiModels,
      gender: gender ?? this.gender,
      activityLevel: activityLevel ?? this.activityLevel,
      homeMetricTypes: homeMetricTypes ?? this.homeMetricTypes,
    );
  }
}

@riverpod
class SettingsController extends _$SettingsController {
  @override
  SettingsState build() {
    return SettingsState();
  }

  Future<void> loadSettings({
    required void Function(String key) onKeyLoaded,
    required void Function(String key) onGeminiBackupKeyLoaded,
    required void Function(String modelId) onCustomModelLoaded,
    required void Function(UserProfile profile) onProfileLoaded,
  }) async {
    final settings = ref.read(settingsServiceProvider);
    final provider = await settings.getAIProvider();
    state = state.copyWith(
      provider: provider,
      selectedModel: provider.defaultModel,
      fallbackModel: null,
    );

    final key = await settings.getApiKeyForProvider(provider);
    if (key != null) {
      onKeyLoaded(key);
    }

    final geminiBackupKey = await settings.getGeminiBackupApiKey();
    if (geminiBackupKey != null) {
      onGeminiBackupKeyLoaded(geminiBackupKey);
    }

    final modelListKey =
        key?.trim().isNotEmpty == true ? key : geminiBackupKey;
    if (provider == AIProvider.gemini &&
        modelListKey?.trim().isNotEmpty == true) {
      await refreshGeminiModels(apiKey: modelListKey!);
    }

    final model = await settings.getAIModel();
    _selectStoredModel(model, onCustomModelLoaded);

    final fallback = await settings.getFallbackModel();
    if (fallback != null && _isKnownModel(fallback)) {
      state = state.copyWith(fallbackModel: fallback);
    }

    final profile = await settings.getUserProfile();
    if (profile != null) {
      state = state.copyWith(
        gender: profile.gender,
        activityLevel: profile.activityLevel,
        homeMetricTypes: profile.dashboardMetricTypes,
      );
      onProfileLoaded(profile);
    }
  }

  void updateProvider(AIProvider provider) {
    state = state.copyWith(
      provider: provider,
      selectedModel: _defaultModelFor(provider),
      fallbackModel: null,
      modelLoadError: null,
    );
  }

  void updateModel(String modelId) {
    state = state.copyWith(selectedModel: modelId);
  }

  void updateFallbackModel(String? modelId) {
    state = state.copyWith(fallbackModel: modelId);
  }

  Future<void> refreshGeminiModels({required String apiKey}) async {
    if (apiKey.trim().isEmpty) {
      state = state.copyWith(
        geminiModels: const [],
        modelLoadError: null,
        isLoadingModels: false,
      );
      return;
    }

    state = state.copyWith(isLoadingModels: true, modelLoadError: null);
    try {
      final descriptors = await AIService.listGeminiModels(apiKey: apiKey);
      final models = descriptors.map(_geminiModelInfo).toList();
      final nextSelectedModel = state.provider == AIProvider.gemini &&
              !models.any((model) => model.id == state.selectedModel) &&
              state.selectedModel != 'custom'
          ? _defaultModelFrom(
              models.isEmpty ? _geminiFallbackModels : models,
            )
          : state.selectedModel;

      state = state.copyWith(
        geminiModels: models,
        isLoadingModels: false,
        selectedModel: nextSelectedModel,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingModels: false,
        modelLoadError: e.toString(),
      );
    }
  }

  void updateGender(String gender) {
    state = state.copyWith(gender: gender);
  }

  void updateActivityLevel(String level) {
    state = state.copyWith(activityLevel: level);
  }

  void updateHomeMetric(int slot, NutritionMetricType metricType) {
    final next = normalizeHomeMetricTypes(state.homeMetricTypes).toList();

    if (slot < 0 || slot >= next.length) return;
    next[slot] = metricType;
    state = state.copyWith(homeMetricTypes: normalizeHomeMetricTypes(next));
  }

  Future<void> save({
    required String apiKey,
    required String geminiBackupApiKey,
    required String customModel,
    required String age,
    required String weight,
    required String height,
    required String calorieGoal,
    required Map<NutritionMetricType, String> metricGoalInputs,
    required List<NutritionMetricType> homeMetricTypes,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final settings = ref.read(settingsServiceProvider);
      await settings.saveAIProvider(state.provider);
      await settings.saveApiKeyForProvider(state.provider, apiKey.trim());
      await settings.saveGeminiBackupApiKey(geminiBackupApiKey.trim());

      final modelToSave = state.selectedModel == 'custom'
          ? customModel.trim()
          : state.selectedModel;
      if (modelToSave.isNotEmpty) {
        await settings.saveAIModelForProvider(state.provider, modelToSave);
      }

      await settings.saveFallbackModel(state.fallbackModel);

      final parsedAge = int.tryParse(age.trim());
      final parsedWeight = _parseGoal(weight);
      final parsedHeight = _parseGoal(height);
      final parsedCalorieGoal = _parseGoal(calorieGoal);

      if (parsedAge != null &&
          parsedWeight != null &&
          parsedHeight != null &&
          parsedCalorieGoal != null &&
          parsedCalorieGoal > 0) {
        final metricGoals = <NutritionMetricType, double>{};
        for (final entry in metricGoalInputs.entries) {
          final parsed = _parseGoal(entry.value);
          if (parsed != null && parsed > 0) {
            metricGoals[entry.key] = parsed;
          }
        }

        await settings.saveUserProfile(
          age: parsedAge,
          weight: parsedWeight,
          height: parsedHeight,
          gender: state.gender,
          activityLevel: state.activityLevel,
          calorieGoal: parsedCalorieGoal,
          metricGoals: metricGoals,
          homeMetricTypes: normalizeHomeMetricTypes(homeMetricTypes),
        );
      }

      ref.invalidate(apiKeyProvider);
      ref.invalidate(aiServiceProvider);
      ref.invalidate(userProfileProvider);
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  double? _parseGoal(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  Future<SyncResult> sync() async {
    state = state.copyWith(isSyncing: true);
    try {
      return await ref.read(syncServiceProvider).sync();
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<void> signIn() async {
    await ref.read(syncServiceProvider).signIn();
  }

  Widget? get webSignInButton => ref.read(syncServiceProvider).webSignInButton;

  Future<void> signOut() async {
    await ref.read(syncServiceProvider).signOut();
  }

  List<AIModelInfo> get availableModels {
    return availableModelsFor(state.provider);
  }

  List<AIModelInfo> availableModelsFor(AIProvider provider) {
    return switch (provider) {
      AIProvider.openRouter => _openRouterModels,
      AIProvider.gemini => state.geminiModels.isEmpty
          ? _geminiFallbackModels
          : [...state.geminiModels, _customGeminiModel],
    };
  }

  int calculateDailyCalories({
    required int age,
    required double weight,
    required double height,
    required String gender,
    required String activityLevel,
  }) {
    return CalorieCalculator.calculateDailyCalories(
      weightKg: weight,
      heightCm: height,
      age: age,
      gender: gender,
      activityLevel: activityLevel,
    );
  }

  void _selectStoredModel(
    String model,
    void Function(String modelId) onCustomModelLoaded,
  ) {
    if (_isKnownModel(model)) {
      state = state.copyWith(selectedModel: model);
      return;
    }

    state = state.copyWith(selectedModel: 'custom');
    onCustomModelLoaded(model);
  }

  bool _isKnownModel(String model) {
    return availableModels.any((availableModel) => availableModel.id == model);
  }

  String _defaultModelFor(AIProvider provider) {
    final models = availableModelsFor(provider);
    if (models.any((model) => model.id == provider.defaultModel)) {
      return provider.defaultModel;
    }

    return _defaultModelFrom(models);
  }

  String _defaultModelFrom(List<AIModelInfo> models) {
    return models
        .firstWhere((model) => model.id != 'custom', orElse: () => models.first)
        .id;
  }

  AIModelInfo _geminiModelInfo(GeminiModelDescriptor descriptor) {
    return AIModelInfo(
      id: descriptor.id,
      name: descriptor.name,
      price: 'Gemini API',
      description: descriptor.description.isNotEmpty
          ? descriptor.description
          : _tokenDescription(descriptor),
    );
  }

  String _tokenDescription(GeminiModelDescriptor descriptor) {
    final input = descriptor.inputTokenLimit;
    final output = descriptor.outputTokenLimit;
    if (input == null && output == null) return 'Available from models.list';
    return 'Input ${_formatTokenLimit(input)} / output ${_formatTokenLimit(output)}';
  }

  String _formatTokenLimit(int? value) {
    if (value == null) return '?';
    if (value >= 1000000) {
      final millions = value / 1000000;
      return '${millions.toStringAsFixed(millions == millions.roundToDouble() ? 0 : 1)}M';
    }
    if (value >= 1000) {
      final thousands = value / 1000;
      return '${thousands.toStringAsFixed(thousands == thousands.roundToDouble() ? 0 : 1)}k';
    }
    return value.toString();
  }

  static const AIModelInfo _customGeminiModel = AIModelInfo(
    id: 'custom',
    name: 'Custom Gemini model',
    price: 'Varies',
    description: 'Enter any Gemini API model ID',
  );

  static const List<AIModelInfo> _geminiFallbackModels = [
    AIModelInfo(
      id: 'gemini-3.1-flash-lite',
      name: 'Gemini 3.1 Flash-Lite',
      price: 'Low',
      description: 'Fast, cost-efficient Gemini API model',
    ),
    AIModelInfo(
      id: 'gemini-3.1-flash-lite-preview',
      name: 'Gemini 3.1 Flash-Lite Preview',
      price: 'Low',
      description: 'Preview Flash-Lite model from Gemini API',
    ),
    AIModelInfo(
      id: 'gemini-3.1-pro-preview',
      name: 'Gemini 3.1 Pro Preview',
      price: 'High',
      description: 'Best Gemini reasoning model',
    ),
    AIModelInfo(
      id: 'gemini-3-flash-preview',
      name: 'Gemini 3 Flash Preview',
      price: 'Medium',
      description: 'Balanced Gemini 3 speed and quality',
    ),
    AIModelInfo(
      id: 'gemini-2.5-flash-lite',
      name: 'Gemini 2.5 Flash-Lite',
      price: 'Low',
      description: 'Stable cost-efficient Gemini model',
    ),
    _customGeminiModel,
  ];

  static const List<AIModelInfo> _openRouterModels = [
    AIModelInfo(
      id: 'google/gemini-3.1-flash-lite',
      name: 'Gemini 3.1 Flash-Lite',
      price: r'~$0.002',
      description: 'Fast, cheap Gemini via OpenRouter',
    ),
    AIModelInfo(
      id: 'google/gemini-3.1-pro-preview',
      name: 'Gemini 3.1 Pro',
      price: r'~$0.014',
      description: 'Best Gemini reasoning via OpenRouter',
    ),
    AIModelInfo(
      id: 'google/gemini-3-flash-preview',
      name: 'Gemini 3 Flash',
      price: r'~$0.004',
      description: 'Balanced Gemini via OpenRouter',
    ),
    AIModelInfo(
      id: 'openai/gpt-5.2',
      name: 'GPT-5.2',
      price: r'~$0.008',
      description: 'Reliable, Accurate',
    ),
    AIModelInfo(
      id: 'openai/gpt-5-mini',
      name: 'GPT-5 Mini',
      price: r'~$0.003',
      description: 'Cheaper, less knowledge',
    ),
    AIModelInfo(
      id: 'anthropic/claude-sonnet-4.5',
      name: 'Claude Sonnet 4.5',
      price: r'~$0.007',
      description: 'Not very accurate',
    ),
    AIModelInfo(
      id: 'anthropic/claude-opus-4.5',
      name: 'Claude Opus 4.5',
      price: r'~$0.01',
      description: 'Not very accurate',
    ),
    AIModelInfo(
      id: 'x-ai/grok-4',
      name: 'Grok 4',
      price: '?',
      description: 'Latest model from xAI',
    ),
    AIModelInfo(
      id: 'custom',
      name: 'Custom OpenRouter model',
      price: 'Varies',
      description: 'Enter any OpenRouter model ID',
    ),
  ];
}
