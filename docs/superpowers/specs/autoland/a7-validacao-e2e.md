# A7: validação ponta a ponta do auto-land

Roadmap: `docs/superpowers/roadmap/2026-11-24-autoland/README.md`. Roda DEPOIS do segundo bundle instalado, num
repositório git temporário FORA deste repo (`mktemp -d`), com um remoto `file://` bare só para provar que nada sobe. Nunca
toca este repositório nem a main dele. Até esta spec rodar, o auto-land e a fábrica são **preview** (veja o CHANGELOG
`[0.2.0]` e `docs/fabrica/auto-land.md`).

Os comandos abaixo são os da CLI de hoje (`collie work run --help`, `collie paddock --help`). O script
`scripts/check-autoland-e2e.sh` AINDA NÃO EXISTE: é entregável desta tarefa (existe só `scripts/check-autoland-loop.sh`,
que roda os testes do laço, não este roteiro).

## Preparação (`scripts/check-autoland-e2e.sh prepare`)
- `git init` com 1 commit; `collie-work.json` com `gate` (um script que roda o `test.sh` do projeto), bloco `factory`
  (`review` com 2 personas simples, `guardrails` com `autoLandPerDay: 3`, `autoland` com `ci` e `timeoutSeconds`) e
  `scripts/ci/run-tests.sh`; `test.sh` verde; remoto bare `origin` configurado.
- Criar o cercado, como dono: `collie paddock create e2e-fabrica --repo <repo> --factory`; conferir com
  `collie paddock status e2e-fabrica` e `collie factory doctor` (precisa passar o mínimo: static e judge >= 1).
- Cada cenário: `collie work start "<titulo>"`, `collie work task add "<t>" --spec <arq> --check "<cmd>" [--accept "<cmd>"]`
  e `collie work run --max <n> --auto-land [--auto-land-max N] [--queue]` a partir do terminal do Pastor do cercado,
  com a confirmação do dono no cartão do app. Leituras: `collie work status --events`, `collie work summary`.

## Cenários (cada um um trabalho com 1 ou 2 tarefas pequenas)
1. **Verde, `landed`:** tarefa que adiciona uma função com teste. Esperado: `stopReason` `landed`, merge na base, resumo
   imutável (0444, na pasta de estado do daemon, `work-loops/<trabalho>/autoland/`) com base antes/depois e a linha
   `git -C <base> reset --hard <antes>`, `git -C origin log` SEM novos commits (nenhum push), notify enviado.
2. **Portão vermelho, `landGateRed`:** a tarefa passa no `--check`, mas o gate falha (teste do projeto quebrado por ela).
   Esperado: nada integrado, base intacta.
3. **Veto de revisão, `landReviewVeto`:** isca com bug real pedido na spec (como a isca f2f de `docs/fabrica/iscas/`).
   Esperado: a tentativa seguinte corrige e depois há land; se as tentativas esgotam, `landReviewVeto`/tarefa deferida.
   Também: parecer mudo (reviewer sem resposta) NÃO aprova.
4. **Conflito, `landConflict` (ou `landBaseMoved`):** a base ganha um commit antes do land. Esperado: `landBaseMoved`
   quando a base andou desde o início da execução; `landConflict` quando o merge em si falha. Em ambos, a base mantém o
   commit externo e nada se perde.
5. **Aceite:** tarefa com `--accept` vermelho: a tentativa falha (`acceptFailed` no diário) e, se esgotar, não há land;
   forçando o caso de aceite que passou e depois ficou vermelho, `landAcceptRed`. Com `--accept` verde: `landed`, e o
   resumo mostra o resultado do aceite. Trabalho sem `--accept`: o resumo diz "sem aceite em runtime".
6. **Fila:** 2 trabalhos aprovados com `--queue`; `--auto-land-max 2` integra os dois em sequência; com fila vazia e teto
   livre o fim é `queueEmpty`; `--auto-land-max 1` integra um só e termina `maxReached` (com um na fila) ou `landed`
   (fila vazia).
7. **Teto diário:** `autoLandPerDay: 1`: o 2º land do dia para com `landDailyCap`; reabrir o trabalho e rodar de novo
   NÃO zera o teto (contado em `Paddock.autoLands`, 24 h).
8. **Recusas:** `--auto-land` em cercado NÃO fábrica; sem `gate` no perfil commitado; com `--no-review`;
   `collie paddock factory e2e-fabrica on|off` por MCP e por terminal de agente (recusado, marca intacta);
   `landNothing` num trabalho sem commits novos; `landDoctorRegressed` com o perfil piorado antes do 2º trabalho da fila.
9. **Parada pelo dono:** `collie work stop` durante o CI do land e durante o encadeamento: nada integrado depois do
   pedido (`requested`); trabalho da fila parado sai da fila e segue aprovado.
10. **Adulteração:** o agente edita `collie-work.json` ou o script de CI no cercado: o land recusa com `landGateRed`
    ("o agente alterou ... que julga o land").

## Saída
`scripts/check-autoland-e2e.sh` imprime uma tabela cenário, esperado, obtido, e sai 1 se algum divergir; guarda o diário
(`work status --events 100`), o resumo e o `git log` de cada cenário em
`docs/superpowers/roadmap/2026-11-24-autoland/a7-evidencia/` (sem segredos). Achado vira cartão do Quadro e tarefa de
correção (laço); depois o cenário repete. Só com todos verdes a fábrica sai de "preview" no CHANGELOG.
