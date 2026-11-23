# Revisão independente da F2, quinta rodada (2026-11-23)

Diff: laço W (`fc4d066..f4f2bff`, 464 linhas). Só seguranca (opus), refazendo todos os canais da rodada 4 e outros. 4 de 4 anteriores corrigidos; **reject** com 2 blockers, 4 minors. JSON em `rev-f2e/`.

## Blockers
1. **`~/.claude.json` continua gravável pelo julgado e o claude lê dele mais que mcpServers**: `env` global (volta `CLAUDE_CODE_DISABLE_AUTO_MEMORY=0`, ou `HTTPS_PROXY`+`NODE_EXTRA_CA_CERTS` para ler e reescrever o tráfego da API do revisor, nonce incluso) e `autoConnectIde` (lock em `~/.claude/ide`). W1 fechou só o mcpServers. A raiz é o arquivo, não a chave.
2. **O snapshot do W2 falha em todo laço real** (erro NOSSO, não de desenho): `git archive -o <reviewRoot>/...` roda por `loopGit` sob o perfil do laço, que nega leitura e escrita da raiz do daemon (`SandboxProfile.swift:269`). Todo revisor fica mudo e nenhuma tentativa é aprovada: falha fechada, motor travado. Os testes usam `LoopFakeHost` sem sandbox e não pegam.

## Minors
Órfão (nohup reparentado ao launchd) sobrevive ao reap; `memory.search/list/get` não checam `reviewerHooksBare` (o revisor tem token e collie no PATH); `moveItem/removeItem` por caminho (troca por symlink entre hash e operação: apaga `~/.ssh/config`); `git archive` honra `export-ignore` (revisor não vê o código).

## Leitura do processo
Quinta rodada, quinto canal. A cada rodada o revisor acha um canal que o julgado tem; os dois últimos (arquivo de config global, sandbox do próprio git) vieram de olhar COMO o claude e o daemon realmente se comportam, não do desenho. Os testes com host falso não exercitam o sandbox real: lacuna a fechar com teste que usa o perfil de verdade.
