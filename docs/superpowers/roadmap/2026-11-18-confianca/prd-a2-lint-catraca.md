# PRD A2: lint em catraca

## Problema

Agentes copiam o padrão que encontram. Em `Sources/` hoje (2026-11-18):

| Regra | Ocorrências | Maiores focos |
|---|---|---|
| `sleep`: `Task.sleep`, `.asyncAfter(`, `usleep(`, `Thread.sleep` | 106 | `AskCoordinator.swift` (12), `DeviceService.swift` (5), `DesignService.swift` (5) |
| `unsafe-concurrency`: `@unchecked Sendable`, `nonisolated(unsafe)` | 59 | `OfflineRewrite.swift` (5), `MCPServer.swift` (4) |
| `force`: `try!`, `as! ` | 8 | `ClaimChecks.swift` (2 regex), `RemoteIdentity.swift` |

Muitos são legítimos (polling de processo externo, tipos CF). O problema é que nada distingue o legítimo do remendo, e
cada novo agente vê "sleep é normal aqui". É o caso dos timers do Cursor na palestra.

## Objetivo

Nenhuma ocorrência **nova** dessas regras entra sem decisão explícita; as antigas só podem diminuir.

## Não-objetivos

- SwiftLint ou swift-format (dependência nova, configuração grande, para três regras de grep).
- Corrigir as ocorrências antigas nesta etapa (é a onda 5: auditoria primeiro, conserto depois, por decisão do dono).
- Marcador de exceção em comentário (`// lint:allow`): é a saída de emergência que a palestra aponta. A exceção é o
  baseline, que muda num diff visível.

## Requisitos

1. `scripts/ci/lint.sh`: varre `Sources/**/*.swift` por regra, conta por arquivo, compara com
   `scripts/ci/lint-baseline.txt` (linhas `<regra> <arquivo> <n>`, ordenadas).
2. Falha (exit 1) quando um arquivo passa do seu número, ou aparece arquivo fora do baseline. A mensagem nomeia regra,
   arquivo, linha e a causa raiz a atacar:
   - `sleep`: "espere o evento (continuation, AsyncStream, notificação, hook), não o tempo";
   - `unsafe-concurrency`: "isole o estado num actor ou torne o tipo Sendable de verdade";
   - `force`: "trate o erro; um regex constante vira `static let` com `try` num inicializador testado".
3. Também falha quando um arquivo tem **menos** que o baseline (catraca): manda rodar `lint.sh --update-baseline`.
4. `--update-baseline` só abaixa ou remove números; nunca sobe nem acrescenta (subir é edição à mão do baseline,
   revisada no diff).
5. Baseline inicial = contagem atual exata.
6. Teste em `scripts/ci/test-lint.sh` (árvore temporária com arquivos fabricados; aceita um diretório raiz por variável
   de ambiente, ex.: `LINT_ROOT`).
7. Rápido: < 2 s no repo.

## Medida de resultado

- Em 30 dias, o total do baseline não sobe.
- Um agente que tenta `Task.sleep` num arquivo novo recebe a mensagem e muda a abordagem (ver notas do laço).

## Tarefas

- A2.1 `lint.sh`, baseline, teste (`tasks/a2-1-lint.md`)
- A2.2 (onda 5) zerar `force` (`tasks/a2-2-force-zero.md`)
- A2.3 (onda 5) auditoria de `sleep` e `unsafe-concurrency`: legítimo × remendo (`tasks/a2-3-audit.md`)
