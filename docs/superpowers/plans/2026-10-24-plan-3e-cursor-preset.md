# Plano 3E — Preset Cursor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O Cursor CLI (`cursor-agent`) vira um preset do Orq, como o Codex: dá para criar pelo app, recrutar pelo Maestro, usar `ask`/`check` e pôr em partituras, usando o plano do Cursor do usuário (login do próprio CLI, sem chave de API). O plano começa por um spike que decide se há hooks utilizáveis sem tocar em configuração global.

**Architecture:** Mesmo molde do preset `codex` da v1: um caso novo em `Preset`, um ramo em `AgentLaunch.launchSpec`, a escolha na janela de terminal e no `recruit`. Sem hooks, a resposta do `ask` vem pelo caminho de **ociosidade** que `shell`/`custom` já usam. A trava `hookCapable` da v1 faz o terminal passar sozinho para "só hook" se um hook chegar. Os hooks só entram se o spike achar um jeito **por terminal** (flag ou variável de ambiente). Arquivo em `~/.cursor/` ou no `.cursor/` do repositório do usuário fica fora, salvo autorização explícita.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing. Nenhuma dependência nova no Orq; o `cursor-agent` é instalado pelo usuário (ou com aprovação dele).

**Spec:** sem spec própria — decisões do usuário em 2026-10-24 (conversa com o Planejador): preset Cursor depois da Fase 3; usa o plano do Cursor sem API; começa por spike dos hooks; painel de uso provavelmente sem dados. Regras da v1 valem: `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §5 (presets, cordas, `ask`), §3. Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md` (linha 3E). Base: `main` depois do 3A (e do 3D, se já mergeado: a validação de presets das partituras ganha `cursor`).

## Global Constraints

- **Nenhuma configuração global tocada:** nada em `~/.cursor/`, nada no `.cursor/` dos repositórios do usuário, sem autorização explícita dele; hooks só por flag/variável de ambiente por terminal (como o `--settings` do Claude e o `-c notify=` do Codex).
- **Sem gastar o plano sem pedido:** o spike não manda prompts ao agente sozinho; qualquer sessão real do `cursor-agent` é feita **pelo usuário** (ou com o OK dele na hora), curta.
- **Instalar exige aprovação:** o instalador oficial baixa da internet (`curl https://cursor.com/install -fsS | bash`); o builder pede ao usuário antes. Login (`cursor-agent login`) é do usuário, no navegador; o Orq nunca vê nem guarda credencial do Cursor.
- Corda é a única permissão; nada muda nas regras de `ask`/`recruit`.
- Protocolo `v: 1`; `preset` ganha o valor novo `cursor`. Para um build antigo (ou arquivo com preset desconhecido) não perder o workspace inteiro, `Preset` decodifica valor desconhecido como `custom` (Task 2).

## Review Focus

1. **`cursor-agent` não instalado ou fora do `PATH` do shell de login** → criar/recrutar falha na hora com "cursor-agent não encontrado (instale com …)", nenhum terminal fantasma. Teste: Task 2 `missingBinaryFailsFast`.
2. **`ask` a um Cursor sem hook** → resposta pela ociosidade (como `shell`), sem esperar os 30 min do prazo; se um hook chegar um dia, a trava `hookCapable` passa para "só hook". Teste: Task 2 `cursorAskCompletesOnIdle`.
3. **Workspace salvo com `preset: cursor` aberto por um build antigo / arquivo com preset desconhecido** → só esse terminal vira `custom` com o comando gravado; o resto do workspace carrega. Teste: Task 2 `unknownPresetDecodesAsCustom`.
4. **Pedido de permissão do Cursor** (rodar comando, editar arquivo) → badge de atenção, como no Claude, com os textos que o spike registrou. Teste: Task 2 `cursorPromptsRaiseAttention`.
5. **Não logado** (o CLI pede login ao abrir) → o terminal mostra o pedido do próprio CLI e fica em atenção; o Orq não tenta logar. Teste: Task 2 (padrão de login na lista de atenção, se o spike achar o texto).

---

## File Structure

```
docs/superpowers/spikes/2026-10-xx-cursor/REPORT.md   resultado do spike (Task 1)
Sources/OrqCore/Workspace.swift                       Preset.cursor + decodificação tolerante
Sources/OrqDaemonKit/{AgentLaunch,AttentionDetector,AskCoordinator,MaestroCommands}.swift
Sources/OrqProtocol/{Commands,HookPayload}.swift      (recruit help; hook cursor-stop se a Task 3 rodar)
Sources/orq/HookCommands.swift                        (cursor-stop, se a Task 3 rodar)
Sources/OrqApp/TerminalSheet.swift
Sources/OrqCore/Partitura.swift                       (se o 3D já estiver na main: preset aceito + checagem de PATH)
Tests/OrqDaemonKitTests/{AgentLaunchTests,AskTests,AttentionTests}.swift, Tests/OrqCoreTests/WorkspaceTests.swift
README.md
```

---

### Task 1: Spike — o que o `cursor-agent` desta máquina oferece

**Files:** Create `docs/superpowers/spikes/2026-10-xx-cursor/REPORT.md` (data real no nome)

- [ ] **Step 1:** `command -v cursor-agent agent`; se ausente, **pedir ao usuário** para instalar (ou aprovar `curl https://cursor.com/install -fsS | bash`). Anotar caminho (normalmente `~/.local/bin`), `cursor-agent --version`, e se `agent` é o mesmo binário.
- [ ] **Step 2 (sem rede, sem tokens):** `cursor-agent --help` e `--help` dos subcomandos; procurar no pacote instalado (`strings`/grep no bundle JS) por: `hooks.json`, nomes de eventos (`stop`, `beforeSubmitPrompt`, `afterAgentResponse`, `beforeShellExecution`, `afterShellExecution`), variáveis de ambiente de configuração (`CURSOR_CONFIG_DIR`, `XDG_CONFIG_HOME` ou parecidas), e flags que apontem um arquivo de configuração/hooks. Anotar o que existe.
- [ ] **Step 3 (sessão curta, pelo usuário):** com o usuário logado, num repositório descartável no scratchpad, abrir `cursor-agent` dentro de um terminal do Orq como `custom` e capturar com `orq check`: (a) o texto da tela quando está pronto esperando prompt; (b) o texto de um pedido de permissão (pedir algo que rode `ls`); (c) o texto de "não logado", se houver como ver sem deslogar. **Se** o Step 2 achou um caminho por terminal, testar ali um hook `stop` que só grava um arquivo no scratchpad, e anotar se dispara no CLI interativo.
- [ ] **Step 4:** Fonte local de uso do plano: procurar em `~/.cursor`/`~/Library/Application Support/Cursor` algo legível **sem token/credencial** com limites de uso; anotar (esperado: nada — o painel de uso fica sem o Cursor).
- [ ] **Step 5:** REPORT com: nome do binário, versão, textos (a)(b)(c), mecanismo de hook por terminal (**sim**, com o como / **não**), fonte de uso (sim/não), e a recomendação: Task 3 roda ou não. **Parar e mostrar ao usuário** antes da Task 2 se o caminho de hooks exigir tocar `~/.cursor` ou o repositório. Commit `docs: cursor cli spike`.

### Task 2: Preset `cursor`

**Files:** Modify `Sources/OrqCore/Workspace.swift`, `Sources/OrqDaemonKit/{AgentLaunch,AttentionDetector,AskCoordinator,MaestroCommands}.swift`, `Sources/OrqProtocol/Commands.swift`, `Sources/OrqApp/TerminalSheet.swift` (e `Sources/OrqCore/Partitura.swift` se existir); Test `Tests/OrqDaemonKitTests/{AgentLaunchTests,AskTests,AttentionTests}.swift`, `Tests/OrqCoreTests/WorkspaceTests.swift`

**Interfaces:**
- Consumes: REPORT da Task 1 (nome do binário, textos de prompt).
- Produces: `Preset.cursor` (`rawValue "cursor"`); `Preset(from:)` tolerante: valor desconhecido → `.custom` (o `command` gravado continua; sem `command`, o terminal fica parado com o erro "custom preset needs a command", como hoje).
- `AgentLaunch.launchSpec`: `case .cursor: spec(["-lc", "command -v cursor-agent >/dev/null || { echo 'cursor-agent não encontrado — instale com: curl https://cursor.com/install -fsS | bash'; exit 127; }; exec cursor-agent"])` (nome do binário conforme o REPORT). Comando próprio em `rec.command` começando por `cursor-agent` vale como no Claude (permite flags extras, ex.: `--model`).
- `recruit`/`admin.spawn`/`admin.update`: aceitam `cursor`; mensagens e `help` passam a "shell|claude|codex|cursor|custom". `TerminalSheet`: opção "cursor" na lista; o botão de reiniciar-com-alterações vale para `cursor` como para `claude`/`codex`.
- Falha rápida: antes de lançar, o daemon roda `/bin/sh -lc 'command -v cursor-agent'` fora do pool (timeout 5 s); sem resultado → `.invalidArgs` "cursor-agent não encontrado (instale com: curl https://cursor.com/install -fsS | bash)" e nada criado.
- `AskCoordinator`: o grupo de conclusão por ociosidade passa a ser `shell || custom || cursor` (e continua respeitando `hookCapable`).
- `AttentionDetector`: lista própria do Cursor com os textos (b) e (c) do REPORT (minúsculas), além dos genéricos. Se o 3B estiver na `main`, as aprovações do painel Trabalho mapeiam esses pedidos para o `ApprovalKind` que bate com as teclas do REPORT (menu → Enter/Esc; s/n → `y`/`n`).
- Partituras (se o 3D estiver na `main`): `cursor` aceito na validação; a checagem prévia de `PATH` cobre `cursor-agent`.
- Uso: nenhum provedor novo (o painel não mostra Cursor) — a menos que o REPORT ache uma fonte sem credencial; nesse caso, um provedor declarativo como o do Codex em `DefaultUsageProviders` (mesmo formato, só leitura).
- [ ] **Step 1: Testes:** `cursorLaunchSpec` (o `-lc` contém o teste de `command -v` e `exec cursor-agent`; comando próprio `cursor-agent --model x` passa intacto); `missingBinaryFailsFast` (PATH sem `cursor-agent` → `.invalidArgs`, nenhum terminal no snapshot); `cursorAskCompletesOnIdle` (`cursor-agent` falso no PATH: script que imprime o prompt de pronto, lê uma linha, imprime resposta e volta ao prompt → `ask` volta com a resposta por ociosidade em < 5 s); `hookLatchSwitchesToHookOnly` (um `turn.completed` do terminal → próximos asks esperam hook); `cursorPromptsRaiseAttention` (falso imprime o texto (b) → badge `attention`); `unknownPresetDecodesAsCustom` (JSON de workspace com `"preset":"warp"` → carrega, terminal `custom`); `recruitAcceptsCursor`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "AgentLaunchTests|AskTests|AttentionTests|WorkspaceTests"`). **Step 5:** Commit `feat(agents): cursor preset`.

### Task 3: Hook de fim de turno (só se o spike achou um caminho por terminal)

**Files:** Modify `Sources/OrqDaemonKit/AgentLaunch.swift`, `Sources/orq/HookCommands.swift`, `Sources/OrqProtocol/HookPayload.swift`; Test `Tests/OrqDaemonKitTests/AgentLaunchTests.swift`, `Tests/OrqProtocolTests/HookParsingTests.swift`

Rodar **só** se o REPORT disse "sim" a hook por terminal sem tocar `~/.cursor` nem o repositório; senão marcar esta task como pulada no roteiro, com o motivo.

**Interfaces:**
- `AgentLaunch` grava `<hooksDir>/<id>.cursor.json` (0600) com o evento de fim de turno que o REPORT confirmou (`stop` ou `afterAgentResponse`) → `orq hook cursor-stop` (timeout 10) e aponta o CLI para ele pelo mecanismo achado (flag ou variável de ambiente só no `env` do terminal). `removeHooks` apaga também esse arquivo.
- `orq hook cursor-stop`: lê stdin, extrai a última mensagem do agente se o payload trouxer (`HookPayload.cursorStopMessage(_ json: Data) -> String?`, campos conforme o REPORT; ausente → nil), manda `turn.completed {source: "cursor", message}`; nunca imprime nem falha (como os hooks da v1).
- [ ] **Step 1: Testes:** `cursorHooksFileWritten` (conteúdo e permissão; caminho passado ao CLI pelo mecanismo do REPORT); `cursorStopMessageParsed` (fixture escrita à mão no formato do REPORT; JSON vazio/inválido → nil); `hookMakesTerminalHookCapable`.
- [ ] **Step 2–4:** FAIL → implementar → PASS. **Step 5:** Commit `feat(agents): cursor end-of-turn hook`.

### Task 4: Docs e verificação

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`; Create (scratchpad) `plan3e-checklist-visual.md`

- [ ] **Step 1:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde (anotar contagem).
- [ ] **Step 2:** README: preset Cursor (instalar e logar pelo próprio CLI; usa o plano do Cursor; resposta do `ask` por ociosidade ou hook conforme o spike; sem memória automática no início de sessão e registro de trabalho só por `orq work …`, como o Codex; sem painel de uso). Roteiro: 3E "em execução" (e Task 3 pulada, se for o caso).
- [ ] **Step 3:** Checklist humana: criar um terminal Cursor pelo app; Maestro recruta um Cursor e faz `ask` curto; pedido de permissão vira badge de atenção (e aparece no painel Trabalho, se o 3B já estiver na `main`); fechar e reabrir o app com o terminal Cursor no workspace.
- [ ] **Step 4:** Commit `docs: cursor preset`.
