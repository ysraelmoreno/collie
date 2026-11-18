# B1.3 Arquivos de evidência declarados

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b1-evidencia.md` (requisito 6). Depende de B1.1 e B1.2.

## Fazer

1. `collie work task add … --evidence <glob>` (e na ferramenta MCP `work_task_add`): `WorkTask.evidenceGlob: String?`.
   Glob relativo, sem `..`, sem caminho absoluto.
2. Na aprovação: arquivos que casam, dentro da worktree (resolver symlinks; fora → ignora), extensões
   `png|gif|jpg|mp4|txt|md`, total ≤ 20 MB (passou → para e anota). Cópia para `<root>/work-loops/<work>/evidence/<task>/`,
   dirs 0700, arquivos 0600. `TaskEvidence.files: [String]?` com os nomes copiados.
3. A cópia roda pelo host do laço (testável); nunca com mais acesso que o check.
4. Cartão: o glob aparece na entrada da tarefa. Painel: a tarefa feita lista os arquivos com ação "Abrir".

## Testes (escrever antes)

`WorkLoopTests` (copia o que casa; ignora symlink para fora; respeita teto), `WorkLoopCommandTests` (glob recusado com
`..`; cartão mostra glob), `WorkPanelTests` (lista de arquivos).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
