import 'dart:convert';
import 'package:http/http.dart' as http;

class WebhookService {
  Future<void> send({
    required String webhookUrl,
    required String bearerToken,
    required Map<String, dynamic> payload,
  }) async {
    final uri = Uri.parse(webhookUrl.trim());

    if (uri.scheme != 'https') {
      throw ArgumentError('Webhook URL must use HTTPS.');
    }

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (bearerToken.trim().isNotEmpty)
              'Authorization': 'Bearer ${bearerToken.trim()}',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Webhook failed: HTTP ${response.statusCode}\n${response.body}',
      );
    }
  }
}
