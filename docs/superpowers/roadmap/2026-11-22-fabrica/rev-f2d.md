# Revisão independente da F2, quarta rodada (2026-11-23)

Diff: Z1 a Z3b (`d50b6a6..fc4d066`, 687 linhas). seguranca e motor-concorrencia (opus), instruídos a listar os canais tentados (`tried`). JSONs em `rev-f2d/`.
Os dois: reject, 4 de 4 anteriores corrigidos cada um. **Mesmo blocker, achado de forma independente.**

## Blocker: MCP de escopo usuário
O revisor sobe sem `--strict-mcp-config` (AgentLaunch.swift:140, "o MCP do usuário fica") e `~/.claude.json` é gravável por todo terminal strict (EssentialPaths.swift:25, R13, aceito para agentes comuns).
O julgado grava um `mcpServers` ali; o servidor roda no sandbox do revisor e suas instruções/ferramentas entram no prompt de sistema, fora da cerca do nonce. `plantedConfig` não olha esse arquivo.

## Major (seguranca): processo em segundo plano do julgado
`reapGroup` mata só o grupo do PTY; o Claude Code roda cada Bash num grupo próprio, então `nohup`/`&` sobrevive ao dismiss, troca arquivos da worktree que o revisor lê por uma versão limpa e restaura antes do `reviewTree` final: o revisor julga código que não é o commit.
Conserto robusto: o revisor lê uma CÓPIA SOMENTE LEITURA do commit julgado (git archive na pasta dele), não a worktree viva; mais matar a árvore de descendentes.

## Minors
- O revisor ainda tem o MCP collie (memory_search/get/list, lot_board) e está no lote do Shepherd: lê memória e posts do julgado. Mesmo conserto do blocker (MCP vazio) e fora do lote.
- pgid lido sem checar que o processo ainda roda: reuso de pid pode matar grupo de outro terminal (motor minor, seguranca nit).
- Mudança em `.claude/` feita pelo Shepherd na mesma worktree vira "o revisor mexeu" e é apagada sem cópia (falsa falha e perda de dado).
- Config de agente dentro de pasta dobrada pelo status (nit).
