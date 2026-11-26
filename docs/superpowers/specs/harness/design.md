# Harness de desenvolvimento fora de laço: design

Status: rascunho (2026-11-26). Pedido do dono: melhorar a harness normal (pre-check, check e outras formas) para o desenvolvimento fora de laço ou fábrica, valendo para **Claude e Cursor**, com o **dev definindo bloqueios e guardrails** no `collie-work.json`.

## Hoje
`gate`, `precheck`, `smoke` e `areas` do `collie-work.json` só valem em laço. Não há hook de git no repositório. A única coisa que chega a uma sessão comum é a injeção de memória. `factory.guardrails.destructive` só avisa. Fora de laço o agente depende de lembrar de rodar os checks.

## Camadas
1. **Pre-check** (início da sessão): estado do ambiente (árvore, daemon instalado versus checkout, laço rodando, build). Contexto, não bloqueia.
2. **Check na edição**: lint/arquitetura nos arquivos tocados, rápido (< 2 s).
3. **Check no fim do turno**: `smoke` mais as `areas` dos arquivos alterados.
4. **Gate no commit e no push** (hooks de git gerenciados) e `guardrails.deny`.
5. **`collie verify`**: gate, áreas e checks do diff, sob demanda, gravando evidência.

## Configuração (`harness` no collie-work.json)
Modos por regra: `advisory` avisa o agente, `ask` abre um cartão para o usuário no app, `block` recusa. `protect` impede o agente de editar os próprios checks. O daemon lê a versão **commitada** do arquivo (o agente não afrouxa a regra na mesma sessão). Veja `h1.md` para a forma exata.

## O que bloqueia de verdade
Base independente do agente: hooks de git (valem para Claude, Cursor e para o dev) e o daemon. Os hooks do agente são feedback mais rápido: Claude (`PreToolUse`, `Stop`, `PostToolUse`), Cursor (`preToolUse`/`postToolUse`; sem hook de fim de turno). O spike (`spike.md`) mede o que cada mecanismo realmente respeita antes de a spec de hooks ser escrita.

## Ordem
Spike → h1 (schema) → h2 (casador) → h3 (`work.config` e `harness.explain`) → depois, com o relatório do spike: hooks de git, hooks de agente, `collie verify`, pre-check.

## Não metas
Alterar a harness por comando de agente. Bloquear por padrão: tudo começa `advisory`. Rodar testes pesados na edição.
