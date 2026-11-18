# PRD A3: fronteiras de módulo verificadas

## Problema

O `Package.swift` declara as dependências, mas o SwiftPM aceita `import` de módulo que só chega transitivamente. Regras
importantes vivem em comentário, ex.: "CollieScreen: SwiftTerm brings AppKit, so only collied links it, never the
`collie` CLI". Um agente que lê o código não vê essas regras; um comentário não é imposto.

É o "electron main/renderer" da palestra: diretório = contexto, e imports cruzados proibidos por ferramenta.

## Objetivo

Toda regra de fronteira é verificada por um script que roda no CI e no laço.

## Não-objetivos

- Ferramenta de grafo de dependências de terceiros.
- Regras dentro de um módulo (por arquivo).

## Requisitos

1. `scripts/ci/check-architecture.sh`, usando `swift package dump-package` + `jq`:
   - **imports declarados:** todo `import <M>` em `Sources/<T>/` onde `<M>` é target ou produto do pacote (inclui
     `SwiftTerm`) precisa ser dependência **direta** de `<T>`. Frameworks da Apple e stdlib são ignorados.
   - **regras explícitas** em `scripts/ci/architecture-rules.txt`, uma por linha, formato simples, ex.:
     `forbid-closure collie SwiftTerm` (o fecho de dependências do executável `collie` não contém `SwiftTerm`),
     `forbid-closure collie CollieScreen`, `forbid-import CollieProtocol Collie*`,
     `forbid-import CollieCore AppKit`, `forbid-import CollieCore SwiftUI`.
2. Regras iniciais: as acima mais o que os comentários do `Package.swift` dizem. Se o código atual violar uma regra
   proposta, a regra está errada: tire-a e explique no commit (o dono revisa).
3. Mensagem de erro: arquivo, linha, a regra, e o que fazer ("declare a dependência em Package.swift se a fronteira
   permite; senão mova o código para <módulo>").
4. Teste `scripts/ci/test-check-architecture.sh` com um pacote mínimo fabricado em diretório temporário (ou entradas
   JSON fabricadas, se o script aceitar `--package-json <f>`).
5. O comentário do `CollieScreen` no `Package.swift` passa a citar a regra (`see scripts/ci/architecture-rules.txt`).

## Medida de resultado

- Introduzir `import SwiftTerm` em `Sources/collie/` faz o script falhar com a mensagem certa.
- Nenhuma regra nova de fronteira é escrita só em comentário daqui em diante.

## Tarefas

- A3.1 `check-architecture.sh`, regras, teste (`tasks/a3-1-architecture.md`)
