import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/card_data.dart';

class OllamaException implements Exception {
  OllamaException(this.message, {this.fatal = false});
  final String message;

  /// True when every following card would fail too (Ollama down, wrong model),
  /// so a batch run should stop instead of repeating the same error.
  final bool fatal;
  @override
  String toString() => message;
}

class ExtractionResult {
  ExtractionResult({
    required this.fields,
    required this.uncertainFields,
    required this.rawResponse,
    required this.elapsed,
  });
  final Map<String, String> fields;
  final Set<String> uncertainFields;
  final String rawResponse;
  final Duration elapsed;
}

const _systemPrompt = '''
You are a careful data-entry assistant. You read scanned paper inquiry cards from
The American University in Cairo (AUC) that people filled in BY HAND, and you
transcribe the handwritten answers into JSON. You never invent information.
''';

const _userPrompt = '''
This image is a filled-in AUC inquiry card. Printed labels are in a typeface;
the answers are HANDWRITTEN in pen, usually on the line just ABOVE or to the
RIGHT of each printed label. Extract only the handwritten answers.

Card layout (top to bottom):
1. "Male" / "Female" checkboxes -> gender. A box counts as selected if it has a
   tick, cross, fill or scribble on or touching it. If none is marked, use "".
2. "Date of birth: __/__/__ (DD/MM/YY)" -> date_of_birth, written as DD/MM/YYYY.
   Two-digit years: 00-30 means 20xx, otherwise 19xx.
3. "Nationality:" -> nationality (e.g. Egyptian, Jordanian). Write the full
   word if the writing is clearly an abbreviation or a country name.
4. One handwritten line above the labels "First name", "Middle name",
   "Family name" -> first_name, middle_name, family_name, split by position.
5. Handwritten line under "School name or university name:" holding the school
   name, then a City and a Country above the printed "City" / "Country"
   labels -> school_name, city, country. Expand obvious abbreviations only if
   certain (e.g. "Sch." -> "School", "Lang" -> "Language"). If only one place
   name is written, put it in city or country by its meaning (Cairo is a city,
   Egypt is a country) rather than by position.
6. "School certificate:" checkboxes: American, IB, IGCSE, German Abitur,
   French Bac, Canadian, Thanaweya Amma, STEM, Other -> school_certificate.
   Pick the ONE box that is marked; a tick may overlap the box edge or the
   first letter of its label. If "Other" is marked, put the written text in
   other_certificate.
7. "When will you graduate? (YY)" -> graduation_year as 4 digits (e.g. 2026).
8. "Mobile number:" -> mobile_number. Read it digit by digit; digits only, no
   spaces. Egyptian mobile numbers are normally 11 digits starting with 010,
   011, 012 or 015. If a digit is overwritten or crossed out, use the final
   intended digit.
9. "Email address:" -> email, lower case, no spaces. Transcribe exactly what is
   written, even if the domain looks unusual; do not "correct" it.

Rules:
- If a field is blank, use "". Never guess content that is not on the card.
- Ignore printed text, logos, "Driven by Excellence" and the red footer.
- Put the key of every field you are not confident about into uncertain_fields.

Return only the JSON object.
''';

class OllamaService {
  OllamaService(String baseUrl) : _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final String _base;

  Uri _uri(String path) => Uri.parse('$_base$path');

  /// Lists the models installed in the local Ollama.
  Future<List<String>> listModels() async {
    final http.Response r;
    try {
      r = await http.get(_uri('/api/tags')).timeout(const Duration(seconds: 5));
    } catch (e) {
      throw OllamaException(
          'Cannot reach Ollama at $_base. Is it running? (`ollama serve`)\n$e');
    }
    if (r.statusCode != 200) {
      throw OllamaException('Ollama returned HTTP ${r.statusCode}: ${r.body}');
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final models = <String>[
      for (final m in (j['models'] as List? ?? const [])) (m as Map)['name'] as String,
    ]..sort();
    return models;
  }

  /// Returns the model's capabilities (e.g. ["completion", "vision"]),
  /// or null if this Ollama version does not report them.
  Future<List<String>?> capabilities(String model) async {
    try {
      final r = await http
          .post(_uri('/api/show'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'model': model}))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final caps = j['capabilities'];
      return caps is List ? caps.cast<String>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<ExtractionResult> extractCard({
    required String model,
    required List<int> imageJpeg,
    bool disableThinking = false,
  }) async {
    // A text-only model (qwen2.5, qwen3) would silently ignore the image and
    // hallucinate an answer, so refuse early.
    final caps = await capabilities(model);
    if (caps != null && !caps.contains('vision')) {
      throw OllamaException(
        '"$model" cannot read images. Use a vision model, e.g.\n'
        '  ollama pull qwen2.5vl:7b\n'
        '  ollama pull qwen3-vl:8b-instruct',
        fatal: true,
      );
    }

    final body = <String, dynamic>{
      'model': model,
      'stream': false,
      // Qwen3 thinking variants spend minutes reasoning; field OCR doesn't need it.
      if (disableThinking || (model.contains('qwen3') && !model.contains('instruct')))
        'think': false,
      'format': cardJsonSchema,
      'keep_alive': '15m',
      'options': {
        'temperature': 0,
        'num_ctx': 8192,
      },
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': _userPrompt,
          'images': [base64Encode(imageJpeg)],
        },
      ],
    };

    final sw = Stopwatch()..start();
    final http.Response r;
    try {
      r = await http
          .post(_uri('/api/chat'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw OllamaException('The model took longer than 10 minutes. Try a smaller model or image size.');
    } catch (e) {
      throw OllamaException('Cannot reach Ollama at $_base.\n$e', fatal: true);
    }
    sw.stop();

    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode != 200) {
      String msg = text;
      try {
        msg = (jsonDecode(text) as Map)['error']?.toString() ?? text;
      } catch (_) {}
      if (r.statusCode == 404 || msg.contains('not found')) {
        msg += '\nPull it first: ollama pull $model';
      }
      throw OllamaException('Ollama error (HTTP ${r.statusCode}): $msg', fatal: true);
    }

    final j = jsonDecode(text) as Map<String, dynamic>;
    final content = ((j['message'] as Map?)?['content'] as String?) ?? '';
    final parsed = _parseJsonObject(content);

    final fields = <String, String>{
      for (final k in allFieldKeys) k: (parsed[k] ?? '').toString().trim(),
    };
    // Normalise values the UI relies on.
    if (!genderOptions.contains(fields['gender'])) fields['gender'] = '';
    if (!certificateOptions.contains(fields['school_certificate'])) {
      fields['school_certificate'] = '';
    }
    fields['email'] = fields['email']!.replaceAll(' ', '').toLowerCase();

    final uncertain = <String>{
      for (final u in (parsed['uncertain_fields'] as List? ?? const [])) u.toString(),
    };

    return ExtractionResult(
      fields: fields,
      uncertainFields: uncertain,
      rawResponse: content,
      elapsed: sw.elapsed,
    );
  }

  /// Tolerates <think> blocks and ```json fences in case the model ignores `format`.
  static Map<String, dynamic> _parseJsonObject(String s) {
    var t = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw OllamaException('Model did not return JSON:\n$s');
    }
    t = t.substring(start, end + 1);
    try {
      return jsonDecode(t) as Map<String, dynamic>;
    } catch (e) {
      throw OllamaException('Could not parse model JSON: $e\n$s');
    }
  }
}
