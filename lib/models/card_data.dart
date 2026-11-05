/// Field definitions for the AUC inquiry card, plus validation helpers.
library;

class CardField {
  const CardField(this.key, this.label, {this.hint});
  final String key;
  final String label;
  final String? hint;
}

const genderOptions = ['', 'Male', 'Female'];

const certificateOptions = [
  '',
  'American',
  'IB',
  'IGCSE',
  'German Abitur',
  'French Bac',
  'Canadian',
  'Thanaweya Amma',
  'STEM',
  'Other',
];

/// Text fields, in the order they appear on the card.
/// `gender` and `school_certificate` are dropdowns and handled separately.
const textFields = <CardField>[
  CardField('date_of_birth', 'Date of birth', hint: 'DD/MM/YYYY'),
  CardField('nationality', 'Nationality'),
  CardField('first_name', 'First name'),
  CardField('middle_name', 'Middle name'),
  CardField('family_name', 'Family name'),
  CardField('school_name', 'School / university name'),
  CardField('city', 'City'),
  CardField('country', 'Country'),
  CardField('other_certificate', 'Other certificate'),
  CardField('graduation_year', 'Graduation year', hint: 'YYYY'),
  CardField('mobile_number', 'Mobile number'),
  CardField('email', 'Email address'),
];

const allFieldKeys = [
  'gender',
  'date_of_birth',
  'nationality',
  'first_name',
  'middle_name',
  'family_name',
  'school_name',
  'city',
  'country',
  'school_certificate',
  'other_certificate',
  'graduation_year',
  'mobile_number',
  'email',
];

/// JSON schema passed to Ollama's `format` parameter so the model
/// is forced to return exactly these keys.
final Map<String, dynamic> cardJsonSchema = {
  'type': 'object',
  'properties': {
    'gender': {'type': 'string', 'enum': genderOptions},
    'date_of_birth': {'type': 'string'},
    'nationality': {'type': 'string'},
    'first_name': {'type': 'string'},
    'middle_name': {'type': 'string'},
    'family_name': {'type': 'string'},
    'school_name': {'type': 'string'},
    'city': {'type': 'string'},
    'country': {'type': 'string'},
    'school_certificate': {'type': 'string', 'enum': certificateOptions},
    'other_certificate': {'type': 'string'},
    'graduation_year': {'type': 'string'},
    'mobile_number': {'type': 'string'},
    'email': {'type': 'string'},
    'uncertain_fields': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
  'required': [...allFieldKeys, 'uncertain_fields'],
};

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$');
final _egyptMobileRe = RegExp(r'^(?:\+?20|0020)?0?1[0125]\d{8}$');
const _freeMailProviders = {'gmail', 'yahoo', 'hotmail', 'outlook', 'icloud', 'live'};

/// Returns a map of field key -> warning message for values that look wrong.
/// These are hints for the person reviewing the card, not hard errors.
Map<String, String> validateCard(Map<String, String> v) {
  final w = <String, String>{};

  final dob = v['date_of_birth'] ?? '';
  if (dob.isNotEmpty) {
    final m = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})$').firstMatch(dob);
    if (m == null) {
      w['date_of_birth'] = 'Expected DD/MM/YYYY';
    } else {
      final d = int.parse(m[1]!), mo = int.parse(m[2]!);
      var y = int.parse(m[3]!);
      if (y < 100) y += 2000;
      final dt = DateTime(y, mo, d);
      final now = DateTime.now();
      if (mo < 1 || mo > 12 || dt.day != d || dt.month != mo) {
        w['date_of_birth'] = 'Not a real date — check day/month';
      } else if (y < 1940 || y > now.year - 10) {
        w['date_of_birth'] = 'Unusual birth year';
      }
    }
  }

  final grad = v['graduation_year'] ?? '';
  if (grad.isNotEmpty) {
    final y = int.tryParse(grad);
    if (y == null || grad.length != 4 || y < 1980 || y > DateTime.now().year + 10) {
      w['graduation_year'] = 'Expected a 4-digit year';
    }
  }

  final mobile = (v['mobile_number'] ?? '').replaceAll(RegExp(r'[\s\-()]'), '');
  if (mobile.isNotEmpty && !_egyptMobileRe.hasMatch(mobile)) {
    w['mobile_number'] = 'Egyptian mobiles are 11 digits starting 010/011/012/015';
  }

  final email = (v['email'] ?? '').trim();
  if (email.isNotEmpty) {
    if (!_emailRe.hasMatch(email)) {
      w['email'] = 'Does not look like a valid email';
    } else {
      final domain = email.split('@').last.toLowerCase();
      final parts = domain.split('.');
      if (_freeMailProviders.contains(parts.first) && parts.last != 'com') {
        w['email'] = 'Unusual domain for ${parts.first} — check the ending';
      }
    }
  }

  if (v['school_certificate'] == 'Other' && (v['other_certificate'] ?? '').isEmpty) {
    w['other_certificate'] = '"Other" is ticked but no certificate written';
  }

  return w;
}
