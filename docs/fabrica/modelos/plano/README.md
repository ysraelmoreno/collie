# Modelo do pacote de plano

Um pacote é uma pasta com `waves.md` e `tasks/<id>.md`. `collie work plan lint <pasta>` o lê; este modelo passa.

Campos do cartão (linhas `chave: valor` no começo da linha, fora de bloco de código; o resto é texto livre e vira a spec
da tarefa): `check` ou `area` (um dos dois), `accept`, `accept-timeout`, `needs`, `scope`, `evidence`, `agent`, `model`,
os mesmos de `collie work task add`. O título é a primeira linha `# `.
