# Models

This directory records the shared model contract; it does not duplicate large model files.

The distributable packages currently reuse these identical relative assets:

- `surya-ocr-2-gguf/surya-2.gguf`
- `surya-ocr-2-gguf/surya-2-mmproj.gguf`
- `model-cache/huggingface/...`
- `model-cache/datalab-models/...`

Each platform package keeps its own copy so that Windows and macOS releases can be installed,
updated, verified, and removed independently. Model hashes remain part of release verification.
