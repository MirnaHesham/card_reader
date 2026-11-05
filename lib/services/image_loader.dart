import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';

class LoadedCard {
  LoadedCard({
    required this.fileName,
    required this.jpegBytes,
    required this.width,
    required this.height,
    this.page,
    this.pageCount,
  });

  final String fileName;

  /// 1-based page number when the card came from a multi-page PDF.
  final int? page;
  final int? pageCount;

  /// The image shown in the UI and sent to the model (same bytes, so what you
  /// see is exactly what the model saw).
  final Uint8List jpegBytes;
  final int width;
  final int height;

  String get label => page == null || (pageCount ?? 1) <= 1 ? fileName : '$fileName · p$page';
}

String baseName(String path) => path.split(Platform.pathSeparator).last;

/// Loads every page of a PDF (one card per page) or a single image file.
/// Each page is rotation-corrected and scaled so its longest side is at most
/// [maxSide] px — ~1600 px keeps handwriting legible without making the model slow.
///
/// [onPage] is called after each page is ready, for progress display.
Future<List<LoadedCard>> loadCards(
  String path, {
  int maxSide = 1600,
  void Function(int pageNumber)? onPage,
}) async {
  final bytes = await File(path).readAsBytes();
  final name = baseName(path);

  if (!name.toLowerCase().endsWith('.pdf')) {
    final p = await Isolate.run(() => _prepare(bytes, maxSide));
    onPage?.call(1);
    return [LoadedCard(fileName: name, jpegBytes: p.$1, width: p.$2, height: p.$3)];
  }

  // Rasterise page by page so memory stays low on long scans.
  final pages = <(Uint8List, int, int)>[];
  await for (final raster in Printing.raster(bytes, dpi: 200)) {
    final png = await raster.toPng();
    pages.add(await Isolate.run(() => _prepare(png, maxSide)));
    onPage?.call(pages.length);
  }
  if (pages.isEmpty) throw const FormatException('The PDF has no pages');

  return [
    for (var i = 0; i < pages.length; i++)
      LoadedCard(
        fileName: name,
        page: i + 1,
        pageCount: pages.length,
        jpegBytes: pages[i].$1,
        width: pages[i].$2,
        height: pages[i].$3,
      ),
  ];
}

(Uint8List, int, int) _prepare(Uint8List bytes, int maxSide) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unsupported or corrupt image file');
  }
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  if (longest > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  return (img.encodeJpg(image, quality: 92), image.width, image.height);
}
