import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'dashboard_providers.g.dart';

class DailySummaryData {
  const DailySummaryData({
    required this.profile,
    required this.summary,
    required this.configuredMetrics,
    required this.isDailyCalculationExportIneligible,
  });

  final UserProfile profile;
  final Map<String, double> summary;
  final Set<NutritionMetricType> configuredMetrics;
  final bool isDailyCalculationExportIneligible;
}

@riverpod
Stream<void> syncUpdate(Ref ref) {
  return ref.watch(syncServiceProvider).onSyncCompleted;
}

@riverpod
Future<Map<String, double>> dailySummary(Ref ref, DateTime date) async {
  ref.watch(syncUpdateProvider);
  final diaryService = ref.watch(diaryServiceProvider);
  return diaryService.getSummary(date);
}

@riverpod
Future<DailySummaryData?> dailySummaryData(Ref ref, DateTime date) async {
  ref.watch(syncUpdateProvider);
  final diaryService = ref.watch(diaryServiceProvider);
  final profileFuture = ref.watch(userProfileProvider.future);
  final summaryFuture = ref.watch(dailySummaryProvider(date).future);
  final configuredMetricsFuture = diaryService.getConfiguredMetricsForDate(
    date,
  );
  final calculationExportIneligibleFuture = ref
      .watch(settingsServiceProvider)
      .isDailyCalculationExportIneligible(date);

  final profile = await profileFuture;
  if (profile == null) return null;

  final summary = await summaryFuture;
  final configuredMetrics = await configuredMetricsFuture;
  final isDailyCalculationExportIneligible =
      await calculationExportIneligibleFuture;
  return DailySummaryData(
    profile: profile,
    summary: summary,
    configuredMetrics: configuredMetrics,
    isDailyCalculationExportIneligible:
        isDailyCalculationExportIneligible,
  );
}

@riverpod
Future<List<DiaryEntry>> dayEntries(Ref ref, DateTime date) async {
  ref.watch(syncUpdateProvider);
  final diaryService = ref.watch(diaryServiceProvider);
  return diaryService.getEntriesForDate(date);
}
