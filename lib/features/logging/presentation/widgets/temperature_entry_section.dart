import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/entry_action_buttons.dart';

class TemperatureEntrySection extends StatelessWidget {
  const TemperatureEntrySection({
    super.key,
    required this.isEditing,
    required this.temperatureController,
    required this.selectedUnit,
    required this.selectedSite,
    required this.selectedDate,
    required this.selectedTime,
    required this.onUnitChanged,
    required this.onSiteChanged,
    required this.onPickDate,
    required this.onPickTime,
    required this.onSave,
    required this.onDeleteConfirmed,
  });

  final bool isEditing;
  final TextEditingController temperatureController;
  final String selectedUnit;
  final String selectedSite;
  final DateTime selectedDate;
  final TimeOfDay selectedTime;
  final ValueChanged<String> onUnitChanged;
  final ValueChanged<String> onSiteChanged;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final Future<void> Function() onSave;
  final Future<void> Function() onDeleteConfirmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    foregroundColor: colorScheme.onPrimaryContainer,
                    child: const Icon(Icons.thermostat),
                  ),
                  const Gap(12),
                  Expanded(
                    child: Text(
                      'Temperature',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const Gap(20),
              TextField(
                controller: temperatureController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Reading',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.device_thermostat),
                ),
              ),
              const Gap(16),
              _FieldLabel(text: 'Unit'),
              const Gap(8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'C', label: Text('C')),
                  ButtonSegment(value: 'F', label: Text('F')),
                ],
                selected: {selectedUnit.toUpperCase() == 'F' ? 'F' : 'C'},
                onSelectionChanged: (selection) {
                  onUnitChanged(selection.first);
                },
              ),
              const Gap(16),
              _FieldLabel(text: 'Position'),
              const Gap(8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'under_tongue',
                    label: Text('Under tongue'),
                  ),
                  ButtonSegment(
                    value: 'left_hand',
                    label: Text('Left hand'),
                  ),
                  ButtonSegment(
                    value: 'right_hand',
                    label: Text('Right hand'),
                  ),
                ],
                selected: {_normalizedSite(selectedSite)},
                onSelectionChanged: (selection) {
                  onSiteChanged(selection.first);
                },
              ),
              const Gap(16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPickDate,
                      icon: const Icon(Icons.calendar_today),
                      label: Text(DateFormat('yyyy-MM-dd').format(selectedDate)),
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPickTime,
                      icon: const Icon(Icons.access_time),
                      label: Text(selectedTime.format(context)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Gap(24),
        EntryActionButtons(
          isEditing: isEditing,
          onSave: onSave,
          onDeleteConfirmed: onDeleteConfirmed,
        ),
        const Gap(32),
      ],
    );
  }

  String _normalizedSite(String value) {
    final site = value
        .trim()
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

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
