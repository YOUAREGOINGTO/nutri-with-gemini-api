import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/features/settings/domain/ai_model_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AIConfigurationSection extends StatelessWidget {
  const AIConfigurationSection({
    super.key,
    required this.provider,
    required this.apiKeyController,
    required this.customModelController,
    required this.selectedModel,
    this.fallbackModel,
    required this.availableModels,
    required this.isLoadingModels,
    this.modelLoadError,
    required this.onProviderChanged,
    required this.onModelChanged,
    required this.onFallbackModelChanged,
    required this.onRefreshModels,
  });
  final AIProvider provider;
  final TextEditingController apiKeyController;
  final TextEditingController customModelController;
  final String selectedModel;
  final String? fallbackModel;
  final List<AIModelInfo> availableModels;
  final bool isLoadingModels;
  final String? modelLoadError;
  final ValueChanged<AIProvider?> onProviderChanged;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?> onFallbackModelChanged;
  final VoidCallback onRefreshModels;

  Future<void> _openApiKeysPage(BuildContext context) async {
    final url = Uri.parse(provider.apiKeyUrl);
    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(provider.apiKeyHelp)),
      );
    }
  }

  Widget _buildModelTile(BuildContext context, AIModelInfo model) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const Gap(8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  model.price,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const Gap(4),
          Text(
            model.description,
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderDropdown() {
    return DropdownButtonFormField<AIProvider>(
      initialValue: provider,
      decoration: const InputDecoration(
        labelText: 'AI Provider',
        border: OutlineInputBorder(),
      ),
      items: AIProvider.values
          .map(
            (provider) => DropdownMenuItem<AIProvider>(
              value: provider,
              child: Text(provider.label),
            ),
          )
          .toList(),
      onChanged: onProviderChanged,
    );
  }

  List<DropdownMenuItem<String>> _buildModelItems(
    BuildContext context, {
    required bool includeNone,
  }) {
    final items = <DropdownMenuItem<String>>[];

    if (includeNone) {
      items.add(
        const DropdownMenuItem<String>(value: null, child: Text('None')),
      );
    }

    items.addAll(
      availableModels.map(
        (model) => DropdownMenuItem<String>(
          value: model.id,
          child: _buildModelTile(context, model),
        ),
      ),
    );
    return items;
  }

  List<Widget> _buildSelectedItems({required bool includeNone}) {
    final items = <Widget>[];

    if (includeNone) {
      items.add(
        const Align(alignment: Alignment.centerLeft, child: Text('None')),
      );
    }

    items.addAll(
      availableModels.map(
        (model) => Align(
          alignment: Alignment.centerLeft,
          child: Text(
            model.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.normal),
          ),
        ),
      ),
    );
    return items;
  }

  Widget _buildModelDropdown({
    required BuildContext context,
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
    String? helperText,
    String? hintText,
    bool includeNone = false,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        helperText: helperText,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          itemHeight: null,
          hint: hintText != null ? Text(hintText) : null,
          items: _buildModelItems(context, includeNone: includeNone),
          selectedItemBuilder: (_) {
            return _buildSelectedItems(includeNone: includeNone);
          },
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'AI Configuration',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Gap(16),
        const Text(
          'Choose OpenRouter or the native Gemini API to analyze your food. You need to provide your own API key.',
          style: TextStyle(color: Colors.grey),
        ),
        const Gap(16),
        _buildProviderDropdown(),
        const Gap(8),
        TextField(
          controller: apiKeyController,
          decoration: InputDecoration(
            labelText: provider.apiKeyLabel,
            border: const OutlineInputBorder(),
            hintText: provider.apiKeyHint,
          ),
          obscureText: true,
        ),
        if (apiKeyController.text.isEmpty) ...[
          const Gap(8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openApiKeysPage(context),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Get API Key'),
            ),
          ),
        ] else ...[
          if (provider == AIProvider.gemini) ...[
            const Gap(8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isLoadingModels ? null : onRefreshModels,
                icon: isLoadingModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('Refresh Gemini Models'),
              ),
            ),
            if (modelLoadError != null) ...[
              const Gap(8),
              Text(
                modelLoadError!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
          const Gap(16),
          _buildModelDropdown(
            context: context,
            label: 'AI Model',
            value: selectedModel,
            onChanged: onModelChanged,
          ),
          if (selectedModel == 'custom') ...[
            const Gap(8),
            TextField(
              controller: customModelController,
              decoration: InputDecoration(
                labelText: 'Custom Model ID (${provider.label})',
                border: const OutlineInputBorder(),
                hintText: provider == AIProvider.gemini
                    ? 'e.g. gemini-3.1-pro-preview'
                    : 'e.g. meta-llama/llama-3-70b-instruct',
              ),
            ),
          ],
          const Gap(16),
          _buildModelDropdown(
            context: context,
            label: 'Fallback Model (Optional)',
            helperText: 'Used if the primary model fails',
            hintText: 'None',
            value: fallbackModel,
            includeNone: true,
            onChanged: onFallbackModelChanged,
          ),
        ],
      ],
    );
  }
}
