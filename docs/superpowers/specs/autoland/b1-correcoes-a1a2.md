# B1: correções da revisão independente de A1 e A2

Leia `docs/superpowers/roadmap/2026-11-24-autoland/rev-a1a2.md`. Arquivos: `Sources/CollieDaemonKit/WorkLoopCommands.swift`, `Sources/CollieDaemonKit/Work/Persona.swift`, `Sources/CollieDaemonKit/PaddockCommands.swift`, `Sources/CollieProtocol/Commands.swift`, `Sources/collie/CLI.swift`, `Sources/CollieDaemonKit/WorkStatusText.swift` (ou onde `originLines` mora), testes (`FactoryRunProfileTests`, `PaddockFactoryTests`).

1. (major 1) O cartão de aprovação (`loopCardText`) mostra a revisão REAL: "(só X)" quando o perfil restringe as personas; "veto só por blocker (collie-work.json)" quando `threshold: blocker`; "sem revisão: --no-review desliga a do perfil" quando o perfil pede revisão e `--no-review` a desligou. Com `trustLoops` (sem cartão) a mesma informação vai para o aviso de início do laço. Teste.
2. (major 2) O filtro `only` NUNCA remove a `seguranca` quando a regra X4 a chama (como já acontece com a `correcao`); teste: perfil `["correcao","testes"]` e diff que toca `docs/fabrica/personas/**` ou um spec mantém a `seguranca`.
3. (minor 1) Arquivo presente e ignorado (inválido fora do `factory`, ou base ilegível) sempre avisa, citando que revisão, orçamento e tentativas do perfil também caíram; vale com `needed=false`. O aviso de `collie-work.json` não commitado também sai com `needed=false`.
4. (minor 2) Aviso do `guardrails.land`: só quando `land == factory-paddock` e o cercado NÃO tem a marca; no cercado marcado diz "auto-land ainda não existe (A4); segue manual". Atualize o comentário `ponytail:`.
5. (minor 3) `paddock factory on` roda o doctor sobre o perfil do commit HEAD (o que o laço lê), não da árvore; arquivo sujo (diferente de HEAD) recusa com uma linha. Teste: árvore com perfil bom e HEAD sem perfil recusa.
6. (minor 4) `paddock.create` vindo pelo MCP recusa o parâmetro `factory` (ou o tira do schema MCP): o spec diz "nunca por MCP". Teste.
7. (minor 5, 6) Mensagem do `work run` sem catálogo de personas quando é o perfil que liga a revisão: "factory.review do collie-work.json liga a revisão, mas não há personas em HEAD"; os nomes de `factory.review.personas` são validados contra o catálogo commitado como o `--personas`: nome desconhecido recusa antes do laço, com a lista disponível.
8. (minor 7) `paddock list` e `status` em texto incluem o `path`. (nits) o corte do orçamento (86400 para 43200) é dito em `work status`; `--no-review` mostra "revisão: desligada" no lugar de "origem revisão: flag".

Check: `scripts/check-autoland-loop.sh b1`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
