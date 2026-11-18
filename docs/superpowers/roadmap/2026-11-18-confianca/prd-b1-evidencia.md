# PRD B1: evidência por tarefa do laço

## Problema

Quando `collie work run` termina, o dono recebe "terminou" e uma lista de tarefas `done`/`deferred`. Para saber o que
cada tarefa fez, precisa abrir o git e reler o código. A palestra: "a revisão encolheu para olhar artefatos de
verificação" (diff, saída de teste, capturas, vídeos). Hoje o laço já tem tudo isso na mão no momento do veredito
(`WorkLoop.attempt`: `before`, `HEAD`, saída do check) e joga fora no caso de sucesso.

## Objetivo

Cada tarefa aprovada pelo laço guarda a evidência do veredito, e o dono a vê sem abrir o git: no `work status`, no
painel do trabalho e no aviso de fim de laço.

## Não-objetivos

- Gerar capturas ou vídeos pelo laço (quem gera é a tarefa; o laço só coleta, em B1.3).
- Mudar a regra do veredito.

## Requisitos

1. `WorkTask` ganha `evidence: TaskEvidence?` (opcional; arquivos antigos decodificam):
   `commits: [String]` (`git log --format='%h %s' before..HEAD`, até 20), `shortstat: String`
   (`git diff --shortstat before HEAD`), `checkTail: String` (últimas 20 linhas da saída do check, mesma limpeza de
   segredos de `LotBoards.scrub`, ≤ 2000 caracteres), `seconds: Int` (duração da tentativa), `attempt: Int`.
2. Gravado só quando a tentativa passa. Falha continua indo para as notas, como hoje.
3. `work status` (texto) mostra por tarefa feita: `✓ <título> · tentativa n · <k> commits · <shortstat>`.
4. Painel do trabalho: a tarefa feita mostra commits, shortstat e a cauda do check (expansível).
5. Aviso de fim de laço ao Pastor: uma linha por tarefa (feita com commits e shortstat; adiada com a razão).
6. **B1.3, onda 5:** `work task add … --evidence <glob>` (relativo à worktree, só arquivos dentro dela, sem symlink
   para fora; `png|gif|jpg|mp4|txt|md`, ≤ 20 MB no total). Na aprovação, o laço copia os que existem para
   `<root>/work-loops/<work>/evidence/<task>/` (0700/0600) e o painel lista com ação "Abrir". O glob aparece no cartão.

## Medida de resultado

- O dono revisa uma onda inteira deste roadmap sem rodar `git log` (pergunta ao dono depois da onda 3).

## Tarefas

- B1.1 gravar a evidência (`tasks/b1-1-evidence-record.md`)
- B1.2 mostrar no status, painel e aviso (`tasks/b1-2-evidence-show.md`)
- B1.3 arquivos de evidência declarados pela tarefa (`tasks/b1-3-evidence-files.md`), onda 5
