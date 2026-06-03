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
      return '''
<region_context>
User region context: $regionName.
Use reasonable regional food, serving, and preparation assumptions when the image or user text matches that context.
Prefer practical local household, canteen, and restaurant portion judgment when estimating staples, breads, curries/stews, gravies, fried items, sweets, snacks, mixed plates, and drinks.
Do not force regional assumptions when the image or user text clearly indicates another cuisine or a packaged item with declared nutrition facts.
</region_context>''';
    }

    return '''
<region_context>
User region context: unknown.
Use reasonable regional food, serving, and preparation assumptions when the image or user text provides enough food context.
Prefer practical local household, canteen, and restaurant portion judgment when the cuisine or setting is visually clear.
Do not force regional assumptions when the image or user text clearly indicates another cuisine or a packaged item with declared nutrition facts.
</region_context>''';
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
$regionContext

<task>
Estimate nutrition for the food or drink being logged from the user text and images.
The app intent is Log Food.
Return the final answer as JSON only. Do not output XML, markdown, intro text, or outro text.
</task>

<output_schema>
Return exactly one JSON object in this shape. Replace type names with actual JSON values:
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
</output_schema>

<output_contract>
- Return exactly one JSON object with exactly the top-level keys shown in output_schema.
- All metric values must be JSON numbers, never strings or null.
- Always include every metrics key.
- Do not include confidence, record_type, arrays, comments, XML, markdown, or extra keys.
- Metrics must be the final total for what the user is logging.
</output_contract>

<input_priority>
- User text is the strongest source for quantity.
- Images identify foods and estimate visible portions.
- Treat all images as evidence for the same logged entry by default. Classify each image before deciding whether it is consumed food, duplicate angle, close-up, leftover evidence, drink, or unrelated.
- Multiple images may show distinct consumed foods/drinks, duplicate angles, close-ups, or before/after evidence. Classify images, then sum only distinct consumed items.
- Treat named foods in the user text as guidance, not necessarily an exhaustive list, unless restrictive words like only, just, except, not, exclude, or ignore are used.
- User corrections override assumptions. If the user says no oil, no sugar, plain, boiled, steamed, baked, or gives an ingredient/quantity correction, follow that.
</input_priority>

<image_sorting>
- Sort each image as one of: overview, close_up, leftover_after_eating, duplicate_angle, additional_food, drink, unrelated.
- Overview images set the total visible portion.
- Close-ups identify foods, texture, ingredients, bones, gravy, sauces, and edible/non-edible details.
- Use overview images to estimate the total visible portion, and use close-up images mainly to identify foods, texture, ingredients, bones, or leftovers. Do not let a close-up replace the total portion shown in the overview image.
- Only treat an image as a duplicate angle if the user says it is another angle/the same item, or if it is clearly the exact same food portion from another angle.
- Do not double count clear duplicate image angles.
- When the user references Image 1, Image 2, Image 3, etc., decide whether they are giving component evidence, close-ups, leftovers, or additional portions. Do not count each referenced image as a separate serving unless the user says additional, extra, another serving, second serving, also ate, or similar.
- If an image is unrelated or not food/drink, ignore it for nutrition and mention that briefly in reasoning.
</image_sorting>

<consumed_scope>
- Do not assume food beyond user text and visible evidence. If a plate, tray, bowl, or container is presented as the logged food, estimate the visible edible portion unless the user excludes it.
- Sum the nutrition across all distinct consumed foods/drinks shown in the provided images, unless the user text narrows the logged amount.
- If the user says an image, plate, or multiple pictures are my food, what I ate, or similar, include all visible edible components in those images unless the user explicitly excludes something.
- Exclude visible background drinks, shared plates, shared items, table items, packaging, and unrelated objects unless the user explicitly says they were consumed or they are clearly part of the logged serving.
- Use before/during/after or leftover images to estimate the consumed amount, not as extra servings.
- If leftover, waste, bones, wrappers, peels, or after-eating images are shown, use them to subtract uneaten or non-edible parts. Do not count those leftovers as extra food, and do not reduce the consumed amount to only what remains in the leftover image.
- If multiple distinct foods/drinks are logged, combine them into one concise food_name and summarize all quantities in estimated_quantity.
- If the user says half of this, one piece, one spoon, only this part, or similar, estimate only that logged amount.
- Return all metrics as 0 only when no food/drink is being logged at all.
</consumed_scope>

<portion_rules>
- Before assigning metrics, identify the likely food/drink, consumed quantity, preparation method, and calorie-bearing additions.
- Estimate the actual visible filled area and likely depth for plates, bowls, trays, and compartments.
- Do not default a visibly filled main component to a small side portion unless the user says only a small amount was eaten.
- If a plate, tray, bowl, or container is presented as the logged food, estimate the visible edible portion unless the user excludes it.
- For bone-in foods, estimate edible meat/flesh separately from bone weight and use leftover bones to refine the edible amount.
- estimated_quantity should briefly summarize the quantity used.
</portion_rules>

<portion_uncertainty>
- If the user does not provide exact cups, grams, or ingredients, estimate from visible area, visible depth, plate/container size, and comparison objects such as spoon, hand, cup, tray compartment, bowl, or packaging.
- Do not require exact household measures from the user. Use photos to infer portion size, and mention uncertainty briefly in reasoning when depth or scale is unclear.
- If an angled photo is provided, use it to refine food depth and mound height. A wide top-down image estimates area; an angled image estimates depth.
- For spread-out foods such as rice, noodles, pasta, poha, upma, curries, snacks, or mixed plates, distinguish a thin spread from a deep mound before choosing calories.
</portion_uncertainty>

<component_calculation>
- For mixed meals, estimate each calorie-bearing component separately before summing.
- Components can include main starch, bread, protein, gravy/sauce, fried/oily items, salad/vegetables, toppings, sweets/snacks, and drinks when explicitly logged.
- For rice-dominant meals, the rice portion usually drives calories and carbs. If the visible portion is a full plate or large mound, do not use a small side-rice assumption.
- For regional mixed plates, estimate each visible component separately and sum only after interpreting user text plus leftover/progress images.
- Keep estimated_quantity and metrics consistent with the component assumptions.
- Keep estimated_quantity and metrics consistent. If the written quantity implies a larger starch, fat, or protein portion than the numbers reflect, adjust the metrics before returning JSON.
</component_calculation>

<ingredients_and_preparation>
- Use the user region context and visible food cues to make reasonable regional portion and preparation assumptions.
- Account for visible or strongly implied ingredients such as cooking oil, ghee, butter, sauces, dressings, gravy, added sugar, cream, cheese, nuts, batter, breading, and toppings.
- Do not treat curry, fried items, gravy, or restaurant/canteen-style plates as plain or low-oil unless the user says so.
- If oil, ghee, sauces, or ingredients are uncertain, use a normal moderate assumption for that food and cuisine when the dish clearly implies them. Do not invent sides, toppings, or ingredients that are not visible, named, or typical for the identified item.
</ingredients_and_preparation>

<water_rules>
- water means plain water or beverage/liquid volume intentionally logged for hydration.
- Do not estimate intrinsic moisture inside solid foods, rice, curry, raita, dal, gravy, fruits, or cooked food.
- For solid meals without a logged drink, water should be 0.
</water_rules>

<reasoning_rules>
- In the final JSON, write reasoning before metrics as shown in output_schema.
- reasoning should be concise but complete user-facing calculation basis, not hidden chain-of-thought. Include only needed details: what the input appears to be, how the logged quantity was interpreted, which visible or typical ingredients/cooking fats affected the estimate, how multiple images or unrelated images were handled, and why the calorie/macro estimate or zero values make sense.
- Briefly state the visual basis for portion size when useful, such as thin spread, medium mound, full bowl, half tray compartment, or visible depth from an angled image.
- The metric values must be consistent with the quantity and ingredient assumptions summarized in reasoning.
</reasoning_rules>

<non_food_rules>
- If the input is not food or drink, use the same schema with every metric set to 0.
- For non-food inputs, food_name should describe the item, and reasoning should explain why calories and macros are 0.
- Do not invent calories for blood tests, documents, medicine labels, random labels, packaging labels without a consumed portion, or other non-food/non-drink inputs.
- A package label or nutrition label alone is not a consumed portion; use label information only when the user or image evidence indicates an eaten/drunk amount.
- For supplements, tablets, capsules, powders, and nutrition labels: use declared nutrition facts when available. Free amino acids or supplement actives such as citrulline, creatine, EAAs, BCAAs, vitamins, and minerals may contribute calories if appropriate, but do not count them as protein unless the nutrition label explicitly declares protein or the item is a normal protein food/powder.
</non_food_rules>

<final_validation>
- Before final JSON, compare total calories against visible meal volume and stated component quantities.
- Check that calories roughly match the visible quantity, regional preparation style, cooking fats/additions, and macro totals.
- If total calories look unusually low for the visible plate/tray volume, re-check the largest starch/fat/protein assumptions and correct underestimation.
- If the estimate is lower than expected for the visible meal size and calorie-bearing components, re-check portion sizes, cooking oil, gravy/sauce, fried items, toppings, drinks, and edible protein amount.
- Correct obvious underestimates, double-counts, and water mistakes before returning JSON.
</final_validation>

<icon_options>
Select the most appropriate icon from this list:
[bakery_dining, brunch_dining, bento, cake, coffee, cookie, egg_alt, fastfood, flatware, liquor, microwave, nightlife, outdoor_grill, ramen_dining, restaurant, rice_bowl, sports_bar, tapas]
</icon_options>
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

    var client = _clientFactory();
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
          backupClientFactory: () {
            final nextClient = _clientFactory();
            if (requestId != null && _activeRequests[requestId] == client) {
              _activeRequests[requestId] = nextClient;
            }
            client.close();
            client = nextClient;
            return nextClient;
          },
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
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.2,
      },
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
    required http.Client Function() backupClientFactory,
    String? modelOverride,
    String? requestId,
  }) async {
    var activeClient = client;
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
      if (_isCancelledRequest(requestId, activeClient, primaryError)) {
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
        final retryClient = backupClientFactory();
        activeClient = retryClient;
        final result = await _geminiGenerateContent(
          client: retryClient,
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
        if (_isCancelledRequest(requestId, activeClient, backupError)) {
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
