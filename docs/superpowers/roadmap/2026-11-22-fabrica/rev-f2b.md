# Revisão independente da F2, segunda rodada (2026-11-22)

Diff revisado: o conserto X1 a X5 (`0f64e5e..f5453f2`, 20 arquivos, +779 -146). Mesmos 5 revisores por persona; cada um diz se cada achado SEU da primeira rodada foi corrigido ou ficou
aberto (`previous`) e procura falhas novas. Veredito agregado: **recusado de novo, por um blocker novo**. JSONs em `rev-f2b/`.

| Persona (modelo) | Veredito | Anteriores | Novos |
|---|---|---|---|
| correcao (sonnet) | approve | 7 de 7 corrigidos | 1 minor |
| testes (sonnet) | approve | 7 de 7 corrigidos | 3 minor/nit |
| simplicidade (haiku) | approve | 3 corrigidos, 4 abertos (minor) | 9 minor/nit |
| seguranca (opus) | reject | 4 de 4 corrigidos | 1 blocker, 1 minor |
| motor-concorrencia (opus) | reject | 6 corrigidos, 1 aberto | 1 blocker (o mesmo), 3 minor |

## O blocker (achado por DUAS personas, confirmado no código)
`reviewScratch` (WorkLoopReview.swift:34) cria a pasta do revisor em `FileManager.temporaryDirectory/collie-review/<nome>-<8hex>`, caminho previsível dentro do `DARWIN_USER_TEMP_DIR`,
que o perfil de sandbox de TODO terminal escreve (SandboxProfile.swift:166: `allow file-write* sub(real(i.userTemp))`), inclusive o do agente julgado. Ele pode plantar `$TMPDIR/collie-review/CLAUDE.md`
(o Claude Code carrega o CLAUDE.md dos ancestrais do cwd) ou trocar `collie-review` por um symlink para a worktree. O revisor volta a carregar instruções de quem trabalhou: o mesmo furo que o X1 devia fechar,
agora pela pasta temporária. O teste do X1 só conferia que o cwd em si estava vazio.

## Majors e minors que valem corrigir junto
- 'o revisor mexeu na árvore' conta como recusa de revisão (`reviewRejects += 1`) e pode adiar a tarefa como 'recusada duas vezes' sem a tarefa ter sido julgada: tratar como o orçamento esgotado.
- Falha depois do launch (`ensurePaddock`) tira o revisor de `loopReviewers` mas o terminal continua vivo e passa a contar como 'outro agente trabalhando' até o próximo início do daemon.
- A contagem de linhas roda um `git show` por arquivo, sem teto de caminhos nem de bytes, antes de os revisores subirem; e ignora `truncated` (nota falsa 'linha N não existe').
- `reviewTree` usa `status --porcelain` sem `--ignored`: um revisor com grant de escrita do lote pode deixar `.claude/settings.local.json` ou `CLAUDE.local.md` ignorados na worktree.
- Testes: `wait` sem `.timeLimit` em dois testes; a varredura de início só é testada no filtro puro; o defer da marca do revisor sem teste.
- Simplicidade (todos minor): `PersonaRun` repete `PersonaVerdict`, dois contadores de linhas, dois leitores de personas, contrato em duas fontes, glob em dois lugares. Aceitos por ora, exceto o que o laço tocar de passagem.
