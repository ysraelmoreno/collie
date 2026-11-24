# PRD A6: `ask`/`wait` bloqueantes no MCP do Cursor viram id + espera

PRD geral: `README.md` desta pasta (problema 5).

## Problema

Na rodada 1b o líder Cursor chamou a ferramenta MCP `ask` (bloqueante) para um worker. O cliente MCP do Cursor
desistiu antes (`-32001`, timeout da chamada) e o worker terminou normalmente depois; o líder só recuperou o resultado
com `check`. O Claude Code não tem esse problema: passa a chamada longa para segundo plano.

A orientação do Cursor (`CollieOrientation.swift`, linhas 82-92) ensina `collie ask <name> "<prompt>"` "to wait for the
reply" como primeira opção.

## Fazer

1. **Medir** o timeout de chamada de ferramenta MCP do `cursor-agent` 2026.11.22 (uma ferramenta que dorme 30/60/120 s
   num MCP de teste) e anotar no spike `docs/superpowers/spikes/2026-10-22-cursor/REPORT.md` (nova seção, com a versão).
2. `Sources/collie/MCPServer.swift`: quando o perfil (`memory.mcp-profile`, já buscado uma vez) diz que o agente é
   Cursor, `ask` sem `no-wait` vira `ask --no-wait`, e a resposta da ferramenta diz, em uma linha: o id, e que a resposta
   chega como mensagem ou por `collie ask result <id>`. `wait` com timeout acima de (timeout medido − 10 s) é cortado
   nesse valor e a resposta diz que ainda não terminou e como esperar de novo. Se o perfil não disser o agente, nada muda.
   Se a regra de conversão não couber no `MCPServer` sem teste, extrair a decisão como função pura num alvo testável
   (`CollieClient`), com a suíte `CursorMCPPolicyTests` em `Tests/CollieClientTests/`.
3. `CollieOrientation.swift`, só para `agent == "cursor"`: a linha dos agentes ligados ensina `--no-wait` + `ask result`
   como forma principal, dentro do limite de 1500 caracteres (os testes de comprimento da orientação continuam valendo).

## Aceite

- Perfil Cursor: `ask` sem `no-wait` volta na hora com o id (teste da função pura).
- Perfil Claude: igual a hoje (teste).
- Orientação Cursor (Pastor e não Pastor) dentro do limite e com `--no-wait` na linha dos agentes
  (`CollieOrientationTests`).

## Check

```
swift test --disable-sandbox --filter CollieOrientationTests && swift test --disable-sandbox --filter CursorMCPPolicyTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
