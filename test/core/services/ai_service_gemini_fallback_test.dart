import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nutrinutri/core/domain/ai_provider.dart';
import 'package:nutrinutri/core/services/ai_service.dart';

void main() {
  test('Gemini retries backup key and backup model after primary API error', () async {
    final requests = <Uri>[];
    Future<http.Response> handler(http.Request request) async {
      requests.add(request.url);
      final model = request.url.pathSegments
          .firstWhere((segment) => segment.endsWith(':generateContent'))
          .replaceFirst(':generateContent', '');
      final key = request.url.queryParameters['key'];

      if (model == 'gemini-3.1-pro-preview') {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 403,
              'message': 'Primary model is not available for this key',
            },
          }),
          403,
        );
      }

      expect(model, 'gemini-3-flash-preview');
      expect(key, 'backup-key');
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': jsonEncode({
                      'food_name': 'Plain idli',
                      'estimated_quantity': '1 idli',
                      'reasoning': 'Estimated as one plain idli.',
                      'metrics': {
                        'calories': 60,
                        'carbs': 12,
                        'sugars': 0,
                        'fats': 1,
                        'saturated_fats': 0,
                        'protein': 2,
                        'fiber': 1,
                        'sodium': 100,
                        'caffeine': 0,
                        'water': 0,
                      },
                      'icon': 'rice_bowl',
                    }),
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    }

    final service = AIService(
      apiKey: 'primary-key',
      backupApiKey: 'backup-key',
      model: 'gemini-3.1-pro-preview',
      backupModel: 'gemini-3-flash-preview',
      provider: AIProvider.gemini,
      clientFactory: () => MockClient(handler),
    );

    final result = await service.analyzeFood(textDescription: 'one plain idli');

    expect(requests, hasLength(2));
    expect(result['_ai_provider'], AIProvider.gemini.id);
    expect(result['_ai_key_source'], 'backup');
    expect(result['_ai_key_relation'], 'different_from_primary');
    expect(result['_ai_model_source'], 'backup');
    expect(result['_ai_model'], 'gemini-3-flash-preview');
    expect(result['metrics'], isA<Map>());
  });

  test('Gemini retries backup key and backup model after primary 429', () async {
    final requests = <Uri>[];
    Future<http.Response> handler(http.Request request) async {
      requests.add(request.url);
      final model = request.url.pathSegments
          .firstWhere((segment) => segment.endsWith(':generateContent'))
          .replaceFirst(':generateContent', '');
      final key = request.url.queryParameters['key'];

      if (model == 'gemini-3.1-pro-preview') {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 429,
              'message': 'Resource exhausted. Please try again later.',
              'status': 'RESOURCE_EXHAUSTED',
            },
          }),
          429,
        );
      }

      expect(model, 'gemini-3-flash-preview');
      expect(key, 'backup-key');
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': jsonEncode({
                      'food_name': 'Curd rice',
                      'estimated_quantity': '1 bowl',
                      'reasoning':
                          'Estimated as one standard bowl of curd rice with typical rice, curd, and light tempering.',
                      'metrics': {
                        'calories': 250,
                        'carbs': 38,
                        'sugars': 4,
                        'fats': 7,
                        'saturated_fats': 3,
                        'protein': 8,
                        'fiber': 1,
                        'sodium': 300,
                        'caffeine': 0,
                        'water': 0,
                      },
                      'icon': 'rice_bowl',
                    }),
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    }

    final service = AIService(
      apiKey: 'primary-key',
      backupApiKey: 'backup-key',
      model: 'gemini-3.1-pro-preview',
      backupModel: 'gemini-3-flash-preview',
      provider: AIProvider.gemini,
      clientFactory: () => MockClient(handler),
    );

    final result = await service.analyzeFood(textDescription: 'one curd rice');

    expect(requests, hasLength(2));
    expect(requests.first.path, contains('gemini-3.1-pro-preview'));
    expect(requests.last.path, contains('gemini-3-flash-preview'));
    expect(result['_ai_provider'], AIProvider.gemini.id);
    expect(result['_ai_key_source'], 'backup');
    expect(result['_ai_key_relation'], 'different_from_primary');
    expect(result['_ai_model_source'], 'backup');
    expect(result['_ai_model'], 'gemini-3-flash-preview');
    expect(result['food_name'], 'Curd rice');
  });

  test('Gemini falls back to backup model and optional backup key', () async {
    final primaryKey = Platform.environment['NUTRINUTRI_GEMINI_TEST_KEY'];
    if (primaryKey == null || primaryKey.trim().isEmpty) {
      return;
    }

    final backupKey =
        Platform.environment['NUTRINUTRI_GEMINI_BACKUP_TEST_KEY'] ?? primaryKey;

    final service = AIService(
      apiKey: primaryKey,
      backupApiKey: backupKey,
      model: 'gemini-3.1-pro-preview',
      backupModel: 'gemini-3-flash-preview',
      provider: AIProvider.gemini,
    );

    final result = await service.analyzeFood(
      textDescription: 'one plain idli',
      requestId: 'gemini-fallback-test',
    );

    expect(result['_ai_provider'], AIProvider.gemini.id);
    expect(result['_ai_model_source'], 'backup');
    expect(result['_ai_model'], 'gemini-3-flash-preview');
    expect(
      result['_ai_key_source'],
      backupKey.trim() == primaryKey.trim() ? 'primary' : 'backup',
    );
    expect(result['metrics'], isA<Map>());
  });
}
