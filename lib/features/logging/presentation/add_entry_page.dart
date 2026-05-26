import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/core/widgets/responsive_center.dart';
import 'package:nutrinutri/features/diary/application/diary_controller.dart';
import 'package:nutrinutri/features/diary/domain/diary_entry.dart';
import 'package:nutrinutri/features/logging/presentation/add_entry_controller.dart';
import 'package:nutrinutri/features/logging/presentation/managers/add_entry_form_manager.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/ai_entry_wizard.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/manual_entry_section.dart';
import 'package:nutrinutri/features/logging/presentation/widgets/temperature_entry_section.dart';

class AddEntryPage extends ConsumerStatefulWidget {
  const AddEntryPage({
    super.key,
    this.existingEntry,
    this.initialType = EntryType.food,
  });
  final DiaryEntry? existingEntry;
  final EntryType initialType;

  @override
  ConsumerState<AddEntryPage> createState() => _AddEntryPageState();
}

class _AddEntryPageState extends ConsumerState<AddEntryPage> {
  late final AddEntryFormManager _formManager;
  bool _isApplyingAiCorrection = false;
  bool _isRerunningAi = false;
  bool _isUpdatingAiReviewMark = false;
  bool _markedForAiReview = false;
  String? _aiRequestLabel;

  @override
  void initState() {
    super.initState();
    _formManager = AddEntryFormManager(
      ref: ref,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );

    if (widget.existingEntry != null) {
      _markedForAiReview = widget.existingEntry!.markedForAiReview;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _formManager.initializeWithEntry(widget.existingEntry!);
        unawaited(_loadAiRequestLabel(widget.existingEntry!.id));
      });
    } else {
      // Initialize with type
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _formManager.initializeWithType(widget.initialType);
      });
    }
  }

  @override
  void dispose() {
    _formManager.dispose();
    super.dispose();
  }

  bool get _canUseCamera {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _addOptimistic() async {
    try {
      await _formManager.addOptimistic();
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        // If it's a validation error (empty input), just show message
        if (e.toString().contains('Please provide text')) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toString())));
          return;
        }

        // API Key or other errors
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().contains('API Key')
                  ? 'Please set your API Key in Settings'
                  : 'Failed to add entry: $e',
            ),
            action: e.toString().contains('API Key')
                ? SnackBarAction(
                    label: 'Settings',
                    onPressed: () => context.go('/settings'),
                  )
                : null,
          ),
        );
      }
    }
  }

  Future<void> _saveEntry() async {
    try {
      await _formManager.saveEntry(
        widget.existingEntry,
        markedForAiReview: _markedForAiReview,
      );
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  Future<void> _loadAiRequestLabel(String entryId) async {
    final chats = await ref.read(diaryServiceProvider).getChatMessages(entryId);
    String? label;
    for (final chat in chats.reversed) {
      final rawMetadata = chat.metadataJson;
      if (chat.role != 'assistant' || rawMetadata == null) continue;

      try {
        final metadata = jsonDecode(rawMetadata);
        if (metadata is! Map) continue;
        if (!metadata.containsKey('ai_result') &&
            !metadata.containsKey('ai_request')) {
          continue;
        }

        final request = metadata['ai_request'];
        if (request is! Map) break;
        final provider = request['provider']?.toString();
        final keySource = request['key_source']?.toString();
        final keyRelation = request['key_relation']?.toString();
        final modelSource = request['model_source']?.toString();
        if (provider != 'gemini' ||
            (keySource != 'backup' && modelSource != 'backup')) {
          break;
        }

        final model = request['model']?.toString();
        final modelSuffix = model == null ? '' : ': $model';
        if (keyRelation == 'same_as_primary' && modelSource == 'backup') {
          label = 'Gemini backup model used with primary key$modelSuffix';
        } else if (keySource == 'backup' && modelSource == 'backup') {
          label = 'Gemini backup key and backup model used$modelSuffix';
        } else if (keySource == 'backup') {
          label = 'Gemini backup key used$modelSuffix';
        } else {
          label = 'Gemini backup model used$modelSuffix';
        }
        break;
      } catch (_) {
        continue;
      }
    }

    if (mounted) {
      setState(() => _aiRequestLabel = label);
    }
  }

  Future<void> _applyAiCorrection() async {
    final entry = widget.existingEntry?.copyWithAiReviewMark(
      _markedForAiReview,
    );
    if (entry == null) return;
    if (_formManager.correctionController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Describe the correction first')),
      );
      return;
    }

    try {
      setState(() => _isApplyingAiCorrection = true);
      await _formManager.applyAiCorrection(entry);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry updated with AI')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI correction failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isApplyingAiCorrection = false);
      }
    }
  }

  Future<void> _rerunAiAnalysis() async {
    final entry = widget.existingEntry?.copyWithAiReviewMark(
      _markedForAiReview,
    );
    if (entry == null) return;

    try {
      setState(() => _isRerunningAi = true);
      await _formManager.rerunAiAnalysis(entry);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Run Again complete')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Run Again failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isRerunningAi = false);
      }
    }
  }

  Future<void> _setAiReviewMark(bool marked) async {
    final entry = widget.existingEntry;
    if (entry == null) return;

    setState(() => _isUpdatingAiReviewMark = true);
    try {
      await ref
          .read(diaryControllerProvider.notifier)
          .setAiReviewMark(entry, marked);
      if (mounted) {
        setState(() => _markedForAiReview = marked);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              marked
                  ? 'Added to AI review queue'
                  : 'Removed from AI review queue',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Review mark failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingAiReviewMark = false);
      }
    }
  }

  Future<void> _pickDate() async {
    final current = ref.read(addEntryControllerProvider).selectedDate;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate != null) {
      ref.read(addEntryControllerProvider.notifier).updateDate(pickedDate);
    }
  }

  Future<void> _pickTime() async {
    final current = ref.read(addEntryControllerProvider).selectedTime;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: current,
    );
    if (pickedTime != null) {
      ref.read(addEntryControllerProvider.notifier).updateTime(pickedTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addEntryControllerProvider);
    final isEditing = widget.existingEntry != null;
    final entryType = widget.existingEntry?.type ?? widget.initialType;

    final isExercise = entryType == EntryType.exercise;
    final isTemperature = entryType == EntryType.temperature;
    final title = isEditing
        ? 'Edit Entry'
        : isExercise
        ? 'Log Exercise'
        : isTemperature
        ? 'Log Temperature'
        : 'Log Food';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isEditing && !state.showForm && !isTemperature)
                AIEntryWizard(
                  isExercise: isExercise,
                  descriptionController: _formManager.descriptionController,
                  images: state.images,
                  canUseCamera: _canUseCamera,
                  onPickImage: (source) => ref
                      .read(addEntryControllerProvider.notifier)
                      .pickImage(source),
                  onRemoveImage: (index) => ref
                      .read(addEntryControllerProvider.notifier)
                      .removeImageAt(index),
                  onPromptSearch: (q) => ref
                      .read(addEntryControllerProvider.notifier)
                      .searchFood(q),
                  onAddOptimistic: _addOptimistic,
                  onEnterManually: () => ref
                      .read(addEntryControllerProvider.notifier)
                      .toggleForm(true),
                  onEntrySelected: (entry) {
                    _formManager.autofill(entry);
                    ref
                        .read(addEntryControllerProvider.notifier)
                        .toggleForm(true);
                  },
                ),
              if (isTemperature)
                TemperatureEntrySection(
                  isEditing: isEditing,
                  temperatureController: _formManager.temperatureController,
                  commentController:
                      _formManager.temperatureCommentController,
                  selectedUnit: state.temperatureUnit,
                  selectedSite: state.temperatureSite,
                  selectedDate: state.selectedDate,
                  selectedTime: state.selectedTime,
                  onUnitChanged: (unit) => ref
                      .read(addEntryControllerProvider.notifier)
                      .updateTemperatureUnit(unit),
                  onSiteChanged: (site) => ref
                      .read(addEntryControllerProvider.notifier)
                      .updateTemperatureSite(site),
                  onPickDate: _pickDate,
                  onPickTime: _pickTime,
                  onSave: _saveEntry,
                  onDeleteConfirmed: () async {
                    try {
                      await _formManager.deleteEntry(widget.existingEntry!);
                      if (context.mounted) context.pop();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to delete: $e')),
                        );
                      }
                    }
                  },
                ),
              if (state.showForm && !isTemperature)
                ManualEntrySection(
                  isEditing: isEditing,
                  isExercise: isExercise,
                  nameController: _formManager.nameController,
                  metricControllers: _formManager.metricControllers,
                  correctionController: _formManager.correctionController,
                  rerunPromptController: _formManager.rerunPromptController,
                  durationController: _formManager.durationController,
                  reasoning: widget.existingEntry?.reasoning,
                  aiRequestLabel: _aiRequestLabel,
                  isApplyingAiCorrection: _isApplyingAiCorrection,
                  isRerunningAi: _isRerunningAi,
                  markedForAiReview: _markedForAiReview,
                  isUpdatingAiReviewMark: _isUpdatingAiReviewMark,
                  selectedIcon: state.selectedIcon,
                  selectedDate: state.selectedDate,
                  selectedTime: state.selectedTime,
                  onBackToWizard: () => ref
                      .read(addEntryControllerProvider.notifier)
                      .toggleForm(false),
                  onIconChanged: (v) {
                    if (v != null) {
                      ref
                          .read(addEntryControllerProvider.notifier)
                          .updateIcon(v);
                    }
                  },
                  onPickDate: _pickDate,
                  onPickTime: _pickTime,
                  onSave: _saveEntry,
                  onApplyAiCorrection:
                      isEditing && !isExercise ? _applyAiCorrection : null,
                  onRerunAi: isEditing && !isExercise ? _rerunAiAnalysis : null,
                  onAiReviewMarkChanged:
                      isEditing && !isExercise ? _setAiReviewMark : null,
                  onDeleteConfirmed: () async {
                    try {
                      await _formManager.deleteEntry(widget.existingEntry!);
                      if (context.mounted) context.pop();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to delete: $e')),
                        );
                      }
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
