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
    this.rerunPromptController,
    this.durationController,
    this.reasoning,
    this.aiRequestLabel,
    this.isApplyingAiCorrection = false,
    this.isRerunningAi = false,
    required this.selectedIcon,
    required this.selectedDate,
    required this.selectedTime,
    required this.onBackToWizard,
    required this.onIconChanged,
    required this.onPickDate,
    required this.onPickTime,
    required this.onSave,
    this.onApplyAiCorrection,
    this.onRerunAi,
    required this.onDeleteConfirmed,
  });
  final bool isEditing;
  final bool isExercise;
  final TextEditingController nameController;
  final Map<NutritionMetricType, TextEditingController> metricControllers;
  final TextEditingController? correctionController;
  final TextEditingController? rerunPromptController;
  final TextEditingController? durationController;
  final String? reasoning;
  final String? aiRequestLabel;
  final bool isApplyingAiCorrection;
  final bool isRerunningAi;
  final String selectedIcon;
  final DateTime selectedDate;
  final TimeOfDay selectedTime;
  final VoidCallback onBackToWizard;
  final ValueChanged<String?> onIconChanged;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final Future<void> Function() onSave;
  final Future<void> Function()? onApplyAiCorrection;
  final Future<void> Function()? onRerunAi;
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
          if (aiRequestLabel?.trim().isNotEmpty == true) ...[
            const Gap(8),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 16),
                const Gap(6),
                Expanded(
                  child: Text(
                    aiRequestLabel!.trim(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
        if (!isExercise &&
            isEditing &&
            rerunPromptController != null &&
            onRerunAi != null) ...[
          const Gap(24),
          TextField(
            controller: rerunPromptController,
            decoration: const InputDecoration(
              labelText: 'Prompt to run again',
              hintText: 'e.g. 2 eggs and toast',
              border: OutlineInputBorder(),
            ),
            minLines: 2,
            maxLines: 4,
          ),
          const Gap(12),
          FilledButton.icon(
            onPressed: isRerunningAi ? null : onRerunAi,
            icon: isRerunningAi
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(
              isRerunningAi ? 'Running again...' : 'Run Again',
            ),
          ),
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
            onPressed: isApplyingAiCorrection ? null : onApplyAiCorrection,
            icon: isApplyingAiCorrection
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high),
            label: Text(
              isApplyingAiCorrection
                  ? 'Updating with AI...'
                  : 'Apply AI Correction',
            ),
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
