import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:nutrinutri/core/domain/nutrition_metric.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/entry_action_buttons.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/entry_form.dart';

class ManualEntrySection extends StatelessWidget {
  const ManualEntrySection({
    super.key,
    required this.isEditing,
    required this.isExercise,
    required this.nameController,
    required this.metricControllers,
    this.correctionController,
    this.durationController,
    this.reasoning,
    required this.selectedIcon,
    required this.selectedDate,
    required this.selectedTime,
    required this.onBackToWizard,
    required this.onIconChanged,
    required this.onPickDate,
    required this.onPickTime,
    required this.onSave,
    this.onApplyAiCorrection,
    required this.onDeleteConfirmed,
  });
  final bool isEditing;
  final bool isExercise;
  final TextEditingController nameController;
  final Map<NutritionMetricType, TextEditingController> metricControllers;
  final TextEditingController? correctionController;
  final TextEditingController? durationController;
  final String? reasoning;
  final String selectedIcon;
  final DateTime selectedDate;
  final TimeOfDay selectedTime;
  final VoidCallback onBackToWizard;
  final ValueChanged<String?> onIconChanged;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final Future<void> Function() onSave;
  final Future<void> Function()? onApplyAiCorrection;
  final Future<void> Function() onDeleteConfirmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isEditing) ...[
          TextButton.icon(
            onPressed: onBackToWizard,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to AI Wizard'),
          ),
          const Gap(16),
        ],
        EntryForm(
          nameController: nameController,
          metricControllers: metricControllers,
          durationController: durationController,
          selectedIcon: selectedIcon,
          selectedDate: selectedDate,
          selectedTime: selectedTime,
          onIconChanged: onIconChanged,
          onPickDate: onPickDate,
          onPickTime: onPickTime,
          isExercise: isExercise,
        ),
        if (!isExercise && reasoning?.trim().isNotEmpty == true) ...[
          const Gap(16),
          Text(
            'AI reasoning',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Gap(8),
          Text(reasoning!.trim()),
        ],
        if (!isExercise &&
            isEditing &&
            correctionController != null &&
            onApplyAiCorrection != null) ...[
          const Gap(24),
          TextField(
            controller: correctionController,
            decoration: const InputDecoration(
              labelText: 'Correct with AI',
              hintText: 'e.g. Actually it was 3 rotis, not 2',
              border: OutlineInputBorder(),
            ),
            minLines: 2,
            maxLines: 4,
          ),
          const Gap(12),
          FilledButton.icon(
            onPressed: onApplyAiCorrection,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Apply AI Correction'),
          ),
        ],
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
}
