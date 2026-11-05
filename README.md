# Card Reader — handwritten card extraction with Ollama + Qwen-VL

A Flutter desktop app (Windows / macOS / Linux) that opens a scanned AUC inquiry
card (PDF or photo), sends it to a **local** Qwen vision model through Ollama,
and shows the handwritten answers in an editable form. Nothing leaves your machine.

## 1. Pick the right model (important)

`qwen2.5` and `qwen3` are **text-only** — they cannot see the card. Use their
vision versions:

| Model | Pull command | Notes |
|---|---|---|
| Qwen2.5-VL 7B | `ollama pull qwen2.5vl:7b` | Good handwriting OCR, ~6 GB, solid default |
| Qwen3-VL 8B Instruct | `ollama pull qwen3-vl:8b-instruct` | Newer, usually more accurate. Use the `-instruct` tag: the plain `qwen3-vl:8b` tag is the slower "thinking" variant |
| Qwen3-VL 4B / 2B Instruct | `ollama pull qwen3-vl:4b-instruct` | For machines without a strong GPU (less accurate) |

Qwen3-VL needs a recent Ollama (0.12.7+). The app checks the model's
capabilities and refuses to run with a text-only model, because such a model
would silently ignore the image and make up answers.

## 2. Run it

### macOS (ready to go)
The repo already contains the macOS project (minimum macOS 12, network and
file access enabled, App Sandbox off so results can be saved next to the scans).

```bash
git clone <this repo>
cd card_reader
./run_mac.sh        # checks Ollama + model, installs packages, launches the app
```

or simply `flutter pub get && flutter run -d macos`.

### Windows / Linux
Generate the platform folder once, then run:

```bash
flutter create --platforms=windows .     # or linux
flutter pub get
flutter run -d windows                   # or -d linux
```

Make sure Ollama is running (`ollama serve`, or the Ollama desktop app).

### Linux only
`file_picker` needs `zenity` (`sudo apt install zenity`).

## 3. Using it

1. **Add cards** → pick one or more PDFs and/or images. Every PDF page becomes
   its own card (one card per page), listed on the left.
2. Choose the model in the top bar, press **Extract all**. Cards are read one
   after another; **Stop** finishes the current card and halts. Use
   **Re-read this card** to retry a single one (e.g. with another model).
   List icons: ○ not read · ✓ done · ⚠ needs review · ✕ failed.
3. Review the form. Fields turn **orange** when the model flagged them as
   uncertain or when they fail a sanity check (impossible date, phone not 11
   digits starting 010/011/012/015, `gmail.edu`-style domains, etc.).
4. When reading finishes, results are saved automatically to an Excel file
   next to the scan (`cards.pdf` -> `cards - results.xlsx`), one row per card,
   with cells to double-check filled orange. Corrections you make in the app
   are re-saved automatically. **Save Excel as…** picks another location;
   **Copy JSON** copies everything to the clipboard.

Settings (gear icon): Ollama URL, image size sent to the model (default 1600 px
on the long side), and a "disable thinking" switch for thinking-type models.

## Project layout

```
lib/
  main.dart                    app entry + theme
  models/card_data.dart        field list, JSON schema, validation rules
  services/ollama_service.dart prompt + /api/chat call with structured output
  services/image_loader.dart   PDF rasterising (one card per page), EXIF rotation, resizing
  services/excel_export.dart   .xlsx output
  models/card_entry.dart       per-card state (status, values, flags)
  screens/home_screen.dart     UI: preview (zoomable) + editable results
```

## How the extraction works

- The card image is resized and sent as base64 to `POST /api/chat`.
- The prompt describes the card layout field by field (where the handwriting
  sits relative to each printed label, how ticks on checkboxes look, Egyptian
  phone format) — this matters more than model size for accuracy.
- `format` is a JSON schema, so Ollama forces the model to return exactly the
  card's keys; checkbox fields are constrained to the printed options.
- `temperature: 0` for repeatable results.

## Tips for better accuracy

- Scan flat and well lit; CamScanner's "B&W" or "Lighten" filters help.
- If names come out wrong, raise the image size to 2048 px in Settings.
- For a different card layout, edit `_userPrompt` in `ollama_service.dart` and
  the field list/schema in `card_data.dart`.
