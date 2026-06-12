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
    this.aiPrompt,
    this.aiResult,
    this.isApplyingAiCorrection = false,
    this.isRerunningAi = false,
    this.markedForAiReview = false,
    this.isUpdatingAiReviewMark = false,
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
    this.onAiReviewMarkChanged,
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
  final String? aiPrompt;
  final String? aiResult;
  final bool isApplyingAiCorrection;
  final bool isRerunningAi;
  final bool markedForAiReview;
  final bool isUpdatingAiReviewMark;
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
  final ValueChanged<bool>? onAiReviewMarkChanged;
  final Future<void> Function() onDeleteConfirmed;

  bool get _hasAiDebugDetails =>
      aiRequestLabel?.trim().isNotEmpty == true ||
      aiPrompt?.trim().isNotEmpty == true ||
      aiResult?.trim().isNotEmpty == true;

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
        if (!isExercise && isEditing && _hasAiDebugDetails) ...[
          const Gap(16),
          _AiDebugDetailsTile(
            requestLabel: aiRequestLabel,
            prompt: aiPrompt,
            result: aiResult,
          ),
        ],
        if (!isExercise && isEditing && onAiReviewMarkChanged != null) ...[
          const Gap(16),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SwitchListTile(
              value: markedForAiReview,
              onChanged: isUpdatingAiReviewMark
                  ? null
                  : onAiReviewMarkChanged,
              secondary: isUpdatingAiReviewMark
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              title: const Text('Mark for Review'),
              subtitle: const Text(
                'Include prompt, images, and AI history in ZIP backup',
              ),
            ),
          ),
        ],
        if (!isExercise &&
            isEditing &&
            rerunPromptController != null &&
            onRerunAi != null) ...[
          const Gap(24),
          TextField(
            controller: rerunPromptController,
            decoration: const InputDecoration(
              labelText: 'Prompt',
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
            label: const Text('Run Again'),
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

class _AiDebugDetailsTile extends StatelessWidget {
  const _AiDebugDetailsTile({
    required this.requestLabel,
    required this.prompt,
    required this.result,
  });

  final String? requestLabel;
  final String? prompt;
  final String? result;

  @override
  Widget build(BuildContext context) {
    final normalizedLabel = requestLabel?.trim();
    final normalizedPrompt = prompt?.trim();
    final normalizedResult = result?.trim();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.manage_search_outlined),
        title: const Text('AI prompt/result used'),
        subtitle: normalizedLabel?.isNotEmpty == true
            ? Text(normalizedLabel!)
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (normalizedPrompt?.isNotEmpty == true)
            _AiDebugTextBlock(title: 'Prompt', text: normalizedPrompt!),
          if (normalizedPrompt?.isNotEmpty == true &&
              normalizedResult?.isNotEmpty == true)
            const Gap(12),
          if (normalizedResult?.isNotEmpty == true)
            _AiDebugTextBlock(title: 'Result', text: normalizedResult!),
        ],
      ),
    );
  }
}

class _AiDebugTextBlock extends StatelessWidget {
  const _AiDebugTextBlock({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        const Gap(6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.45,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
