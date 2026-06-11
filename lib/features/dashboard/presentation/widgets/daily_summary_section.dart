import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/features/dashboard/presentation/dashboard_providers.dart';
import 'package:nutrinutri/features/dashboard/presentation/widgets/metric_ring.dart';

class DailySummarySection extends ConsumerWidget {
  const DailySummarySection({super.key, required this.today});
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryDataAsync = ref.watch(dailySummaryDataProvider(today));

    return summaryDataAsync.when(
      data: (summaryData) {
        if (summaryData == null) return const Text('Profile not found');
        return _buildContent(context, summaryData.profile, summaryData.summary);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Text('Error: $err'),
    );
  }

  Widget _buildContent(
    BuildContext context,
    UserProfile profile,
    Map<String, double> summary,
  ) {
    final consumed = summary[NutritionMetricType.calories.key] ?? 0;
    final burned = summary['caloriesBurned'] ?? 0.0;
    final goal = profile.goalFor(NutritionMetricType.calories);
    final effectiveGoal = goal + burned;
    final remaining = effectiveGoal - consumed;
    final isOver = remaining < 0;

    final progress = effectiveGoal <= 0
        ? 0.0
        : (consumed / effectiveGoal).clamp(0.0, 1.0);

    final statusColor = isOver ? Colors.redAccent : Colors.green;
    final secondaryColor = isOver
        ? Colors.red.withValues(alpha: 0.1)
        : Colors.grey[200]!;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Calories Today',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Goal: ${effectiveGoal.round()} kcal',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                    if (burned > 0)
                      Text(
                        '(+${burned.round()} burned)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.orange,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const Gap(16),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  MetricRing(
                    label: NutritionMetricType.caffeine.label,
                    value: summary[NutritionMetricType.caffeine.key] ?? 0,
                    goal: profile.goalFor(NutritionMetricType.caffeine),
                    unit: NutritionMetricType.caffeine.unit,
                    color: _metricColor(NutritionMetricType.caffeine),
                  ),
                  SizedBox(
                    height: 150,
                    width: 150,
                    child: Stack(
                      children: [
                        PieChart(
                          PieChartData(
                            sections: [
                              PieChartSectionData(
                                value: progress,
                                color: statusColor,
                                radius: 20,
                                showTitle: false,
                              ),
                              PieChartSectionData(
                                value: 1 - progress,
                                color: secondaryColor,
                                radius: 20,
                                showTitle: false,
                              ),
                            ],
                            startDegreeOffset: 270,
                          ),
                        ),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isOver
                                    ? remaining.abs().round().toString()
                                    : remaining.round().toString(),
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: isOver
                                      ? Colors.redAccent
                                      : Theme.of(
                                          context,
                                        ).textTheme.headlineMedium?.color,
                                ),
                              ),
                              Text(
                                isOver ? 'Over' : 'Left',
                                style: TextStyle(
                                  color: isOver
                                      ? Colors.redAccent
                                      : Colors.grey,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  MetricRing(
                    label: NutritionMetricType.water.label,
                    value: summary[NutritionMetricType.water.key] ?? 0,
                    goal: profile.goalFor(NutritionMetricType.water),
                    unit: NutritionMetricType.water.unit,
                    color: _metricColor(NutritionMetricType.water),
                  ),
                ],
              ),
            ),
            const Gap(24),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              alignment: WrapAlignment.center,
              children: _buildMacroRings(profile, summary),
            ),
            ..._buildMicroRow(profile, summary),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildMacroRings(
    UserProfile profile,
    Map<String, double> summary,
  ) {
    final metrics = profile.dashboardMetricTypes
        .where(
          (m) =>
              m != NutritionMetricType.caffeine &&
              m != NutritionMetricType.water,
        )
        .toList();

    return metrics.map((metric) {
      if (metric == NutritionMetricType.carbs) {
        return MetricRing(
          label: metric.label,
          value: summary[metric.key] ?? 0,
          goal: profile.goalFor(metric),
          unit: metric.unit,
          color: _metricColor(metric),
          subLabel: NutritionMetricType.sugars.label,
          subValue: summary[NutritionMetricType.sugars.key] ?? 0,
          subGoal: profile.goalFor(NutritionMetricType.sugars),
          subColor: _metricColor(NutritionMetricType.sugars),
        );
      }
      if (metric == NutritionMetricType.fats) {
        return MetricRing(
          label: metric.label,
          value: summary[metric.key] ?? 0,
          goal: profile.goalFor(metric),
          unit: metric.unit,
          color: _metricColor(metric),
          subLabel: 'Sat. Fats',
          subValue: summary[NutritionMetricType.saturatedFats.key] ?? 0,
          subGoal: profile.goalFor(NutritionMetricType.saturatedFats),
          subColor: _metricColor(NutritionMetricType.saturatedFats),
        );
      }
      return MetricRing(
        label: metric.label,
        value: summary[metric.key] ?? 0,
        goal: profile.goalFor(metric),
        unit: metric.unit,
        color: _metricColor(metric),
      );
    }).toList();
  }

  List<Widget> _buildMicroRow(
    UserProfile profile,
    Map<String, double> summary,
  ) {
    const microMetrics = [
      NutritionMetricType.polyunsaturatedFat,
      NutritionMetricType.calcium,
      NutritionMetricType.magnesium,
      NutritionMetricType.potassium,
      NutritionMetricType.iron,
      NutritionMetricType.zinc,
      NutritionMetricType.copper,
      NutritionMetricType.vitaminA,
      NutritionMetricType.phosphorus,
    ];

    final visible = microMetrics
        .where((m) => (summary[m.key] ?? 0) > 0)
        .toList();

    if (visible.isEmpty) return [];

    return [
      const Gap(16),
      Wrap(
        spacing: 16,
        runSpacing: 16,
        alignment: WrapAlignment.center,
        children: visible
            .map(
              (metric) => MetricRing(
                label: metric.label,
                value: summary[metric.key] ?? 0,
                goal: profile.goalFor(metric),
                unit: metric.unit,
                color: _metricColor(metric),
              ),
            )
            .toList(),
      ),
    ];
  }

  Color _metricColor(NutritionMetricType metric) {
    switch (metric) {
      case NutritionMetricType.protein:
        return Colors.blue;
      case NutritionMetricType.carbs:
        return Colors.amber;
      case NutritionMetricType.sugars:
        return Colors.orange;
      case NutritionMetricType.fats:
        return Colors.redAccent;
      case NutritionMetricType.saturatedFats:
        return Colors.red;
      case NutritionMetricType.fiber:
        return Colors.green;
      case NutritionMetricType.sodium:
        return Colors.teal;
      case NutritionMetricType.caffeine:
        return Colors.brown;
      case NutritionMetricType.water:
        return Colors.lightBlue;
      case NutritionMetricType.polyunsaturatedFat:
        return Colors.pinkAccent;
      case NutritionMetricType.calcium:
      case NutritionMetricType.phosphorus:
      case NutritionMetricType.magnesium:
      case NutritionMetricType.potassium:
        return Colors.indigo;
      case NutritionMetricType.iron:
      case NutritionMetricType.zinc:
      case NutritionMetricType.copper:
        return Colors.deepPurple;
      case NutritionMetricType.vitaminA:
        return Colors.cyan;
      case NutritionMetricType.calories:
        return Colors.deepOrange;
    }
  }
}
