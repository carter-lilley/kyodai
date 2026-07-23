# Logo Detector GDExtension

This addon provides a `LogoDetector` class that runs a YOLOv8-seg ONNX model to propose title/logo regions in cover images, then uses a RapidOCR CRNN model to recognize text inside each candidate. GDScript scores the candidates against the game title to pick the best box.

## Files

- `logo_detector.gdextension` — Godot extension manifest
- `src/` — C++ source code
- `CMakeLists.txt` — CMake build configuration (used by CI)
- `models/` — ONNX models (Git LFS)
  - `logo_detector.onnx` — YOLOv8-seg title/logo detector
  - `ch_PP-OCRv4_rec_infer.onnx` — RapidOCR text recognition (CRNN)
  - `ch_PP-OCRv4_det_infer.onnx` — (optional, not currently used) RapidOCR text detection

## Supported platforms

- Windows x86_64
- Linux x86_64
- Android ARM64

## Getting binaries

Binaries are built by GitHub Actions. The workflow produces a draft release (`logo-detector-latest`) with a `logo_detector-binaries.zip` artifact containing all three platforms plus the ONNX models.

Place the files so the paths match the `.gdextension` manifest:

```
addons/logo_detector/
├── bin/
│   ├── windows.x86_64/
│   │   ├── liblogo_detector.windows.template_release.x86_64.dll
│   │   ├── onnxruntime.dll
│   │   └── onnxruntime_providers_shared.dll
│   ├── linux.x86_64/
│   │   ├── liblogo_detector.linux.template_release.x86_64.so
│   │   └── libonnxruntime.so*
│   └── android.arm64/
│       ├── liblogo_detector.android.template_release.arm64.so
│       └── libonnxruntime.so
└── models/
    ├── logo_detector.onnx
    └── ch_PP-OCRv4_rec_infer.onnx
```

After placing the binaries, **restart Godot** so it loads the GDExtension. If Godot still reports that it cannot find the library, delete the `.godot/` folder at the project root and restart Godot so it rescans all addons.

## Usage in GDScript

```gdscript
var detector = LogoDetector.new()

# Load the YOLO model and the OCR recognition model.
detector.load_yolo_model("res://addons/logo_detector/models/logo_detector.onnx")
detector.load_ocr_rec_model("res://addons/logo_detector/models/ch_PP-OCRv4_rec_infer.onnx")

# Get candidate boxes.
var candidates = detector.detect_candidates(image, 0.15, 0.45, 5)

# Get recognized text for each candidate (uses YOLO crops internally).
var words = detector.ocr_full_image(image)

# Or let the extension pick the candidate whose text best matches a title.
var result = detector.detect_title_box(image, "Super Mario Bros", 0.15, 0.45)
if result["detected"]:
    print("Box: ", result["x1"], result["y1"], result["x2"], result["y2"])
    print("Matched text: ", result["matched_text"])
    print("Confidence: ", result["confidence"])
```

## Notes

- The model was trained with `nc: 1` and class name `title_logo`.
- The YOLO output is decoded in 640x640 letterbox space and mapped back to the original image coordinates.
- The extension builds a **Release** binary and uses the Release CRT (`/MD`) on Windows.
- `reloadable` is set to `false` in the `.gdextension` manifest because the binary is built with `GODOT_USE_HOT_RELOAD OFF`.
- ONNX Runtime binaries are **not** committed to git. They are downloaded and linked by the GitHub Actions workflow.
