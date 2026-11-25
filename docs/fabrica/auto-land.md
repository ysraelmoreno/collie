# Auto-land: o laço integra o cercado sozinho (preview)

O auto-land faz o `work run` terminar o trabalho **integrando o cercado na base por merge local**, quando um conjunto
fixo de condições passa. Tudo falha fechado: qualquer dúvida para o laço com um `stopReason` próprio e avisa o dono.

**O auto-land nunca faz push, nunca abre PR e nunca cria tag.** Só roda `paddock land` em modo `merge`
(`WorkLoopCommands.swift`, `landPaddock`: qualquer outro modo é recusado). O que sai do seu computador continua sendo
decisão sua: depois do land, você revisa e dá o push.

Estado: preview. As partes abaixo estão implementadas e testadas com hosts falsos; a validação ponta a ponta num
repositório real é a A7 (`docs/superpowers/specs/autoland/a7-validacao-e2e.md`) e ainda não rodou.

## Como ligar

1. **Perfil.** O `collie-work.json` COMMITADO na base precisa ter `gate` e o bloco `factory` com `review`
   (modelos em `docs/fabrica/modelos/`). O motor lê o perfil do commit base, nunca da árvore do agente
   (`ProjectWorkConfig`, `WorkConfigFile.config(base:dir:)`).
2. **`collie factory doctor`** precisa passar o mínimo: `static` e `judge` com nota 1 ou mais.
3. **Marca de cercado fábrica**, só o dono (app ou a CLI dele; nunca MCP nem terminal de agente):

   ```sh
   collie paddock create meu-cercado --factory      # já nasce marcado
   collie paddock factory meu-cercado on|off         # liga ou desliga
   ```

   Ligar roda o núcleo do doctor (só leitura) e recusa se `static` ou `judge` estiver abaixo de 1 ou o perfil for
   inválido, dizendo a camada. Desligar nunca recusa. No app, há o interruptor do cercado e o selo no trilho.
4. **`work run --auto-land`**, de dentro do cercado (o Pastor roda; o dono confirma tarefas, checks, gate e limites no
   cartão do app, e o cartão diz "AUTO-LAND no fim: portão ..., CI ..., então paddock land por merge local, sem push").

   ```sh
   collie work run --max 6 --auto-land
   collie work run --max 6 --auto-land --auto-land-max 3
   collie work run --max 6 --auto-land --queue      # só entra na fila do cercado (veja "Fila")
   ```

`--auto-land` é recusado, com mensagem, quando: o cercado não é fábrica; o perfil commitado não tem `gate`; a revisão
está desligada (`--no-review`, ou o perfil sem `factory.review` e sem `--review`). `--queue` e `--auto-land-max` só
valem junto de `--auto-land`. Sem `--auto-land`, `factory.guardrails.land: factory-paddock` só gera um aviso e o laço
segue manual.

## As condições do land

Quando todas as tarefas do trabalho terminam `done`, o motor confere nesta ordem e para na primeira que falha
(`landConditions`, `Sources/CollieDaemonKit/Work/WorkLoop.swift`):

| Ordem | Condição | Falha com |
|---|---|---|
| 1 | o cercado ainda é fábrica | `landNotFactory` |
| 2 | teto diário não estourado | `landDailyCap` |
| 3 | o agente não mexeu em arquivo que julga o land (`collie-work.json`, o CI, scripts que o gate ou o CI citam), comparando a base da execução com a árvore | `landGateRed` ("o agente alterou ... que julga o land") |
| 4 | portão (`gate` do perfil commitado) verde no HEAD do cercado | `landGateRed` |
| 5 | toda tarefa `done` teve revisão limpa na última tentativa (parecer mudo ou ausente não aprova) e o HEAD é o que a revisão aprovou | `landReviewVeto` |
| 6 | se alguma tarefa tem `--accept`, o último aceite dela passou | `landAcceptRed` |
| 7 | CI local verde: `factory.autoland.ci` do perfil, senão `scripts/ci/run-tests.sh`; timeout `factory.autoland.timeoutSeconds`, senão 1800 s | `landCiRed` |
| 8 | árvore limpa e o HEAD não mudou durante o portão e o CI | `landDirty` |
| 9 | a base não andou desde o início da execução | `landBaseMoved` |
| 10 | nenhum outro agente trabalhando no cercado | `landDirty` |
| 11 | `work stop`, cancelamento, trabalho fechado ou Pastor sumido não chegaram no meio | `requested`, `cancelled`, `workGone`, `starterGone` |
| 12 | o `paddock land` por merge funciona | `landConflict` (falha ou conflito); `landNothing` se o merge não criou commit |

Se tudo passa, o merge é feito e o resultado fica registrado no diário (`landed`) e numa nota do trabalho com o commit
da base antes e depois, mais o comando para desfazer (`git reset --hard <antes>` na base, ou `git revert -m 1 <depois>`).
Um passo que falha DEPOIS do merge não vira conflito: a nota diz que a base mudou e guarda os dois commits.

## `stopReason` do auto-land

O laço `finished` quando termina com `landed`, `queueEmpty` ou `maxReached` com detalhe (teto do auto-land;
`WorkLoopState.Stop.finishes`). Os demais deixam o trabalho `stopped` e chamam o dono por `notify`.

| `stopReason` | Quando | Integrou? |
|---|---|---|
| `landed` | merge feito e a corrente acabou (detalhe: `<base antes> -> <depois>`) | sim |
| `queueEmpty` | integrou e ainda havia teto livre em `--auto-land-max`, mas não há outro trabalho aprovado na fila | sim, o que havia |
| `maxReached` (com detalhe) | integrou `--auto-land-max` trabalhos e ainda há aprovados esperando | sim |
| `landGateRed` | portão vermelho no HEAD, ou o agente alterou arquivo que julga o land | não |
| `landReviewVeto` | tarefa sem revisão limpa, parecer mudo, ou commits depois da revisão | não |
| `landCiRed` | CI local vermelho ou estourou o timeout | não |
| `landDirty` | árvore suja, HEAD mudou durante o portão/CI, ou outro agente trabalhando | não |
| `landConflict` | o `paddock land` por merge falhou (ou conflitou) | não |
| `landNotFactory` | o cercado deixou de ser fábrica | não |
| `landAcceptRed` | uma tarefa com `--accept` não tem aceite verde na tentativa vencedora | não |
| `landDailyCap` | `factory.guardrails.autoLandPerDay` lands em 24 h já feitos (antes do primeiro land ou antes do próximo trabalho da corrente) | não, ou só os anteriores |
| `landDoctorRegressed` | antes do próximo trabalho da fila, o `factory doctor` do cercado não passa mais o mínimo (static e judge >= 1) | só os anteriores |
| `landNothing` | o merge não criou commit (nada novo, ou já integrado); não conta no teto diário nem na corrente | não |
| `landBaseMoved` | a base andou desde o início da execução: o portão e o CI não julgaram o resultado do merge; refaça o land | não |

Com `--auto-land-max 1` e a fila vazia o fim é `landed`, não `queueEmpty`: `queueEmpty` só aparece quando ainda havia
teto e a fila acabou.

## Fila e tetos (`--auto-land-max`, `autoLandPerDay`)

- `--auto-land-max N` (padrão 1, no máximo 5): quantos trabalhos uma mesma execução integra.
- `--queue`: o dono aprova o trabalho no cartão agora e ele espera na fila do cercado (`queued`, nada roda). Depois de um
  land, a corrente ativa o próximo trabalho aprovado (o de aprovação mais antiga). A corrente nunca aprova nada: só
  entra o que o dono já aprovou. `work stop` num trabalho da fila o tira da fila e o mantém aprovado.
- Antes de cada novo trabalho: teto N, teto diário, `factory doctor` e orçamento. O `--budget` vale para a execução
  inteira, não por trabalho. Uma falha de land num trabalho da corrente para a corrente toda.
- **Teto diário:** `factory.guardrails.autoLandPerDay` no perfil (inteiro de 1 a 20; padrão 3). É contado pelos lands
  que o próprio cercado registrou nas últimas 24 h (`Paddock.autoLands`, guardado pelo daemon). Reabrir o trabalho ou
  rodar de novo não zera o teto.

## O resumo imutável

Toda execução com `--auto-land` termina, seja qual for o `stopReason`, com um resumo em markdown, escrito UMA vez na
pasta de estado do daemon (`<raiz do daemon>/work-loops/<trabalho>/autoland/AAAA-MM-DD-HHMMSS.md`, `AutoLandSummary.swift`),
fora da árvore do agente, com `O_EXCL` e permissão 0444. Nada o sobrescreve (nome ocupado vira `-1`, `-2`, ...).

Conteúdo: início, fim e duração; `stopReason`; nota do doctor no fim; PRD (hash e origem), se houver; o trabalho
integrado (título, base antes e depois); por tarefa, tentativas, tempo, quem aprovou, quem vetou (`[persona]
arquivo:linha`) e o resultado do aceite; "Não feito": sem push, a linha para reverter
(`git -C <base> reset --hard <antes>`, como TEXTO, nunca executada) ou, se nada foi integrado, as condições que passaram
e a que parou; e candidatas a armadilha (a mesma falha em 2 ou mais tentativas; nada é salvo em memória sozinho).
O texto passa pelo mesmo `scrub` das notas e traz só linhas já limpas do registro, nunca a tela crua do agente.

O dono recebe uma linha por `notify` (`integrou N trabalhos` ou `parou em <stopReason>`) com o caminho do resumo, e
`collie work summary` e o cartão do app mostram o mesmo texto.

## O que o auto-land não faz

- push, PR, tag, ou qualquer comando de rede;
- aprovar tarefas, trabalhos ou o plano pelo dono;
- decidir por você se o resultado está certo: a revisão por personas só **veta**; quem aprova são o check, o portão, o
  aceite e o CI;
- bloquear comandos destrutivos: `factory.guardrails.destructive` hoje só aparece como aviso no `work status`.

Veja também: `docs/fabrica/aceite-e-entrada.md` (aceite em runtime e entrada por PRD) e `docs/fabrica/modelos/`.
