import 'dart:io';

import 'package:excel/excel.dart';

import '../models/card_data.dart';
import '../models/card_entry.dart';

/// (field key, column header, column width)
const _columns = <(String, String, double)>[
  ('first_name', 'First name', 16),
  ('middle_name', 'Middle name', 16),
  ('family_name', 'Family name', 16),
  ('gender', 'Gender', 9),
  ('date_of_birth', 'Date of birth', 13),
  ('nationality', 'Nationality', 14),
  ('school_name', 'School / university', 30),
  ('city', 'City', 12),
  ('country', 'Country', 12),
  ('school_certificate', 'Certificate', 16),
  ('other_certificate', 'Other certificate', 16),
  ('graduation_year', 'Graduation year', 11),
  ('mobile_number', 'Mobile', 15),
  ('email', 'Email', 30),
];

/// Writes every extracted card to an .xlsx file at [path] (overwriting it).
///
/// One row per card. Cells the model was unsure about, or that failed a
/// sanity check, are filled orange, and listed in the "Needs review" column.
/// All values are stored as text so phone numbers keep their leading 0.
Future<void> writeCardsExcel(List<CardEntry> entries, String path) async {
  final excel = Excel.createExcel();
  final defaultSheet = excel.tables.keys.first;
  excel.rename(defaultSheet, 'Cards');
  final sheet = excel['Cards'];

  final headerStyle = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
    backgroundColorHex: ExcelColor.fromHexString('#00205B'),
  );
  final reviewStyle = CellStyle(backgroundColorHex: ExcelColor.fromHexString('#FFD8A8'));

  final headers = ['#', 'Source', for (final c in _columns) c.$2, 'Needs review', 'Model'];
  for (var c = 0; c < headers.length; c++) {
    sheet.updateCell(
      CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
      TextCellValue(headers[c]),
      cellStyle: headerStyle,
    );
  }

  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final row = i + 1;
    final flagged = {...e.uncertain, ...validateCard(e.values).keys};

    void put(int col, CellValue value, {bool review = false}) => sheet.updateCell(
          CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
          value,
          cellStyle: review ? reviewStyle : null,
        );

    put(0, IntCellValue(i + 1));
    put(1, TextCellValue(e.card.label));
    for (var c = 0; c < _columns.length; c++) {
      final key = _columns[c].$1;
      put(2 + c, TextCellValue(e.values[key] ?? ''), review: flagged.contains(key));
    }
    final labels = {
      for (final f in textFields) f.key: f.label,
      'gender': 'Gender',
      'school_certificate': 'Certificate',
    };
    put(2 + _columns.length,
        TextCellValue(flagged.map((k) => labels[k] ?? k).join(', ')),
        review: flagged.isNotEmpty);
    put(3 + _columns.length, TextCellValue(e.model ?? ''));
  }

  sheet.setColumnWidth(0, 5);
  sheet.setColumnWidth(1, 26);
  for (var c = 0; c < _columns.length; c++) {
    sheet.setColumnWidth(2 + c, _columns[c].$3);
  }
  sheet.setColumnWidth(2 + _columns.length, 28);
  sheet.setColumnWidth(3 + _columns.length, 16);

  final bytes = excel.encode();
  if (bytes == null) throw const FileSystemException('Could not encode the Excel file');
  await File(path).writeAsBytes(bytes, flush: true);
}
