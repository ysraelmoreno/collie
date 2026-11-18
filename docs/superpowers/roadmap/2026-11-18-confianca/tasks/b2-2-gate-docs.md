# B2.2 Ensinar o portão

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b2-portao.md` (requisito 7). Depende de B2.1.

## Fazer

1. `Sources/CollieDaemonKit/Work/LoopCommand.swift` (texto do `/collie:loop`, constante em inglês): ao montar as
   tarefas, o que é comum a todas (build, lint, arquitetura) vai em `--gate`, e o check da tarefa mede só a tarefa.
   Manter a regra do arquivo: texto constante, nada interpolado.
2. `docs/referencia.md`, seção do laço: `--gate` na linha do `work run`, uma frase sobre veredito e cartão.
3. Linha nova nos updates do topo de `docs/superpowers/specs/2026-11-17-work-run-design.md`.

## Testes

`LoopCommandTests` (o texto cita `--gate`; continua sem interpolação).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
