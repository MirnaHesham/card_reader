import '../services/image_loader.dart';
import 'card_data.dart';

enum CardStatus { pending, extracting, done, error }

/// One card (one PDF page or one image) and everything known about it.
class CardEntry {
  CardEntry(this.card);

  final LoadedCard card;
  Map<String, String> values = {for (final k in allFieldKeys) k: ''};
  Set<String> uncertain = {};
  String raw = '';
  Duration? elapsed;
  String? model;
  CardStatus status = CardStatus.pending;
  String? error;

  /// Extracted, but the model was unsure or a value failed a sanity check.
  bool get needsReview =>
      status == CardStatus.done && (uncertain.isNotEmpty || validateCard(values).isNotEmpty);

  Map<String, dynamic> toJson() => {
        'source': card.label,
        ...values,
        'needs_review': {...uncertain, ...validateCard(values).keys}.toList(),
      };
}
