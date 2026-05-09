enum AIProvider {
  openRouter(
    id: 'openrouter',
    label: 'OpenRouter',
    apiKeyLabel: 'OpenRouter API Key',
    apiKeyHint: 'sk-or-...',
    apiKeyUrl: 'https://openrouter.ai/settings/keys',
    apiKeyHelp: 'Could not open browser. Visit openrouter.ai/settings/keys',
    defaultModel: 'google/gemini-3-flash-preview',
  ),
  gemini(
    id: 'gemini',
    label: 'Gemini',
    apiKeyLabel: 'Gemini API Key',
    apiKeyHint: 'AIza...',
    apiKeyUrl: 'https://aistudio.google.com/app/apikey',
    apiKeyHelp: 'Could not open browser. Visit aistudio.google.com/app/apikey',
    defaultModel: 'gemini-3.1-flash-lite',
  );

  const AIProvider({
    required this.id,
    required this.label,
    required this.apiKeyLabel,
    required this.apiKeyHint,
    required this.apiKeyUrl,
    required this.apiKeyHelp,
    required this.defaultModel,
  });

  final String id;
  final String label;
  final String apiKeyLabel;
  final String apiKeyHint;
  final String apiKeyUrl;
  final String apiKeyHelp;
  final String defaultModel;

  static AIProvider fromId(String? id) {
    return AIProvider.values.firstWhere(
      (provider) => provider.id == id,
      orElse: () => AIProvider.openRouter,
    );
  }
}
