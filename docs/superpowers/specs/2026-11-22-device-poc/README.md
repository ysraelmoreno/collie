# POCs do helper de UI e do OCR (2026-11-22)

Código descartável que sustenta as specs `device-helper-design` e `device-ocr-fallback-design`. Não é build do produto.

- `helper-a11y/`: serviço de acessibilidade (APK montado à mão com aapt2, javac, d8, zipalign, apksigner; JDK do Android Studio). Escuta em TCP 127.0.0.1:7788 (a versão de produção usa socket abstrato com checagem de uid). `q.py` mede o dump, `t.py` testa o toque.
- `app-process/`: helper via `app_process` com `UiAutomation`; morre com SIGKILL no `connect()`. Descartado.
- `ocr/`: `ocr2.swift` (Vision: `ocr2 <png> fast|accurate <escala> <vezes>`), `corpus.py` (captura de telas estáveis com a árvore do helper como gabarito), `evalocr2.py` (recall, posição, latência), `fx.py` (bateria do fixture).
- Fixture de telas de árvore pobre: `Helpers/android-device/fixture/`.
