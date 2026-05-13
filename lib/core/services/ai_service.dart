import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/domain/user_profile.dart';

class GeminiModelDescriptor {
  const GeminiModelDescriptor({
    required this.id,
    required this.name,
    required this.description,
    required this.inputTokenLimit,
    required this.outputTokenLimit,
  });

  final String id;
  final String name;
  final String description;
  final int? inputTokenLimit;
  final int? outputTokenLimit;

  static GeminiModelDescriptor? fromJson(Map<String, dynamic> json) {
    final methods = (json['supportedGenerationMethods'] as List? ?? const [])
        .map((method) => method.toString())
        .toSet();
    if (!methods.contains('generateContent')) return null;

    final rawName = json['name']?.toString() ?? '';
    final id = rawName.startsWith('models/')
        ? rawName.substring('models/'.length)
        : rawName;
    if (id.isEmpty || !id.startsWith('gemini-')) return null;

    return GeminiModelDescriptor(
      id: id,
      name: (json['displayName']?.toString().trim().isNotEmpty == true)
          ? json['displayName'].toString().trim()
          : _titleFromModelId(id),
      description: json['description']?.toString() ?? '',
      inputTokenLimit: _toInt(json['inputTokenLimit']),
      outputTokenLimit: _toInt(json['outputTokenLimit']),
    );
  }
}

class AIService {
  AIService({
    required this.apiKey,
    required this.model,
    this.backupApiKey,
    this.backupModel,
    this.provider = AIProvider.openRouter,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? (() => http.Client());

  static const String _openRouterBaseUrl =
      'https://openrouter.ai/api/v1/chat/completions';
  static const String _geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  final String apiKey;
  final String model;
  final String? backupApiKey;
  final String? backupModel;
  final AIProvider provider;
  final http.Client Function() _clientFactory;

  // Track active clients for cancellation
  final Map<String, http.Client> _activeRequests = {};

  bool get hasUsableApiKey => _hasUsableApiKey;

  static Future<List<GeminiModelDescriptor>> listGeminiModels({
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) return const [];

    final client = http.Client();
    final models = <GeminiModelDescriptor>[];
    String? pageToken;

    try {
      do {
        final queryParameters = <String, String>{
          'key': apiKey.trim(),
          'pageSize': '1000',
        };
        final token = pageToken ?? '';
        if (token.isNotEmpty) {
          queryParameters['pageToken'] = token;
        }

        final uri = Uri.parse('$_geminiBaseUrl/models').replace(
          queryParameters: queryParameters,
        );
        final response = await client.get(uri);

        if (response.statusCode != 200) {
          throw Exception(
            'Gemini model list error: ${response.statusCode} - ${response.body}',
          );
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawModels = data['models'] as List? ?? const [];
        for (final rawModel in rawModels) {
          if (rawModel is! Map) continue;
          final model = GeminiModelDescriptor.fromJson(
            Map<String, dynamic>.from(rawModel),
          );
          if (model != null) {
            models.add(model);
          }
        }

        pageToken = data['nextPageToken']?.toString();
      } while ((pageToken ?? '').isNotEmpty);
    } finally {
      client.close();
    }

    models.sort(_compareGeminiModels);
    return models;
  }

  Map<String, String> _openRouterHeaders() => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'HTTP-Referer': 'https://nutrinutri.popelis.sk',
    'X-Title': 'NutriNutri',
  };

  Map<String, String> _geminiHeaders() => {'Content-Type': 'application/json'};

  String _foodRegionContext() {
    final locale = ui.PlatformDispatcher.instance.locale;
    final countryCode = locale.countryCode?.trim().toUpperCase() ?? '';
    final regionName = _countryNameForCode(countryCode);

    if (regionName != null) {
      return 'User region context: $regionName. Use reasonable regional food and portion assumptions when estimating.';
    }

    return 'User region context: unknown. Use reasonable regional food and portion assumptions when the food context indicates them.';
  }

  String? _countryNameForCode(String code) {
    return switch (code) {
      'IN' => 'India',
      'US' => 'America',
      'CA' => 'Canada',
      'GB' => 'United Kingdom',
      'AU' => 'Australia',
      'AE' => 'United Arab Emirates',
      'SA' => 'Saudi Arabia',
      'SG' => 'Singapore',
      'MY' => 'Malaysia',
      'PK' => 'Pakistan',
      'BD' => 'Bangladesh',
      'LK' => 'Sri Lanka',
      'NP' => 'Nepal',
      _ => null,
    };
  }

  List<Map<String, dynamic>> _foodMessages({
    String? textDescription,
    String? base64Image,
    List<String>? base64Images,
  }) {
    final images = _mergedBase64Images(base64Image, base64Images);
    final regionContext = _foodRegionContext();
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '''
You are a nutrition estimation assistant for a food diary.
The app intent is already Log Food. Return STRICT JSON ONLY. No markdown, no intro/outro.
$regionContext

Output schema, with types only. In the final response, replace these type names with actual JSON values:
{
  "food_name": string,
  "estimated_quantity": string,
  "reasoning": string,
  "metrics": {
    "calories": number,
    "carbs": number,
    "sugars": number,
    "fats": number,
    "saturated_fats": number,
    "protein": number,
    "fiber": number,
    "sodium": number,
    "caffeine": number,
    "water": number
  },
  "icon": string
}

Rules:
- Return exactly one JSON object with exactly these top-level keys.
- All metric values must be JSON numbers, never strings or null.
- Always include every metrics key.
- Do not include confidence, record_type, arrays, comments, or extra keys.
- User text is the strongest source for quantity.
- Images identify foods and estimate visible portions. Use all images as foods/drinks the user is logging in one entry by default.
- Multiple images usually mean multiple consumed foods/drinks or portion evidence for what the user ate.
- Sum the nutrition across all distinct consumed foods/drinks shown in the provided images, unless the user text narrows the logged amount.
- If multiple distinct foods/drinks are logged, combine them into one concise food_name and summarize all quantities in estimated_quantity.
- Only treat an image as a duplicate angle if the user says it is another angle/the same item, or if it is clearly the exact same food portion from another angle.
- Do not double count clear duplicate image angles.
- If an image is unrelated or not food/drink, ignore it for nutrition and mention that briefly in reasoning.
- Return all metrics as 0 only when no food/drink is being logged at all.
- Do not assume the user is logging a full meal or full plate.
- If the user says half of this, one piece, one spoon, only this part, or similar, estimate only that logged amount.
- Metrics must be the final total for what the user is logging.
- Before assigning metrics, identify the likely food/drink, consumed quantity, preparation method, and calorie-bearing additions.
- Use the user region context and visible food cues to make reasonable regional portion and preparation assumptions.
- Account for visible or strongly implied ingredients such as cooking oil, ghee, butter, sauces, dressings, gravy, added sugar, cream, cheese, nuts, batter, breading, and toppings.
- If oil, ghee, sauces, or ingredients are uncertain, use a normal moderate assumption for that food and cuisine when the dish clearly implies them. Do not invent sides, toppings, or ingredients that are not visible, named, or typical for the identified item.
- User text overrides assumptions. If the user says no oil, no sugar, plain, boiled, steamed, baked, or gives an ingredient/quantity correction, follow that.
- Validate the final numbers before returning JSON. Check that calories roughly match the visible quantity, regional preparation style, cooking fats/additions, and macro totals.
- In the final JSON, write reasoning before metrics as shown in the schema. The metric values must be consistent with the quantity and ingredient assumptions summarized in reasoning.
- estimated_quantity should briefly summarize the quantity used.
- reasoning should be concise but complete user-facing calculation basis, not hidden chain-of-thought. Include only needed details: what the input appears to be, how the logged quantity was interpreted, which visible or typical ingredients/cooking fats affected the estimate, how multiple images or unrelated images were handled, and why the calorie/macro estimate or zero values make sense.
- If the input is not food or drink, use the same schema with every metric set to 0.
- For non-food inputs, food_name should describe the item, and reasoning should explain why calories and macros are 0.
- Do not invent calories for blood tests, documents, medicine labels, random labels, packaging labels without a consumed portion, or other non-food/non-drink inputs.
- A package label or nutrition label alone is not a consumed portion; use label information only when the user or image evidence indicates an eaten/drunk amount.
Select the most appropriate icon from this list:
[bakery_dining, brunch_dining, bento, cake, coffee, cookie, egg_alt, fastfood, flatware, liquor, microwave, nightlife, outdoor_grill, ramen_dining, restaurant, rice_bowl, sports_bar, tapas]
''',
      },
    ];

    if (images.isNotEmpty) {
      final content = <Map<String, dynamic>>[
        {
          'type': 'text',
          'text':
              textDescription?.trim().isNotEmpty == true
                  ? textDescription!.trim()
                  : 'Analyze the provided food/drink images.',
        },
      ];

      for (var i = 0; i < images.length; i++) {
        content.add({'type': 'text', 'text': 'Image ${i + 1}'});
        content.add({
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,${images[i]}'},
        });
      }
      messages.add({
        'role': 'user',
        'content': content,
      });
    } else {
      messages.add({
        'role': 'user',
        'content': textDescription ?? 'Analyze this food or drink.',
      });
    }

    return messages;
  }

  List<Map<String, dynamic>> _foodCorrectionMessages({
    required String correctionMessage,
    required String currentEntryJson,
    required String previousAiJson,
    required String previousReasoning,
    required String imageMetadataJson,
    List<String>? base64Images,
  }) {
    final prompt = '''
Correct the existing food diary entry using the new user correction.

Current diary entry values:
$currentEntryJson

Previous AI JSON/result:
$previousAiJson

Previous user-facing reasoning:
$previousReasoning

Image metadata/paths:
$imageMetadataJson

New user correction message:
$correctionMessage

Return corrected strict JSON for the same diary entry. Update only the values that should change because of the correction, while keeping the same schema and food logging rules.
''';

    return _foodMessages(
      textDescription: prompt,
      base64Images: base64Images,
    );
  }

  List<Map<String, dynamic>> _exerciseMessages({
    required String textDescription,
    UserProfile? userProfile,
  }) {
    final profileInfo = userProfile == null
        ? ''
        : 'User Profile for Calorie Calculation:\n'
              'Age: ${userProfile.age}\n'
              'Weight: ${userProfile.weightKg} kg\n'
              'Height: ${userProfile.heightCm} cm\n'
              'Gender: ${userProfile.gender}\n';

    return <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '''
You are a fitness expert AI. Analyze the exercise described.
$profileInfo
Return STRICT JSON ONLY. No markdown.
Select the most appropriate icon from this list:
[directions_run, directions_bike, directions_walk, fitness_center, pool, sports_soccer, sports_tennis, sports_basketball, rowing, hiking, yoga, self_improvement]

Structure:
{
  "food_name": "Short descriptive exercise name",
  "metrics": {
    "calories": 150.0
  },
  "durationMinutes": 30,
  "icon": "directions_run",
  "confidence": 0.9
}
Calculate calories based on the user profile provided and standard MET values.
''',
      },
      {'role': 'user', 'content': textDescription},
    ];
  }

  bool _looksLikeClientException(Object error) {
    return error is http.ClientException ||
        error.toString().contains('ClientException');
  }

  bool _isCancelledRequest(
    String? requestId,
    http.Client client,
    Object error,
  ) {
    return requestId != null &&
        _looksLikeClientException(error) &&
        _activeRequests[requestId] != client;
  }

  Future<Map<String, dynamic>> _chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    String? requestId,
  }) async {
    if (!_hasUsableApiKey) {
      throw Exception('API Key is missing');
    }

    final client = _clientFactory();
    if (requestId != null) {
      _activeRequests[requestId]?.close(); // Cancel previous if exists
      _activeRequests[requestId] = client;
    }

    try {
      return switch (provider) {
        AIProvider.openRouter => _openRouterChatCompletion(
          client: client,
          messages: messages,
          modelOverride: modelOverride,
        ),
        AIProvider.gemini => _geminiGenerateContentWithKeyFallback(
          client: client,
          messages: messages,
          modelOverride: modelOverride,
          requestId: requestId,
        ),
      };
    } catch (e) {
      if (_isCancelledRequest(requestId, client, e)) {
        throw Exception('Request cancelled');
      }
      debugPrint('AI Service Error: $e');
      rethrow;
    } finally {
      if (requestId != null && _activeRequests[requestId] == client) {
        _activeRequests.remove(requestId);
      }
      client.close();
    }
  }

  bool get _hasUsableApiKey {
    if (apiKey.trim().isNotEmpty) return true;
    return provider == AIProvider.gemini &&
        (backupApiKey?.trim().isNotEmpty ?? false);
  }

  Future<Map<String, dynamic>> _openRouterChatCompletion({
    required http.Client client,
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
  }) async {
    final body = jsonEncode({
      'model': modelOverride ?? model,
      'messages': messages,
      'response_format': {'type': 'json_object'},
    });

    final response = await client.post(
      Uri.parse(_openRouterBaseUrl),
      headers: _openRouterHeaders(),
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('AI Error: ${response.statusCode} - ${response.body}');
    }

    final data = jsonDecode(response.body);
    final content = data['choices'][0]['message']['content'];
    return jsonDecode(_extractJson(content));
  }

  Future<Map<String, dynamic>> _geminiGenerateContent({
    required http.Client client,
    required List<Map<String, dynamic>> messages,
    required String apiKeyOverride,
    String? modelOverride,
  }) async {
    final selectedModel = _normalizeGeminiModel(modelOverride ?? model);
    final body = jsonEncode({
      ..._geminiSystemInstruction(messages),
      'contents': _geminiContents(messages),
      'generationConfig': {'responseMimeType': 'application/json'},
    });

    final uri = Uri.parse(
      '$_geminiBaseUrl/models/$selectedModel:generateContent',
    ).replace(queryParameters: {'key': apiKeyOverride});

    final response = await client.post(
      uri,
      headers: _geminiHeaders(),
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Gemini Error: ${response.statusCode} - ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = _geminiText(data);
    if (content.isEmpty) {
      throw Exception('Gemini returned an empty response');
    }
    return jsonDecode(_extractJson(content));
  }

  Future<Map<String, dynamic>> _geminiGenerateContentWithKeyFallback({
    required http.Client client,
    required List<Map<String, dynamic>> messages,
    String? modelOverride,
    String? requestId,
  }) async {
    final primaryKey = apiKey.trim();
    final fallbackKey = backupApiKey?.trim() ?? '';
    final primaryModel = modelOverride ?? model;
    final fallbackModel = backupModel?.trim().isNotEmpty == true
        ? backupModel!.trim()
        : primaryModel;
    final fallbackKeyRelation = fallbackKey.isEmpty
        ? 'missing'
        : fallbackKey == primaryKey
        ? 'same_as_primary'
        : 'different_from_primary';

    if (primaryKey.isEmpty) {
      final result = await _geminiGenerateContent(
        client: client,
        messages: messages,
        apiKeyOverride: fallbackKey,
        modelOverride: fallbackModel,
      );
      return _withAiRequestMetadata(
        result,
        keySource: 'backup',
        modelId: _normalizeGeminiModel(fallbackModel),
        modelSource: fallbackModel == primaryModel ? 'primary' : 'backup',
        keyRelation: 'backup_only',
      );
    }

    try {
      final result = await _geminiGenerateContent(
        client: client,
        messages: messages,
        apiKeyOverride: primaryKey,
        modelOverride: primaryModel,
      );
      return _withAiRequestMetadata(
        result,
        keySource: 'primary',
        modelId: _normalizeGeminiModel(primaryModel),
        modelSource: 'primary',
        keyRelation: fallbackKeyRelation,
      );
    } catch (primaryError) {
      if (_isCancelledRequest(requestId, client, primaryError)) {
        rethrow;
      }
      final hasBackupModel = fallbackModel != primaryModel;
      final hasDistinctBackupKey =
          fallbackKey.isNotEmpty && fallbackKey != primaryKey;
      if (!hasBackupModel && !hasDistinctBackupKey) {
        throw Exception(
          'Gemini primary failed and no distinct backup key or backup model is configured. '
          'Backup key relation: $fallbackKeyRelation. Primary: $primaryError',
        );
      }

      final retryKey = fallbackKey.isEmpty ? primaryKey : fallbackKey;
      final retryKeySource = retryKey == primaryKey ? 'primary' : 'backup';

      debugPrint(
        'Gemini primary request failed, retrying with '
        '$retryKeySource key and $fallbackModel '
        '(key relation: $fallbackKeyRelation): $primaryError',
      );
      try {
        final result = await _geminiGenerateContent(
          client: client,
          messages: messages,
          apiKeyOverride: retryKey,
          modelOverride: fallbackModel,
        );
        return _withAiRequestMetadata(
          result,
          keySource: retryKeySource,
          modelId: _normalizeGeminiModel(fallbackModel),
          modelSource: fallbackModel == primaryModel ? 'primary' : 'backup',
          keyRelation: fallbackKeyRelation,
        );
      } catch (backupError) {
        if (_isCancelledRequest(requestId, client, backupError)) {
          rethrow;
        }
        throw Exception(
          'Gemini backup was attempted but also failed. Backup: $backupError Primary: $primaryError',
        );
      }
    }
  }

  Map<String, dynamic> _withAiRequestMetadata(
    Map<String, dynamic> result, {
    required String keySource,
    required String modelId,
    required String modelSource,
    String? keyRelation,
  }) {
    final resultWithMetadata = <String, dynamic>{
      ...result,
      '_ai_provider': provider.id,
      '_ai_key_source': keySource,
      '_ai_model': modelId,
      '_ai_model_source': modelSource,
    };
    if (keyRelation != null) {
      resultWithMetadata['_ai_key_relation'] = keyRelation;
    }
    return resultWithMetadata;
  }

  Map<String, dynamic> _geminiSystemInstruction(
    List<Map<String, dynamic>> messages,
  ) {
    final systemText = messages
        .where((message) => message['role'] == 'system')
        .map((message) => message['content']?.toString().trim() ?? '')
        .where((content) => content.isNotEmpty)
        .join('\n\n');

    if (systemText.isEmpty) return const {};
    return {
      'system_instruction': {
        'parts': [
          {'text': systemText},
        ],
      },
    };
  }

  List<Map<String, dynamic>> _geminiContents(
    List<Map<String, dynamic>> messages,
  ) {
    return messages
        .where((message) => message['role'] != 'system')
        .map((message) {
          final parts = _geminiParts(message['content']);
          if (parts.isEmpty) return null;
          return {
            'role': message['role'] == 'assistant' ? 'model' : 'user',
            'parts': parts,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  List<Map<String, dynamic>> _geminiParts(dynamic content) {
    if (content is String) {
      final trimmed = content.trim();
      return trimmed.isEmpty
          ? const []
          : [
              {'text': trimmed},
            ];
    }

    if (content is! List) return const [];

    final parts = <Map<String, dynamic>>[];
    for (final item in content) {
      if (item is! Map) continue;
      final itemMap = Map<String, dynamic>.from(item);
      switch (itemMap['type']) {
        case 'text':
          final text = itemMap['text']?.toString().trim();
          if (text != null && text.isNotEmpty) {
            parts.add({'text': text});
          }
          break;
        case 'image_url':
          final imageUrl = itemMap['image_url'];
          if (imageUrl is! Map) break;
          final url = imageUrl['url']?.toString();
          final inlineData = _inlineDataFromDataUrl(url);
          if (inlineData != null) {
            parts.add({'inline_data': inlineData});
          }
          break;
      }
    }
    return parts;
  }

  Map<String, dynamic>? _inlineDataFromDataUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final commaIndex = url.indexOf(',');
    if (!url.startsWith('data:') || commaIndex <= 0) return null;

    final metadata = url.substring('data:'.length, commaIndex);
    final mimeType = metadata.split(';').first;
    final data = url.substring(commaIndex + 1);
    if (mimeType.isEmpty || data.isEmpty) return null;

    return {'mime_type': mimeType, 'data': data};
  }

  String _geminiText(Map<String, dynamic> data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final first = candidates.first;
    if (first is! Map) return '';
    final content = first['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';

    return parts
        .whereType<Map>()
        .map((part) => part['text']?.toString() ?? '')
        .where((text) => text.isNotEmpty)
        .join();
  }

  /// Analyzes food from text description or base64 image
  /// [requestId] is optional. If provided, allows cancellation of the request.
  /// [modelOverride] is optional. If provided, uses this model instead of the default.
  Future<Map<String, dynamic>> analyzeFood({
    String? textDescription,
    String? base64Image,
    List<String>? base64Images,
    String? requestId,
    String? modelOverride,
  }) async {
    return _chatCompletion(
      messages: _foodMessages(
        textDescription: textDescription,
        base64Image: base64Image,
        base64Images: base64Images,
      ),
      modelOverride: modelOverride,
      requestId: requestId,
    );
  }

  Future<Map<String, dynamic>> correctFoodEntry({
    required String correctionMessage,
    required String currentEntryJson,
    required String previousAiJson,
    required String previousReasoning,
    required String imageMetadataJson,
    List<String>? base64Images,
    String? requestId,
    String? modelOverride,
  }) async {
    return _chatCompletion(
      messages: _foodCorrectionMessages(
        correctionMessage: correctionMessage,
        currentEntryJson: currentEntryJson,
        previousAiJson: previousAiJson,
        previousReasoning: previousReasoning,
        imageMetadataJson: imageMetadataJson,
        base64Images: base64Images,
      ),
      modelOverride: modelOverride,
      requestId: requestId,
    );
  }

  Future<Map<String, dynamic>> analyzeExercise({
    required String textDescription,
    UserProfile? userProfile,
    String? requestId,
    String? modelOverride,
  }) async {
    return _chatCompletion(
      messages: _exerciseMessages(
        textDescription: textDescription,
        userProfile: userProfile,
      ),
      modelOverride: modelOverride,
      requestId: requestId,
    );
  }

  void cancelRequest(String requestId) {
    if (_activeRequests.containsKey(requestId)) {
      _activeRequests[requestId]?.close();
      _activeRequests.remove(requestId);
    }
  }

  String _extractJson(String content) {
    if (content.contains('```json')) {
      final startIndex = content.indexOf('```json') + 7;
      final endIndex = content.lastIndexOf('```');
      if (endIndex > startIndex) {
        return content.substring(startIndex, endIndex).trim();
      }
    } else if (content.contains('```')) {
      final startIndex = content.indexOf('```') + 3;
      final endIndex = content.lastIndexOf('```');
      if (endIndex > startIndex) {
        return content.substring(startIndex, endIndex).trim();
      }
    }
    return content.trim();
  }

  List<String> _mergedBase64Images(
    String? base64Image,
    List<String>? base64Images,
  ) {
    final images = <String>[];
    final seen = <String>{};

    void add(String? value) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty || !seen.add(trimmed)) return;
      images.add(trimmed);
    }

    add(base64Image);
    if (base64Images != null) {
      for (final image in base64Images) {
        add(image);
      }
    }
    return images;
  }
}

int _compareGeminiModels(
  GeminiModelDescriptor left,
  GeminiModelDescriptor right,
) {
  final priority = _geminiModelPriority(left.id).compareTo(
    _geminiModelPriority(right.id),
  );
  if (priority != 0) return priority;
  return left.name.toLowerCase().compareTo(right.name.toLowerCase());
}

int _geminiModelPriority(String id) {
  if (id.startsWith('gemini-3.1')) return 0;
  if (id.startsWith('gemini-3')) return 1;
  if (id.startsWith('gemini-2.5')) return 2;
  if (id.startsWith('gemini-2')) return 3;
  return 4;
}

String _normalizeGeminiModel(String model) {
  return model.startsWith('models/') ? model.substring('models/'.length) : model;
}

String _titleFromModelId(String id) {
  return id
      .split('-')
      .where((part) => part.isNotEmpty)
      .map((part) {
        if (part.length <= 2) return part.toUpperCase();
        return part.substring(0, 1).toUpperCase() + part.substring(1);
      })
      .join(' ');
}

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}
