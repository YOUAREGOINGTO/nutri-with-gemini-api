import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/features/diary/application/diary_controller.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:nutrinutri/features/logging/presentation/add_entry_controller.dart';

class AddEntryFormManager {
  AddEntryFormManager({required this.ref, required this.onStateChanged}) {
    nameController.addListener(_updateCalories);
    durationController.addListener(_updateCalories);
  }
  final WidgetRef ref;
  final VoidCallback onStateChanged;

  final descriptionController = TextEditingController();
  final correctionController = TextEditingController();
  final rerunPromptController = TextEditingController();
  final nameController = TextEditingController();
  final temperatureController = TextEditingController();
  final temperatureCommentController = TextEditingController();
  final metricControllers = {
    for (final metric in NutritionMetricType.values)
      metric: TextEditingController(),
  };
  final durationController = TextEditingController();
  int _calorieRequestToken = 0;

  TextEditingController get caloriesController =>
      metricControllers[NutritionMetricType.calories]!;

  void _updateCalories() async {
    final token = ++_calorieRequestToken;
    final state = ref.read(addEntryControllerProvider);
    if (state.type != EntryType.exercise) return;

    final name = nameController.text;
    final duration = int.tryParse(durationController.text);

    if (name.isNotEmpty && duration != null && duration > 0) {
      final calories = await ref
          .read(addEntryControllerProvider.notifier)
          .calculateExerciseCalories(name, duration);
      if (token == _calorieRequestToken && calories != null) {
        caloriesController.text = calories.toString();
      }
    }
  }

  void dispose() {
    descriptionController.dispose();
    correctionController.dispose();
    rerunPromptController.dispose();
    nameController.dispose();
    temperatureController.dispose();
    temperatureCommentController.dispose();
    for (final controller in metricControllers.values) {
      controller.dispose();
    }
    durationController.dispose();
  }

  void initializeWithEntry(DiaryEntry entry) {
    ref.read(addEntryControllerProvider.notifier).initializeWithEntry(entry);
    nameController.text = entry.name;
    descriptionController.text = entry.description ?? '';
    rerunPromptController.text = entry.description?.trim().isNotEmpty == true
        ? entry.description!.trim()
        : entry.name;
    temperatureController.text = entry.temperatureValue == null
        ? ''
        : _formatMetric(entry.temperatureValue!);
    temperatureCommentController.text = entry.type == EntryType.temperature
        ? _temperatureCommentText(entry)
        : '';
    _applyMetrics(entry);
    durationController.text = entry.durationMinutes?.toString() ?? '';
    onStateChanged();
  }

  void initializeWithType(EntryType type) {
    ref.read(addEntryControllerProvider.notifier).initializeWithType(type);
    onStateChanged();
  }

  void autofill(DiaryEntry entry) {
    nameController.text = entry.name;
    _applyMetrics(entry);
    durationController.text = entry.durationMinutes?.toString() ?? '';
    if (entry.icon != null) {
      ref.read(addEntryControllerProvider.notifier).updateIcon(entry.icon!);
    }
  }

  void _applyMetrics(DiaryEntry entry) {
    for (final metric in NutritionMetricType.values) {
      final value = entry.metricValue(metric);
      metricControllers[metric]!.text =
          (metric == NutritionMetricType.calories || value > 0)
          ? _formatMetric(value)
          : '';
    }
  }

  Future<void> addOptimistic() async {
    final state = ref.read(addEntryControllerProvider);
    if (descriptionController.text.isEmpty && state.images.isEmpty) {
      throw Exception('Please provide text or an image.');
    }

    await ref
        .read(addEntryControllerProvider.notifier)
        .addOptimistic(description: descriptionController.text);
  }

  Future<void> saveEntry(
    DiaryEntry? existingEntry, {
    bool? markedForAiReview,
  }) async {
    final state = ref.read(addEntryControllerProvider);
    if (state.type == EntryType.temperature) {
      await ref
          .read(addEntryControllerProvider.notifier)
          .saveTemperatureEntry(
            existingEntry: existingEntry,
            temperatureText: temperatureController.text,
            commentText: temperatureCommentController.text,
          );
      return;
    }

    await ref
        .read(addEntryControllerProvider.notifier)
        .saveEntry(
          existingEntry: existingEntry,
          name: nameController.text,
          metricValues: {
            for (final entry in metricControllers.entries)
              entry.key: entry.value.text,
          },
          durationMinutes: durationController.text,
          markedForAiReview: markedForAiReview,
        );
  }

  Future<void> rerunAiAnalysis(DiaryEntry existingEntry) async {
    await ref
        .read(diaryControllerProvider.notifier)
        .rerunFoodAnalysis(
          entry: existingEntry,
          description: rerunPromptController.text,
        );
  }

  Future<void> applyAiCorrection(DiaryEntry existingEntry) async {
    await ref
        .read(diaryControllerProvider.notifier)
        .correctFoodEntry(
          entry: existingEntry,
          correctionMessage: correctionController.text,
        );
  }

  Future<void> deleteEntry(DiaryEntry entry) async {
    await ref.read(addEntryControllerProvider.notifier).deleteEntry(entry);
  }

  String _formatMetric(double value) {
    if (value == value.roundToDouble()) {
      return value.round().toString();
    }
    return value.toStringAsFixed(1);
  }

  String _temperatureCommentText(DiaryEntry entry) {
    final description = entry.description?.trim();
    if (description == null || description.isEmpty) return '';

    final siteLabel = entry.temperatureSiteLabel.trim().toLowerCase();
    if (description.toLowerCase() == siteLabel) return '';
    if (description.toLowerCase().startsWith('under tongue - ')) return '';

    return description;
  }
}
