import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:nutrinutri/features/dashboard/presentation/dashboard_providers.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';

class TemperatureTimelineSection extends ConsumerWidget {
  const TemperatureTimelineSection({super.key, required this.today});

  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(dayEntriesProvider(today));

    return entriesAsync.when(
      data: (entries) {
        final readings = entries
            .where(
              (entry) =>
                  entry.type == EntryType.temperature &&
                  entry.temperatureCelsius != null,
            )
            .toList(growable: false);
        return _TemperatureCard(readings: readings);
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (err, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Error loading temperature: $err'),
        ),
      ),
    );
  }
}

class _TemperatureCard extends StatelessWidget {
  const _TemperatureCard({required this.readings});

  final List<DiaryEntry> readings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final latest = readings.isEmpty ? null : readings.last;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colorScheme.tertiaryContainer,
                  foregroundColor: colorScheme.onTertiaryContainer,
                  child: const Icon(Icons.thermostat),
                ),
                const Gap(12),
                Expanded(
                  child: Text(
                    'Temperature',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (latest != null)
                  Text(
                    latest.temperatureDisplay,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
            const Gap(12),
            if (readings.isEmpty)
              Text(
                'No temperature logged for this date.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              Text(
                '${readings.length} reading${readings.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Gap(14),
              SizedBox(
                height: 150,
                child: _TemperatureChart(readings: readings),
              ),
              const Gap(14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: readings.reversed
                    .take(6)
                    .map((entry) => _ReadingChip(entry: entry))
                    .toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TemperatureChart extends StatelessWidget {
  const _TemperatureChart({required this.readings});

  final List<DiaryEntry> readings;

  @override
  Widget build(BuildContext context) {
    final values = readings
        .map((entry) => entry.temperatureCelsius)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) return const SizedBox.shrink();

    final spots = <FlSpot>[];
    for (final entry in readings) {
      final value = entry.temperatureCelsius;
      if (value == null) continue;
      final minute = entry.timestamp.hour * 60 + entry.timestamp.minute;
      spots.add(FlSpot(minute.toDouble(), value));
    }

    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final minY = minValue - 0.7;
    final maxY = maxValue + 0.7;
    final colorScheme = Theme.of(context).colorScheme;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: 24 * 60,
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 360,
              reservedSize: 26,
              getTitlesWidget: (value, meta) {
                final hour = (value ~/ 60).clamp(0, 24);
                if (hour == 24) return const SizedBox.shrink();
                return Text(
                  hour.toString().padLeft(2, '0'),
                  style: Theme.of(context).textTheme.labelSmall,
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(1),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: spots.length > 1,
            color: colorScheme.primary,
            barWidth: 3,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: colorScheme.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadingChip extends StatelessWidget {
  const _ReadingChip({required this.entry});

  final DiaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${DateFormat('HH:mm').format(entry.timestamp)}  ${entry.temperatureDisplay}  ${entry.temperatureSiteLabel}',
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
