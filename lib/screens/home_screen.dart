import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/card_data.dart';
import '../models/card_entry.dart';
import '../services/image_loader.dart';
import '../services/ollama_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ---------------------------------------------------------------- settings
  String _ollamaUrl = 'http://localhost:11434';
  String? _model;
  int _maxSide = 1600;
  bool _disableThinking = false;

  List<String> _models = [];
  String? _modelsError;

  // ---------------------------------------------------------------- cards
  final List<CardEntry> _entries = [];
  int _selected = -1;
  CardEntry? get _current =>
      _selected >= 0 && _selected < _entries.length ? _entries[_selected] : null;

  String? _loadingMessage;
  String? _error;

  // ---------------------------------------------------------------- batch run
  bool _running = false;
  bool _stopRequested = false;
  int _runDone = 0;
  int _runTotal = 0;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  // ---------------------------------------------------------------- form
  final Map<String, TextEditingController> _ctrl = {
    for (final f in textFields) f.key: TextEditingController(),
  };
  bool _syncing = false; // true while we fill the form from a card
  Map<String, String> _warnings = {};

  @override
  void initState() {
    super.initState();
    for (final entry in _ctrl.entries) {
      entry.value.addListener(() {
        if (_syncing) return;
        final cur = _current;
        if (cur == null) return;
        cur.values[entry.key] = entry.value.text.trim();
        _revalidate();
      });
    }
    _refreshModels();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _revalidate() {
    final cur = _current;
    final w = cur == null ? <String, String>{} : validateCard(cur.values);
    if (w.toString() != _warnings.toString()) setState(() => _warnings = w);
  }

  /// Copies the selected card's values into the form fields.
  void _loadIntoForm() {
    final cur = _current;
    _syncing = true;
    for (final e in _ctrl.entries) {
      e.value.text = cur?.values[e.key] ?? '';
    }
    _syncing = false;
    _warnings = cur == null ? {} : validateCard(cur.values);
  }

  void _select(int i) {
    if (i < 0 || i >= _entries.length) return;
    _selected = i;
    _loadIntoForm();
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- models

  Future<void> _refreshModels() async {
    try {
      final models = await OllamaService(_ollamaUrl).listModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _modelsError =
            models.isEmpty ? 'No models installed. Run: ollama pull qwen2.5vl:7b' : null;
        if (_model == null || !models.contains(_model)) _model = _pickDefault(models);
      });
    } on OllamaException catch (e) {
      if (!mounted) return;
      setState(() {
        _models = [];
        _modelsError = e.message;
      });
    }
  }

  String? _pickDefault(List<String> models) {
    // Fast, direct-answer vision models first; plain qwen3-vl tags are the
    // slower "thinking" variant, so they come after qwen2.5vl.
    final prefs = <bool Function(String)>[
      (m) => m.contains('qwen3-vl') && m.contains('instruct'),
      (m) => m.contains('qwen2.5vl') || m.contains('qwen2.5-vl'),
      (m) => m.contains('qwen3-vl'),
      (m) => m.contains('vl') || m.contains('vision'),
    ];
    for (final p in prefs) {
      final hit = models.where(p);
      if (hit.isNotEmpty) return hit.first;
    }
    return models.isNotEmpty ? models.first : null;
  }

  // ---------------------------------------------------------------- files

  Future<void> _addFiles() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff'],
      allowMultiple: true,
      dialogTitle: 'Choose scanned cards (PDFs with one card per page, or images)',
    );
    final paths = res?.paths.whereType<String>().toList() ?? const <String>[];
    if (paths.isEmpty) return;

    setState(() {
      _error = null;
      _loadingMessage = 'Loading…';
    });

    final added = <CardEntry>[];
    final failures = <String>[];
    for (final path in paths) {
      final name = baseName(path);
      try {
        final cards = await loadCards(
          path,
          maxSide: _maxSide,
          onPage: (n) {
            if (mounted) setState(() => _loadingMessage = 'Loading $name — page $n…');
          },
        );
        added.addAll(cards.map(CardEntry.new));
      } catch (e) {
        failures.add('$name: $e');
      }
    }
    if (!mounted) return;

    final firstNew = _entries.length;
    _entries.addAll(added);
    if (added.isNotEmpty) {
      _selected = firstNew;
      _loadIntoForm();
    }
    setState(() {
      _loadingMessage = null;
      if (failures.isNotEmpty) _error = 'Could not open:\n${failures.join('\n')}';
    });
    if (added.isNotEmpty) {
      _snack('Added ${added.length} card${added.length == 1 ? '' : 's'}');
    }
  }

  void _remove(int i) {
    if (_running) return;
    _entries.removeAt(i);
    if (i < _selected || _selected >= _entries.length) _selected--;
    if (_selected < 0 && _entries.isNotEmpty) _selected = 0;
    _loadIntoForm();
    setState(() {});
  }

  Future<void> _clearAll() async {
    if (_entries.any((e) => e.status == CardStatus.done)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove all cards?'),
          content: const Text('Extracted results that you have not exported will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove all')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _entries.clear();
    _selected = -1;
    _loadIntoForm();
    setState(() => _error = null);
  }

  // ---------------------------------------------------------------- extraction

  Future<void> _runExtraction(List<CardEntry> targets) async {
    final model = _model;
    if (model == null || targets.isEmpty || _running) return;
    final service = OllamaService(_ollamaUrl);

    setState(() {
      _running = true;
      _stopRequested = false;
      _runDone = 0;
      _runTotal = targets.length;
      _elapsed = Duration.zero;
      _error = null;
    });
    final sw = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed = sw.elapsed);
    });

    try {
      for (final e in targets) {
        if (_stopRequested || !mounted) break;
        if (!_entries.contains(e)) continue;
        setState(() {
          e.status = CardStatus.extracting;
          e.error = null;
        });

        try {
          final r = await service.extractCard(
            model: model,
            imageJpeg: e.card.jpegBytes,
            disableThinking: _disableThinking,
          );
          e
            ..values = Map.of(r.fields)
            ..uncertain = r.uncertainFields
            ..raw = r.rawResponse
            ..elapsed = r.elapsed
            ..model = model
            ..status = CardStatus.done;
        } on OllamaException catch (err) {
          e
            ..status = CardStatus.error
            ..error = err.message;
          if (err.fatal) {
            // Every remaining card would fail the same way.
            _error = err.message;
            _stopRequested = true;
          }
        } catch (err) {
          e
            ..status = CardStatus.error
            ..error = 'Unexpected error: $err';
        }

        if (!mounted) return;
        if (identical(e, _current)) _loadIntoForm();
        setState(() => _runDone++);
      }
    } finally {
      _ticker?.cancel();
      sw.stop();
      if (mounted) {
        setState(() => _running = false);
        if (_runTotal > 1 && _error == null) {
          final review = targets.where((e) => e.needsReview).length;
          _snack('Finished $_runDone of $_runTotal in ${sw.elapsed.inSeconds}s'
              '${review > 0 ? ' — $review need review' : ''}');
        }
      }
    }
  }

  void _extractAll() =>
      _runExtraction(_entries.where((e) => e.status != CardStatus.done).toList());

  void _extractCurrent() {
    final cur = _current;
    if (cur != null) _runExtraction([cur]);
  }

  // ---------------------------------------------------------------- export

  List<CardEntry> get _doneEntries =>
      _entries.where((e) => e.status == CardStatus.done).toList();

  Future<void> _copyJson() async {
    final json =
        const JsonEncoder.withIndent('  ').convert([for (final e in _doneEntries) e.toJson()]);
    await Clipboard.setData(ClipboardData(text: json));
    _snack('Copied ${_doneEntries.length} card(s) as JSON');
  }

  Future<void> _exportCsv() async {
    final rows = _doneEntries;
    if (rows.isEmpty) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save results as CSV',
      fileName: 'cards.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return;

    String esc(Object? s) => '"${(s ?? '').toString().replaceAll('"', '""')}"';
    // The BOM makes Excel open the file as UTF-8 (needed for Arabic names).
    final buf = StringBuffer('﻿')
      ..writeln(['source', ...allFieldKeys, 'needs_review'].map(esc).join(','));
    for (final e in rows) {
      final j = e.toJson();
      buf.writeln([
        e.card.label,
        for (final k in allFieldKeys) e.values[k],
        (j['needs_review'] as List).join(' '),
      ].map(esc).join(','));
    }

    final out = path.toLowerCase().endsWith('.csv') ? path : '$path.csv';
    try {
      await File(out).writeAsString(buf.toString());
      _snack('Saved ${rows.length} card(s) to ${baseName(out)}');
    } catch (e) {
      setState(() => _error = 'Could not save CSV: $e');
    }
  }

  // ---------------------------------------------------------------- settings

  Future<void> _openSettings() async {
    final urlCtrl = TextEditingController(text: _ollamaUrl);
    var maxSide = _maxSide;
    var disableThinking = _disableThinking;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Settings'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(labelText: 'Ollama URL'),
                ),
                const SizedBox(height: 20),
                Text('Max image size sent to the model: $maxSide px'),
                Slider(
                  value: maxSide.toDouble(),
                  min: 1024,
                  max: 2560,
                  divisions: 6,
                  label: '$maxSide',
                  onChanged: (v) => setD(() => maxSide = v.round()),
                ),
                const Text(
                  'Larger = sharper handwriting but slower. Applies to cards added after the change.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Always disable thinking'),
                  subtitle: const Text(
                      'Already automatic for qwen3 models without "instruct" in the name.'),
                  value: disableThinking,
                  onChanged: (v) => setD(() => disableThinking = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == true) {
      setState(() {
        _ollamaUrl = urlCtrl.text.trim();
        _maxSide = maxSide;
        _disableThinking = disableThinking;
      });
      _refreshModels();
    }
    urlCtrl.dispose();
  }

  // ================================================================ UI

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Card Reader'),
        backgroundColor: scheme.primaryContainer,
        actions: [
          _modelPicker(),
          IconButton(
              tooltip: 'Refresh models', onPressed: _refreshModels, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          if (_running) LinearProgressIndicator(value: _runTotal == 0 ? null : _runDone / _runTotal),
          if (_error != null) _banner(_error!),
          if (_modelsError != null && _error == null) _banner(_modelsError!),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_entries.isNotEmpty) ...[
                  SizedBox(width: 190, child: _cardList()),
                  const VerticalDivider(width: 1),
                ],
                Expanded(flex: 6, child: _preview()),
                const VerticalDivider(width: 1),
                Expanded(flex: 4, child: _resultsPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelPicker() {
    if (_models.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DropdownButton<String>(
        value: _model,
        underline: const SizedBox.shrink(),
        hint: const Text('Choose model'),
        items: [for (final m in _models) DropdownMenuItem(value: m, child: Text(m))],
        onChanged: _running ? null : (m) => setState(() => _model = m),
      ),
    );
  }

  Widget _toolbar() {
    final pending = _entries.where((e) => e.status != CardStatus.done).length;
    final done = _doneEntries.length;
    final busy = _running || _loadingMessage != null;
    final small = Theme.of(context).textTheme.bodySmall;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : _addFiles,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Add cards'),
          ),
          if (_running)
            FilledButton.tonalIcon(
              onPressed: _stopRequested ? null : () => setState(() => _stopRequested = true),
              icon: const Icon(Icons.stop),
              label: Text(_stopRequested ? 'Stopping after this card…' : 'Stop'),
            )
          else
            FilledButton.icon(
              onPressed: pending > 0 && _model != null && !busy ? _extractAll : null,
              icon: const Icon(Icons.auto_awesome),
              label: Text(pending > 0 ? 'Extract all ($pending)' : 'Extract all'),
            ),
          OutlinedButton.icon(
            onPressed: _current != null && _model != null && !busy ? _extractCurrent : null,
            icon: const Icon(Icons.replay),
            label: const Text('Re-read this card'),
          ),
          OutlinedButton.icon(
            onPressed: done > 0 && !_running ? _exportCsv : null,
            icon: const Icon(Icons.table_view_outlined),
            label: const Text('Export CSV'),
          ),
          OutlinedButton.icon(
            onPressed: done > 0 ? _copyJson : null,
            icon: const Icon(Icons.copy),
            label: const Text('Copy JSON'),
          ),
          IconButton(
            tooltip: 'Remove all cards',
            onPressed: _entries.isNotEmpty && !busy ? _clearAll : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          if (_running)
            Text('Reading ${_runDone + 1} of $_runTotal · ${_elapsed.inSeconds}s', style: small)
          else if (_loadingMessage != null)
            Text(_loadingMessage!, style: small)
          else if (_entries.isNotEmpty)
            Text('$done of ${_entries.length} extracted', style: small),
        ],
      ),
    );
  }

  Widget _banner(String msg) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(msg,
            style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
      );

  // ---------------------------------------------------------------- card list

  Widget _cardList() => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _entries.length,
        itemBuilder: (_, i) => _cardTile(i),
      );

  Widget _cardTile(int i) {
    final e = _entries[i];
    final selected = i == _selected;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: () => _select(i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  e.card.jpegBytes,
                  height: 90,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 360,
                  gaplessPlayback: true,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _statusIcon(e),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${i + 1}. ${e.card.label}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (!_running)
                    InkWell(
                      onTap: () => _remove(i),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 14),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusIcon(CardEntry e) => switch (e.status) {
        CardStatus.pending => const Tooltip(
            message: 'Not read yet',
            child: Icon(Icons.radio_button_unchecked, size: 16, color: Colors.grey)),
        CardStatus.extracting => const SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        CardStatus.error => const Tooltip(
            message: 'Failed', child: Icon(Icons.error, size: 16, color: Colors.red)),
        CardStatus.done => e.needsReview
            ? const Tooltip(
                message: 'Needs review',
                child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.deepOrange))
            : const Tooltip(
                message: 'Done', child: Icon(Icons.check_circle, size: 16, color: Colors.green)),
      };

  // ---------------------------------------------------------------- preview

  Widget _preview() {
    final cur = _current;
    if (cur == null) {
      if (_loadingMessage != null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.badge_outlined, size: 72, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('Add scanned cards to begin'),
            const SizedBox(height: 4),
            Text('A PDF with many pages becomes one card per page.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }
    return Container(
      color: Colors.grey.shade200,
      child: InteractiveViewer(
        key: ObjectKey(cur), // reset zoom when switching cards
        maxScale: 6,
        child: Center(
            child: Image.memory(cur.card.jpegBytes, fit: BoxFit.contain, gaplessPlayback: true)),
      ),
    );
  }

  // ---------------------------------------------------------------- results

  Widget _resultsPanel() {
    final cur = _current;
    if (cur == null) {
      return const Center(child: Text('Extracted fields appear here'));
    }
    final fieldByKey = {for (final f in textFields) f.key: f};
    Widget text(String key) => _textField(fieldByKey[key]!);
    final small = Theme.of(context).textTheme.bodySmall;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Card ${_selected + 1} of ${_entries.length} — ${cur.card.label}',
                  style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'Previous card',
              onPressed: _selected > 0 ? () => _select(_selected - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Next card',
              onPressed: _selected < _entries.length - 1 ? () => _select(_selected + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (cur.status == CardStatus.extracting)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (cur.status == CardStatus.pending)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Not read yet — press "Extract all" or "Re-read this card".', style: small),
          ),
        if (cur.status == CardStatus.error && cur.error != null) _banner(cur.error!),
        _section('Personal'),
        _dropdown('gender', 'Gender', genderOptions),
        _row([text('date_of_birth'), text('nationality')]),
        text('first_name'),
        text('middle_name'),
        text('family_name'),
        _section('School'),
        text('school_name'),
        _row([text('city'), text('country')]),
        _dropdown('school_certificate', 'School certificate', certificateOptions),
        if (cur.values['school_certificate'] == 'Other' ||
            (cur.values['other_certificate'] ?? '').isNotEmpty)
          text('other_certificate'),
        text('graduation_year'),
        _section('Contact'),
        text('mobile_number'),
        text('email'),
        if (cur.status == CardStatus.done && cur.elapsed != null)
          Text('Read by ${cur.model} in ${(cur.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)}s',
              style: small),
        if (cur.raw.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Raw model output'),
            children: [
              SelectableText(cur.raw,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _row(List<Widget> children) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: children[i]),
          ],
        ],
      );

  /// Orange = model said it was unsure, or the value failed a sanity check.
  String? _flag(String key) {
    if (_warnings.containsKey(key)) return _warnings[key];
    if (_current?.uncertain.contains(key) ?? false) return 'Model was unsure — please check';
    return null;
  }

  Widget _textField(CardField f) {
    final flag = _flag(f.key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: _ctrl[f.key],
        decoration: InputDecoration(
          labelText: f.label,
          hintText: f.hint,
          helperText: flag,
          helperStyle: const TextStyle(color: Colors.deepOrange),
          enabledBorder: flag == null
              ? null
              : const OutlineInputBorder(borderSide: BorderSide(color: Colors.deepOrange)),
          suffixIcon:
              flag == null ? null : const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange),
        ),
      ),
    );
  }

  Widget _dropdown(String key, String label, List<String> options) {
    final cur = _current!;
    final value = cur.values[key] ?? '';
    final flag = _flag(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: flag,
          helperStyle: const TextStyle(color: Colors.deepOrange),
          enabledBorder: flag == null
              ? null
              : const OutlineInputBorder(borderSide: BorderSide(color: Colors.deepOrange)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: options.contains(value) ? value : '',
            isDense: true,
            isExpanded: true,
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text(o.isEmpty ? '— not marked —' : o)),
            ],
            onChanged: (v) => setState(() {
              cur.values[key] = v ?? '';
              _warnings = validateCard(cur.values);
            }),
          ),
        ),
      ),
    );
  }
}
