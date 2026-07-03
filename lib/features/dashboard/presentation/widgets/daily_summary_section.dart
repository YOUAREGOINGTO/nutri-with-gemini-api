import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';
import 'package:nutrinutri/core/providers.dart';
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
        return _buildContent(
          context,
          ref,
          summaryData.profile,
          summaryData.summary,
          summaryData.configuredMetrics,
          summaryData.isDailyCalculationExportIneligible,
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Text('Error: $err'),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    UserProfile profile,
    Map<String, double> summary,
    Set<NutritionMetricType> configuredMetrics,
    bool isDailyCalculationExportIneligible,
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
            _buildDailyExportEligibilitySwitch(
              ref,
              isDailyCalculationExportIneligible,
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
            ..._buildRatioRow(summary, configuredMetrics),
            ..._buildAnalyticsSection(summary, configuredMetrics),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyExportEligibilitySwitch(
    WidgetRef ref,
    bool isDailyCalculationExportIneligible,
  ) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: const Icon(Icons.table_chart_outlined),
      title: const Text('Calculation export: Not eligible'),
      value: isDailyCalculationExportIneligible,
      onChanged: (value) {
        unawaited(_setDailyCalculationExportIneligible(ref, value));
      },
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
    final visible = micronutrientMetricTypes
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

  List<Widget> _buildRatioRow(
    Map<String, double> summary,
    Set<NutritionMetricType> configuredMetrics,
  ) {
    final calciumPhosphorus = _metricRatio(
      summary,
      configuredMetrics,
      NutritionMetricType.calcium,
      NutritionMetricType.phosphorus,
    );
    final zincCopper = _metricRatio(
      summary,
      configuredMetrics,
      NutritionMetricType.zinc,
      NutritionMetricType.copper,
    );
    final potassiumSodium = _metricRatio(
      summary,
      configuredMetrics,
      NutritionMetricType.potassium,
      NutritionMetricType.sodium,
    );

    final items = [
      if (calciumPhosphorus != null)
        _RatioItem(
          label: 'Ca:P',
          value: '${_formatCompactNumber(calciumPhosphorus)}:1',
        ),
      if (zincCopper != null)
        _RatioItem(
          label: 'Zn:Cu',
          value: '${_formatCompactNumber(zincCopper)}:1',
        ),
      if (potassiumSodium != null)
        _RatioItem(
          label: 'K:Na',
          value: '${_formatCompactNumber(potassiumSodium)}:1',
        ),
    ];

    if (items.isEmpty) return [];

    return [
      const Gap(16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: items
            .map((item) => _RatioStat(label: item.label, value: item.value))
            .toList(growable: false),
      ),
    ];
  }

  List<Widget> _buildAnalyticsSection(
    Map<String, double> summary,
    Set<NutritionMetricType> configuredMetrics,
  ) {
    final items = _analyticsItems(summary, configuredMetrics);
    final statusText = items.isEmpty ? 'Not configured' : null;

    return [
      const Gap(8),
      SizedBox(
        width: double.infinity,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          leading: const Icon(Icons.insights_outlined),
          title: const Text('Analytics'),
          subtitle: statusText == null ? null : Text(statusText),
          children: [
            if (items.isEmpty)
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.tune_outlined),
                title: Text('Not configured'),
              ),
            if (items.isNotEmpty)
              ...items.map(
                (item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(item.icon),
                  title: Text(item.label),
                  trailing: Text(
                    item.value,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _setDailyCalculationExportIneligible(
    WidgetRef ref,
    bool ineligible,
  ) async {
    await ref
        .read(settingsServiceProvider)
        .setDailyCalculationExportIneligible(today, ineligible: ineligible);
    ref.invalidate(dailySummaryDataProvider(today));
  }

  List<_AnalyticsItem> _analyticsItems(
    Map<String, double> summary,
    Set<NutritionMetricType> configuredMetrics,
  ) {
    final calories = summary[NutritionMetricType.calories.key] ?? 0;
    final pufa = summary[NutritionMetricType.polyunsaturatedFat.key] ?? 0;
    final hasPufaConfigured = configuredMetrics.contains(
      NutritionMetricType.polyunsaturatedFat,
    );
    final pufaPercent = calories > 0 && pufa > 0 && hasPufaConfigured
        ? (pufa * 9 / calories) * 100
        : null;

    return [
      if (pufaPercent != null)
        _AnalyticsItem(
          label: 'PUFA % of calories',
          value: '${_formatCompactNumber(pufaPercent, maxDecimals: 1)}%',
          icon: Icons.percent,
        ),
    ];
  }

  double? _metricRatio(
    Map<String, double> summary,
    Set<NutritionMetricType> configuredMetrics,
    NutritionMetricType numerator,
    NutritionMetricType denominator,
  ) {
    if (!configuredMetrics.contains(numerator) ||
        !configuredMetrics.contains(denominator)) {
      return null;
    }
    final numeratorValue = summary[numerator.key] ?? 0;
    final denominatorValue = summary[denominator.key] ?? 0;
    if (numeratorValue <= 0 || denominatorValue <= 0) return null;
    return numeratorValue / denominatorValue;
  }

  String _formatCompactNumber(double value, {int maxDecimals = 2}) {
    var text = value.toStringAsFixed(maxDecimals);
    text = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return text;
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

class _RatioStat extends StatelessWidget {
  const _RatioStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 112,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.balance_outlined, size: 16, color: colorScheme.primary),
              const Gap(4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Gap(4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatioItem {
  const _RatioItem({required this.label, required this.value});

  final String label;
  final String value;
}

class _AnalyticsItem {
  const _AnalyticsItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;
}
