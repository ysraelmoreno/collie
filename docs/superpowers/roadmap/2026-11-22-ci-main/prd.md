# PRD: `ci` da main verde de novo (investigação das falhas de 2026-11-22)

Status: proposto. Origem: o primeiro `ci` depois do push da v0.1.9 (run 44969188276, commit `edd5bd4`) falhou em 22 minutos. Card do Quadro: "CI da main: investigar falhas dos 3 shards".

## Problema
A main não tem `ci` verde desde `01f703d` (run 44660112287, 2026-11-20). Os três runs seguintes na main foram **cancelados** (44790066091, 44926559472, 44928048461): ficaram pendurados até o teto de 60 minutos do job. A Onda 11 (M11.2) trocou esse cancelamento por timeout de 900 s por shard, e agora a falha aparece com nome. O release da v0.1.9 saiu normalmente porque `release.yml` não roda a suíte; o `ci` é o único portão automático que o repositório público tem e hoje ele não protege nada.

## O que o run mostra
| Shard | Resultado | Último teste iniciado / issues |
|---|---|---|
| 0 | timeout 900 s | `tooManyEntriesThrows` (ZipWriterTests); 1 issue |
| 1 | timeout 900 s | `runNeedsOpenTasks` (WorkLoopCommandTests); 14 issues |
| 2 | exit 1 em 682 s, rodou 1310 de 1385 testes | 25 issues |

Falhas já identificadas no shard 2 (as dos shards 0 e 1 só estão no artefato `test-logs`):
- WebKit sem tela: `BrowserEmulateTests` (reducedMotion, combos, shadow/adopted sheets), `BrowserInputTests.iframeTypingNeverRefusedNorLeaks`.
- Serviços de app: `PaddockAppsTests` (`serviceStartsInCwd`, `serviceWithoutCwdUnchanged`, `runsOnDemandRestartsAndStopsWithItsPin`, `idleWithNoPanelStops`, `landDropsApprovalsAndStopsServices`, `deleteDropsApprovalsStopsServicesAndLogs`): "Kube ainda está iniciando", cada um esperando cerca de 30 s.
- Outros: `DaemonClientTests.resizeDebounceSendsLastSizeOnly` (3 winch em vez de 1), `HerdApplyTests.rollbackKeepsPaddockWithCommits`, `ShepherdTests.injectedTurnHoldsQueue`, `VizinhoPluginTests.editGuidesFromSiblingsAndLoneFileIsSilent` (`isExecutableFile`).

O "último teste iniciado" não é necessariamente o culpado: o swift-testing roda testes em paralelo.

## Hipóteses (a testar, não a assumir)
1. **Ambiente do runner:** testes que dependem de WebKit com janela, de pty ou de bit executável nunca passaram em runner hospedado e entraram na suíte depois do último verde.
2. **Tempo, não travamento:** os 30 s de espera dos testes de serviço, multiplicados, estouram 900 s num runner de 3 núcleos.
3. **Regressão do produto** entre `01f703d` e `edd5bd4` (104 commits: Ondas 8 a 13).
4. **Teste frágil por corrida** (`resizeDebounce…`, `injectedTurnHoldsQueue`, `rollbackKeepsPaddock…`): passa na máquina do dono, falha sob carga.

## Objetivos
- Cada falha classificada como **ambiente**, **teste frágil** ou **regressão**, com evidência.
- `ci` verde na main em dois runs seguidos, com cada shard abaixo de 600 s (folga sobre os 900 s).
- Nada de teste escondido sem motivo: o que for ambiente entra em `scripts/ci/ci-skip.txt` com a razão, como manda o catraca daquele arquivo.

## Fora do escopo
- Reescrever a suíte ou mudar de runner.
- Cobrir de verdade o WebKit no CI (se a hipótese 1 se confirmar, a cobertura desses testes fica para depois).
- Mexer em `release.yml`.

## Plano (tarefas)
- **CI1 Coletar (sem código).** Baixar o artefato `test-logs` do run 44969188276 (retenção de 7 dias: vence em 2026-11-29; o download pede autorização do dono) e extrair as issues dos shards 0 e 1 e o tempo por teste. Entregável: tabela falha → hipótese.
- **CI2 Localizar o início.** Achar o primeiro commit ruim entre `01f703d` e `edd5bd4`. Opções: bisseção por branch e pull request de teste (cerca de 7 runs de 25 minutos; publica branch, precisa de OK do dono) ou reprodução local fora do sandbox do Collie, que não vale para os testes de WebKit e pty.
- **CI3 Consertar ou isolar,** uma falha por vez, sempre com teste: regressão do produto = conserto; teste frágil = tornar determinístico (sem `sleep` nem relógio de parede, como as regras da Onda 11); ambiente = `ci-skip.txt` com razão.
- **CI4 Orçamento de tempo.** Se a hipótese 2 valer, reduzir os 30 s de espera dos testes de serviço por um valor injetável (o padrão da M11.2 com `AskTests`) e rebalancear os shards.
- **CI5 Prova.** Dois `ci` verdes seguidos na main, tempos por shard registrados no CHANGELOG ou no relatório.

## Riscos
- Esconder uma regressão real no `ci-skip.txt`. Mitigação: só entra com evidência de que o teste não roda no runner, e uma revisão independente confere a lista.
- Custo de runs (25 minutos cada). Mitigação: bisseção só depois da CI1 apontar o que procurar.
- Cache de `.build` (M11.2) mascarar ou causar falha: se algo inexplicável aparecer, comparar com um run sem cache.

## Perguntas abertas
1. Autoriza baixar o artefato `test-logs` e abrir uma branch/PR de teste (publica no repositório público)?
2. Tolerância: aceita deixar os testes de WebKit fora do CI enquanto o resto fica verde?
