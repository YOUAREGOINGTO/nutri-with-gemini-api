import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/providers.dart';
import 'package:nutrinutri/core/services/data_portability_service.dart';
import 'package:nutrinutri/core/services/google_user_info.dart';
import 'package:nutrinutri/core/utils/platform_helper.dart';
import 'package:nutrinutri/core/widgets/responsive_center.dart';
import 'package:nutrinutri/features/dashboard/presentation/dashboard_providers.dart';
import 'package:nutrinutri/features/diary/application/diary_controller.dart';
import 'package:nutrinutri/features/settings/presentation/managers/settings_form_manager.dart';
import 'package:nutrinutri/features/settings/presentation/settings_controller.dart';
import 'package:nutrinutri/features/settings/presentation/widgets/ai_configuration_section.dart';
import 'package:nutrinutri/features/settings/presentation/widgets/profile_section.dart';
import 'package:nutrinutri/features/settings/presentation/widgets/sync_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final SettingsFormManager _formManager;
  bool _isExportingData = false;
  bool _isImportingData = false;
  bool _isExportingBackup = false;
  bool _isImportingBackup = false;
  bool _isExportingDailyXlsx = false;
  bool _isClearingAiReviewQueue = false;

  @override
  void initState() {
    super.initState();
    _formManager = SettingsFormManager(
      ref: ref,
      onStateChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSettings();
    });
  }

  @override
  void dispose() {
    _formManager.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    await _formManager.loadSettings();
  }

  Future<void> _save() async {
    try {
      await _formManager.save();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Settings saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving: $e')));
      }
    }
  }

  Future<void> _handleSync() async {
    try {
      final result = await ref.read(settingsControllerProvider.notifier).sync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sync complete: ↓${result.downloaded} ↑${result.uploaded}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (!_formManager.hasChanges()) return true;

    final shouldPop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text(
          'You have unsaved changes. Do you want to save them before leaving?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () async {
              await _save();
              if (context.mounted) Navigator.of(context).pop(true);
            },
            child: const Text('Save & Leave'),
          ),
        ],
      ),
    );

    return shouldPop ?? false;
  }

  void _onModelChanged(SettingsController controller, String? value) {
    if (value == null) return;
    controller.updateModel(value);
  }

  void _onProviderChanged(AIProvider? value) {
    if (value == null) return;
    unawaited(_formManager.changeProvider(value));
  }

  void _onGenderChanged(SettingsController controller, String? value) {
    if (value == null) return;
    controller.updateGender(value);
    _formManager.recalculateCalories();
  }

  void _onActivityLevelChanged(SettingsController controller, String? value) {
    if (value == null) return;
    controller.updateActivityLevel(value);
    _formManager.recalculateCalories();
  }

  DataPortabilityService _dataPortabilityService() {
    return DataPortabilityService(
      ref.read(appDatabaseProvider),
      ref.read(deviceIdServiceProvider),
      ref.read(syncServiceProvider),
    );
  }

  String _backupExportMessage(DataExportResult result) {
    return 'Exported ${result.entryCount} entries to ZIP backup';
  }

  Future<void> _exportData() async {
    if (_isExportingData) return;
    setState(() => _isExportingData = true);
    try {
      final result = await _dataPortabilityService().exportCsv();
      if (!mounted) return;

      final message = result == null
          ? 'Export cancelled'
          : 'Exported ${result.entryCount} entries to CSV';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isExportingData = false);
      }
    }
  }

  Future<void> _exportBackup() async {
    if (_isExportingBackup) return;
    setState(() => _isExportingBackup = true);
    try {
      final result = await _dataPortabilityService().exportBackupZip();
      if (!mounted) return;

      final message = result == null
          ? 'Backup export cancelled'
          : _backupExportMessage(result);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup export failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isExportingBackup = false);
      }
    }
  }

  Future<void> _clearAiReviewQueue() async {
    if (_isClearingAiReviewQueue) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Review List'),
        content: const Text(
          'Remove the review mark from every entry? Diary entries stay untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isClearingAiReviewQueue = true);
    try {
      final cleared = await ref
          .read(diaryControllerProvider.notifier)
          .clearAiReviewMarks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cleared $cleared review marks')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Clear failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isClearingAiReviewQueue = false);
      }
    }
  }

  Future<void> _exportDailyXlsx() async {
    if (_isExportingDailyXlsx) return;
    setState(() => _isExportingDailyXlsx = true);
    try {
      final result = await _dataPortabilityService().exportDailyXlsx();
      if (!mounted) return;

      final dayCount = result?.dayCount ?? 0;
      final dayLabel = dayCount == 1 ? 'day' : 'days';
      final message = result == null
          ? 'XLSX export cancelled'
          : 'Exported $dayCount $dayLabel to daily XLSX';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('XLSX export failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isExportingDailyXlsx = false);
      }
    }
  }

  Future<void> _importData() async {
    if (_isImportingData) return;
    setState(() => _isImportingData = true);
    try {
      final result = await _dataPortabilityService().importCsv();
      if (!mounted) return;

      if (result == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Import cancelled')));
        return;
      }

      _invalidateImportedDates(result.affectedDates);

      final skippedText = result.skippedRows == 0
          ? ''
          : ' (${result.skippedRows} skipped)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.importedEntries} entries$skippedText',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isImportingData = false);
      }
    }
  }

  Future<void> _importBackup() async {
    if (_isImportingBackup) return;
    setState(() => _isImportingBackup = true);
    try {
      final result = await _dataPortabilityService().importBackupZip();
      if (!mounted) return;

      if (result == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Backup import cancelled')));
        return;
      }

      _invalidateImportedDates(result.affectedDates);

      final skippedText = result.skippedRows == 0
          ? ''
          : ' (${result.skippedRows} skipped)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored ${result.importedEntries} entries$skippedText',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup import failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isImportingBackup = false);
      }
    }
  }

  void _invalidateImportedDates(Set<DateTime> dates) {
    for (final date in dates) {
      ref.invalidate(dayEntriesProvider(date));
      ref.invalidate(dailySummaryProvider(date));
      ref.invalidate(dailySummaryDataProvider(date));
    }
  }

  Future<void> _openLicenses() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      const platform = MethodChannel('sk.popelis.nutrinutri/licenses');
      try {
        await platform.invokeMethod('showLicenses');
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load licenses: '$e'.")),
        );
      }
      return;
    }

    showLicensePage(
      context: context,
      applicationName: 'NutriNutri',
      useRootNavigator: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsControllerProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final controller = ref.read(settingsControllerProvider.notifier);
    final isDesktop = PlatformHelper.isDesktopOrWeb;
    final theme = Theme.of(context);
    final settingsSections = _SettingsSections(
      state: state,
      currentUser: currentUser,
      controller: controller,
      formManager: _formManager,
      onProviderChanged: _onProviderChanged,
      onModelChanged: (value) => _onModelChanged(controller, value),
      onFallbackModelChanged: controller.updateFallbackModel,
      onGenderChanged: (value) => _onGenderChanged(controller, value),
      onActivityLevelChanged: (value) =>
          _onActivityLevelChanged(controller, value),
      onSync: () => unawaited(_handleSync()),
      onExportData: () => unawaited(_exportData()),
      onImportData: () => unawaited(_importData()),
      onExportBackup: () => unawaited(_exportBackup()),
      onImportBackup: () => unawaited(_importBackup()),
      onExportDailyXlsx: () => unawaited(_exportDailyXlsx()),
      onClearAiReviewQueue: () => unawaited(_clearAiReviewQueue()),
      onOpenLicenses: () => unawaited(_openLicenses()),
      onRefreshGeminiModels: () =>
          unawaited(_formManager.refreshGeminiModels()),
      isExportingData: _isExportingData,
      isImportingData: _isImportingData,
      isExportingBackup: _isExportingBackup,
      isImportingBackup: _isImportingBackup,
      isExportingDailyXlsx: _isExportingDailyXlsx,
      isClearingAiReviewQueue: _isClearingAiReviewQueue,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: isDesktop ? null : AppBar(title: const Text('Settings')),
        body: isDesktop
            ? _buildDesktopLayout(context, theme, state, settingsSections)
            : _buildMobileLayout(state, settingsSections),
      ),
    );
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    ThemeData theme,
    SettingsState state,
    Widget settingsSections,
  ) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Desktop header
          Row(
            children: [
              Text(
                'Settings',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: state.isLoading ? null : _save,
                icon: const Icon(Icons.save),
                label: const Text('Save Settings'),
              ),
            ],
          ),
          const Gap(24),
          // Main content
          Expanded(
            child: ResponsiveCenter(
              maxWidth: 900,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [settingsSections],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(SettingsState state, Widget settingsSections) {
    return ResponsiveCenter(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          settingsSections,
          const Gap(24),
          FilledButton.icon(
            onPressed: state.isLoading ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Save Settings'),
          ),
          const Gap(40),
        ],
      ),
    );
  }
}

class _SettingsSections extends StatelessWidget {
  const _SettingsSections({
    required this.state,
    required this.currentUser,
    required this.controller,
    required this.formManager,
    required this.onProviderChanged,
    required this.onModelChanged,
    required this.onFallbackModelChanged,
    required this.onGenderChanged,
    required this.onActivityLevelChanged,
    required this.onSync,
    required this.onExportData,
    required this.onImportData,
    required this.onExportBackup,
    required this.onImportBackup,
    required this.onExportDailyXlsx,
    required this.onClearAiReviewQueue,
    required this.onOpenLicenses,
    required this.onRefreshGeminiModels,
    required this.isExportingData,
    required this.isImportingData,
    required this.isExportingBackup,
    required this.isImportingBackup,
    required this.isExportingDailyXlsx,
    required this.isClearingAiReviewQueue,
  });

  final SettingsState state;
  final GoogleUserInfo? currentUser;
  final SettingsController controller;
  final SettingsFormManager formManager;
  final ValueChanged<AIProvider?> onProviderChanged;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?> onFallbackModelChanged;
  final ValueChanged<String?> onGenderChanged;
  final ValueChanged<String?> onActivityLevelChanged;
  final VoidCallback onSync;
  final VoidCallback onExportData;
  final VoidCallback onImportData;
  final VoidCallback onExportBackup;
  final VoidCallback onImportBackup;
  final VoidCallback onExportDailyXlsx;
  final VoidCallback onClearAiReviewQueue;
  final VoidCallback onOpenLicenses;
  final VoidCallback onRefreshGeminiModels;
  final bool isExportingData;
  final bool isImportingData;
  final bool isExportingBackup;
  final bool isImportingBackup;
  final bool isExportingDailyXlsx;
  final bool isClearingAiReviewQueue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AIConfigurationSection(
          provider: state.provider,
          apiKeyController: formManager.apiKeyController,
          geminiBackupApiKeyController:
              formManager.geminiBackupApiKeyController,
          customModelController: formManager.customModelController,
          selectedModel: state.selectedModel,
          fallbackModel: state.fallbackModel,
          availableModels: controller.availableModels,
          isLoadingModels: state.isLoadingModels,
          modelLoadError: state.modelLoadError,
          onProviderChanged: onProviderChanged,
          onModelChanged: onModelChanged,
          onFallbackModelChanged: onFallbackModelChanged,
          onRefreshModels: onRefreshGeminiModels,
        ),
        const _SettingsSectionBreak(),
        SyncSection(
          currentUser: currentUser,
          isSyncing: state.isSyncing,
          onSignIn: controller.signIn,
          onSignOut: controller.signOut,
          onSync: onSync,
          webSignInButton: controller.webSignInButton,
        ),
        const _SettingsSectionBreak(),
        ProfileSection(
          ageController: formManager.ageController,
          weightController: formManager.weightController,
          heightController: formManager.heightController,
          metricGoalControllers: formManager.metricGoalControllers,
          gender: state.gender,
          activityLevel: state.activityLevel,
          onGenderChanged: onGenderChanged,
          onActivityLevelChanged: onActivityLevelChanged,
        ),
        const _SettingsSectionBreak(),
        _DataSection(
          isExporting: isExportingData,
          isImporting: isImportingData,
          isExportingBackup: isExportingBackup,
          isImportingBackup: isImportingBackup,
          isExportingDailyXlsx: isExportingDailyXlsx,
          isClearingAiReviewQueue: isClearingAiReviewQueue,
          onExport: onExportData,
          onImport: onImportData,
          onExportBackup: onExportBackup,
          onImportBackup: onImportBackup,
          onExportDailyXlsx: onExportDailyXlsx,
          onClearAiReviewQueue: onClearAiReviewQueue,
        ),
        const _SettingsSectionBreak(),
        _AboutSection(onOpenLicenses: onOpenLicenses),
      ],
    );
  }
}

class _SettingsSectionBreak extends StatelessWidget {
  const _SettingsSectionBreak();

  @override
  Widget build(BuildContext context) {
    return const Column(children: [Gap(32), Divider(), Gap(16)]);
  }
}

class _DataSection extends StatelessWidget {
  const _DataSection({
    required this.isExporting,
    required this.isImporting,
    required this.isExportingBackup,
    required this.isImportingBackup,
    required this.isExportingDailyXlsx,
    required this.isClearingAiReviewQueue,
    required this.onExport,
    required this.onImport,
    required this.onExportBackup,
    required this.onImportBackup,
    required this.onExportDailyXlsx,
    required this.onClearAiReviewQueue,
  });

  final bool isExporting;
  final bool isImporting;
  final bool isExportingBackup;
  final bool isImportingBackup;
  final bool isExportingDailyXlsx;
  final bool isClearingAiReviewQueue;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onExportBackup;
  final VoidCallback onImportBackup;
  final VoidCallback onExportDailyXlsx;
  final VoidCallback onClearAiReviewQueue;

  bool get _isBusy =>
      isExporting ||
      isImporting ||
      isExportingBackup ||
      isImportingBackup ||
      isExportingDailyXlsx ||
      isClearingAiReviewQueue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Data', style: Theme.of(context).textTheme.titleMedium),
        ),
        const Gap(8),
        ListTile(
          title: const Text('Export ZIP Backup'),
          subtitle: const Text('Save entries, images, and AI chat history'),
          leading: const Icon(Icons.archive_outlined),
          trailing: isExportingBackup
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onExportBackup,
        ),
        ListTile(
          title: const Text('Import ZIP Backup'),
          subtitle: const Text('Restore entries without removing existing data'),
          leading: const Icon(Icons.unarchive_outlined),
          trailing: isImportingBackup
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onImportBackup,
        ),
        ListTile(
          title: const Text('Export CSV'),
          subtitle: const Text('Save a portable backup of diary entries'),
          leading: const Icon(Icons.download),
          trailing: isExporting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onExport,
        ),
        ListTile(
          title: const Text('Export Daily XLSX'),
          subtitle: const Text('Save daily nutrition totals as one spreadsheet'),
          leading: const Icon(Icons.table_chart_outlined),
          trailing: isExportingDailyXlsx
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onExportDailyXlsx,
        ),
        ListTile(
          title: const Text('Clear Review List'),
          subtitle: const Text('Remove all review marks at once'),
          leading: const Icon(Icons.fact_check_outlined),
          trailing: isClearingAiReviewQueue
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onClearAiReviewQueue,
        ),
        ListTile(
          title: const Text('Import CSV'),
          subtitle: const Text('Add or update entries from a CSV backup'),
          leading: const Icon(Icons.upload_file),
          trailing: isImporting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _isBusy ? null : onImport,
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.onOpenLicenses});

  final VoidCallback onOpenLicenses;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('About', style: Theme.of(context).textTheme.titleMedium),
        ),
        const Gap(8),
        ListTile(
          title: const Text('Open Source Licenses'),
          leading: const Icon(Icons.description),
          trailing: const Icon(Icons.chevron_right),
          onTap: onOpenLicenses,
        ),
      ],
    );
  }
}
