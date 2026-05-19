import 'dart:io';
import 'package:flutter/material.dart';

import 'package:image_picker/image_picker.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/core/utils/met_values.dart';
import 'package:nutrinutri/features/diary/application/diary_controller.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'add_entry_controller.g.dart';

class AddEntryState {
  AddEntryState({
    List<File>? images,
    this.showForm = false,
    required this.selectedDate,
    required this.selectedTime,
    this.selectedIcon = 'restaurant',
    this.type = EntryType.food,
    this.temperatureUnit = 'C',
    this.temperatureSite = 'under_tongue',
  }) : images = List.unmodifiable(images ?? const []);
  final List<File> images;
  final bool showForm;
  final DateTime selectedDate;
  final TimeOfDay selectedTime;
  final String selectedIcon;
  final EntryType type;
  final String temperatureUnit;
  final String temperatureSite;
  File? get image => images.isEmpty ? null : images.first;

  AddEntryState copyWith({
    List<File>? images,
    bool? showForm,
    DateTime? selectedDate,
    TimeOfDay? selectedTime,
    String? selectedIcon,
    EntryType? type,
    String? temperatureUnit,
    String? temperatureSite,
  }) {
    return AddEntryState(
      images: images ?? this.images,
      showForm: showForm ?? this.showForm,
      selectedDate: selectedDate ?? this.selectedDate,
      selectedTime: selectedTime ?? this.selectedTime,
      selectedIcon: selectedIcon ?? this.selectedIcon,
      type: type ?? this.type,
      temperatureUnit: temperatureUnit ?? this.temperatureUnit,
      temperatureSite: temperatureSite ?? this.temperatureSite,
    );
  }
}

@riverpod
class AddEntryController extends _$AddEntryController {
  final _picker = ImagePicker();
  static const _uuid = Uuid();

  @override
  AddEntryState build() {
    final now = DateTime.now();
    return AddEntryState(
      selectedDate: DateTime(now.year, now.month, now.day),
      selectedTime: TimeOfDay.now(),
      type: EntryType.food,
    );
  }

  void initializeWithType(EntryType type) {
    state = state.copyWith(
      type: type,
      selectedIcon: _defaultIconForType(type),
      showForm: type == EntryType.temperature ? true : state.showForm,
    );
  }

  void initializeWithEntry(DiaryEntry entry) {
    state = state.copyWith(
      images: entry.imagePaths.map(File.new).toList(growable: false),
      showForm: true,
      selectedDate: entry.timestamp,
      selectedTime: TimeOfDay.fromDateTime(entry.timestamp),
      selectedIcon: entry.icon ?? _defaultIconForType(entry.type),
      type: entry.type,
      temperatureUnit: entry.temperatureUnit ?? 'C',
      temperatureSite: _normalizeTemperatureSite(entry.temperatureSite),
    );
  }

  Future<File?> pickImage(ImageSource source) async {
    if (source == ImageSource.gallery) {
      final pickedFiles = await _picker.pickMultiImage(
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (pickedFiles.isEmpty) return null;
      final newImages = <File>[];
      for (final file in pickedFiles) {
        newImages.add(await _persistPickedImage(file));
      }
      state = state.copyWith(images: [...state.images, ...newImages]);
      return newImages.first;
    }

    final pickedFile = await _picker.pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (pickedFile != null) {
      final image = await _persistPickedImage(pickedFile);
      state = state.copyWith(images: [...state.images, image]);
      return image;
    }
    return null;
  }

  Future<File> _persistPickedImage(XFile pickedFile) async {
    final sourceFile = File(pickedFile.path);
    try {
      final appDirectory = await getApplicationDocumentsDirectory();
      final imageDirectory = Directory(
        p.join(appDirectory.path, 'entry_images', 'pending'),
      );
      await imageDirectory.create(recursive: true);
      final extension = p.extension(pickedFile.path).isEmpty
          ? '.jpg'
          : p.extension(pickedFile.path);
      final targetFile = File(
        p.join(imageDirectory.path, '${_uuid.v4()}$extension'),
      );
      return sourceFile.copy(targetFile.path);
    } catch (_) {
      return sourceFile;
    }
  }

  void removeImageAt(int index) {
    if (index < 0 || index >= state.images.length) return;
    final nextImages = [...state.images]..removeAt(index);
    state = state.copyWith(images: nextImages);
  }

  void updateDate(DateTime date) {
    state = state.copyWith(selectedDate: date);
  }

  void updateTime(TimeOfDay time) {
    state = state.copyWith(selectedTime: time);
  }

  void updateIcon(String icon) {
    state = state.copyWith(selectedIcon: icon);
  }

  void updateTemperatureUnit(String unit) {
    state = state.copyWith(temperatureUnit: unit);
  }

  void updateTemperatureSite(String site) {
    state = state.copyWith(temperatureSite: site);
  }

  void toggleForm(bool show) {
    state = state.copyWith(showForm: show);
  }

  Future<void> addOptimistic({required String? description}) async {
    await ref
        .read(diaryControllerProvider.notifier)
        .addOptimisticEntry(
          date: state.selectedDate,
          time: state.selectedTime,
          description: description?.isNotEmpty == true ? description : null,
          imagePaths: state.images.map((image) => image.path).toList(),
          type: state.type,
        );
  }

  Future<void> saveEntry({
    required DiaryEntry? existingEntry,
    required String name,
    required Map<NutritionMetricType, String> metricValues,
    String? durationMinutes,
  }) async {
    final diaryService = ref.read(diaryServiceProvider);

    final finalName = name.trim().isEmpty
        ? (state.type == EntryType.exercise
              ? 'Unknown Exercise'
              : 'Unknown Food')
        : name.trim();
    final parsedMetrics = <NutritionMetricType, double>{};
    for (final entry in metricValues.entries) {
      final parsed = _parseMetric(entry.value);
      if (parsed == null || parsed <= 0) continue;
      parsedMetrics[entry.key] = parsed;
    }

    final calories = parsedMetrics[NutritionMetricType.calories] ?? 0;
    final finalMetrics = state.type == EntryType.exercise
        ? {NutritionMetricType.calories: calories}
        : {...parsedMetrics, NutritionMetricType.calories: calories};

    final finalDuration = durationMinutes != null
        ? int.tryParse(durationMinutes)
        : null;

    final timestamp = DateTime(
      state.selectedDate.year,
      state.selectedDate.month,
      state.selectedDate.day,
      state.selectedTime.hour,
      state.selectedTime.minute,
    );

    if (existingEntry != null) {
      final updatedEntry = DiaryEntry(
        id: existingEntry.id,
        name: finalName,
        type: state.type,
        metrics: finalMetrics,
        timestamp: timestamp,
        imagePaths: state.images.isNotEmpty
            ? state.images.map((image) => image.path).toList()
            : existingEntry.imagePaths,
        icon: state.selectedIcon,
        status: existingEntry.status,
        description: existingEntry.description,
        reasoning: existingEntry.reasoning,
        durationMinutes: finalDuration,
      );
      await diaryService.updateEntry(updatedEntry);
    } else {
      final entry = DiaryEntry(
        id: const Uuid().v4(),
        name: finalName,
        type: state.type,
        metrics: finalMetrics,
        timestamp: timestamp,
        imagePaths: state.images.map((image) => image.path).toList(),
        icon: state.selectedIcon,
        durationMinutes: finalDuration,
      );
      await diaryService.addEntry(entry);
    }
  }

  Future<void> saveTemperatureEntry({
    required DiaryEntry? existingEntry,
    required String temperatureText,
    String? commentText,
  }) async {
    final diaryService = ref.read(diaryServiceProvider);
    final value = _parseMetric(temperatureText);
    if (value == null || value <= 0) {
      throw Exception('Please enter a temperature.');
    }

    final unit = state.temperatureUnit.trim().toUpperCase() == 'F' ? 'F' : 'C';
    final site = _normalizeTemperatureSite(state.temperatureSite);
    final timestamp = DateTime(
      state.selectedDate.year,
      state.selectedDate.month,
      state.selectedDate.day,
      state.selectedTime.hour,
      state.selectedTime.minute,
    );
    final rounded = (value * 10).roundToDouble() / 10;
    final displayValue = rounded == rounded.roundToDouble()
        ? rounded.round().toString()
        : rounded.toStringAsFixed(1);
    final comment = commentText?.trim();
    final entry = DiaryEntry(
      id: existingEntry?.id ?? const Uuid().v4(),
      name: 'Temperature $displayValue $unit',
      type: EntryType.temperature,
      metrics: const {},
      timestamp: timestamp,
      icon: 'thermostat',
      status: FoodEntryStatus.synced,
      description: comment?.isEmpty == false ? comment : null,
      temperatureValue: rounded,
      temperatureUnit: unit,
      temperatureSite: site,
    );

    if (existingEntry != null) {
      await diaryService.updateEntry(entry);
    } else {
      await diaryService.addEntry(entry);
    }
  }

  Future<void> deleteEntry(DiaryEntry entry) async {
    await ref.read(diaryServiceProvider).deleteEntry(entry);
  }

  Future<int?> calculateExerciseCalories(
    String name,
    int durationMinutes,
  ) async {
    if (durationMinutes <= 0) return null;

    final settingsService = ref.read(settingsServiceProvider);
    final profile = await settingsService.getUserProfile();
    final weight = profile?.weightKg ?? 70.0;

    final met = MetValues.getMet(name);
    if (met == 0) return null;

    // Calories = MET * Weight(kg) * Duration(hr)
    final calories = (met * weight * (durationMinutes / 60)).round();
    return calories;
  }

  Future<List<DiaryEntry>> searchFood(String query) async {
    return ref
        .read(diaryServiceProvider)
        .searchEntrySuggestions(query, type: state.type);
  }

  double? _parseMetric(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  String _defaultIconForType(EntryType type) {
    return switch (type) {
      EntryType.exercise => 'directions_run',
      EntryType.temperature => 'thermostat',
      EntryType.food => 'restaurant',
    };
  }

  String _normalizeTemperatureSite(String? value) {
    final site = value
        ?.trim()
        .toLowerCase()
        .replaceAll(' ', '_')
        .replaceAll('-', '_');
    return switch (site) {
      'left' || 'left_hand' => 'left_hand',
      'right' || 'right_hand' => 'right_hand',
      _ => 'under_tongue',
    };
  }
}
