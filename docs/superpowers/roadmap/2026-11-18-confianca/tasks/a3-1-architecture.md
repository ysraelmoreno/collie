# A3.1 Fronteiras de módulo

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a3-arquitetura.md` (requisitos 1–5).

## Fazer

1. `scripts/ci/check-architecture.sh`, com `swift package dump-package` + `jq` (aceita `--package-json <f>` e
   `ARCH_ROOT` para teste):
   - todo `import <M>` em `Sources/<T>/**/*.swift`, onde `<M>` é target do pacote ou produto de dependência
     (`SwiftTerm`), precisa estar nas dependências **diretas** de `<T>`. `@testable import` em `Tests/` fica fora.
   - regras de `scripts/ci/architecture-rules.txt` (comentários com `#`, uma regra por linha):
     `forbid-closure <target> <módulo>`: o fecho de dependências de `<target>` não contém `<módulo>`;
     `forbid-import <target> <padrão>`: nenhum arquivo de `<target>` importa módulo que casa com o padrão (glob).
2. Regras iniciais: `forbid-closure collie SwiftTerm`, `forbid-closure collie CollieScreen`,
   `forbid-import CollieProtocol Collie*`, `forbid-import CollieCore AppKit`, `forbid-import CollieCore SwiftUI`,
   `forbid-import CollieProtocol AppKit`. Se o código atual viola uma delas, tire a regra e explique no commit.
3. Erro: `arquivo:linha`, regra, e o que fazer.
4. `scripts/ci/test-check-architecture.sh`: JSON de pacote fabricado + árvore fabricada; casos: import declarado passa;
   import transitivo falha; `forbid-closure` violado falha; `forbid-import` violado falha; o repo real passa.
5. No `Package.swift`, o comentário do `CollieScreen` ganha `(enforced: scripts/ci/architecture-rules.txt)`.
6. Executáveis com `chmod +x`.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
