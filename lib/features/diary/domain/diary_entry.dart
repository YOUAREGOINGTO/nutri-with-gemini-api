import 'package:nutrinutri/core/domain/nutrition_metric.dart';

class DiaryEntry {
  DiaryEntry({
    required this.id,
    required this.name,
    this.type = EntryType.food,
    Map<NutritionMetricType, double>? metrics,
    required this.timestamp,
    String? imagePath,
    List<String>? imagePaths,
    this.icon,
    this.status = FoodEntryStatus.synced,
    this.description,
    this.reasoning,
    this.durationMinutes,
  }) : imagePaths = List.unmodifiable(_normalizeImagePaths(
         imagePath,
         imagePaths,
       )),
       imagePath = imagePath ?? _firstImagePath(imagePaths),
       metrics = Map.unmodifiable(metrics ?? const {});

  final String id;
  final String name;
  final EntryType type;
  final Map<NutritionMetricType, double> metrics;
  final DateTime timestamp;
  final String? imagePath;
  final List<String> imagePaths;
  final String? icon;
  final FoodEntryStatus status;
  final String? description;
  final String? reasoning;
  final int? durationMinutes;

  double metricValue(NutritionMetricType type) {
    return metrics[type] ?? 0;
  }

  double get calories => metricValue(NutritionMetricType.calories);
  double get protein => metricValue(NutritionMetricType.protein);
  double get carbs => metricValue(NutritionMetricType.carbs);
  double get fats => metricValue(NutritionMetricType.fats);
}

enum EntryType { food, exercise }

enum FoodEntryStatus { synced, processing, failed, cancelled }

class DiaryEntryImage {
  const DiaryEntryImage({
    required this.id,
    required this.entryId,
    required this.localPath,
    this.originalName,
    this.mimeType,
    required this.createdAt,
  });

  final String id;
  final String entryId;
  final String localPath;
  final String? originalName;
  final String? mimeType;
  final DateTime createdAt;
}

class AiChatMessage {
  const AiChatMessage({
    required this.id,
    required this.entryId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.metadataJson,
  });

  final String id;
  final String entryId;
  final String role;
  final String content;
  final DateTime createdAt;
  final String? metadataJson;
}

List<String> _normalizeImagePaths(String? imagePath, List<String>? imagePaths) {
  final seen = <String>{};
  final normalized = <String>[];

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

String? _firstImagePath(List<String>? imagePaths) {
  if (imagePaths == null || imagePaths.isEmpty) return null;
  final first = imagePaths.first.trim();
  return first.isEmpty ? null : first;
}
