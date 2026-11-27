# wd2: máscara com leitura recente, rotação com pasta no lugar, hangup testado

Onda d da revisão final (`.collie/briefs/rev-device-flows-final.md`, achados 5, 7, 8, 9 e 10). Check: `scripts/check-device-flows-wd.sh wd2` (não o altere). Sem relógio real nem sleep (relógio injetável); só `swift test --filter`.

## O que construir
- Máscara: o texto de `device.text` só vai em claro se a leitura que o prova é **recente** (limite nomeado, ~2 s, relógio injetável) além de fresca por geração; senão refaz o dump antes (com o log ligado) ou mascara. Cobre toque fora do viewer (Simulator.app, aparelho físico, scrcpy externo).
- Rotação: uma pasta (ou outra coisa que não é arquivo regular) no lugar de `actions.1.jsonl` não deixa o log crescer sem limite nem inundar o stderr: remova a pasta vazia com `unlinkat(AT_REMOVEDIR)` ou, se não der, trunque o arquivo atual; uma linha de aviso por rotação falha, não por ação.
- Quem tinha `.collie/flows/enabled` (formato antigo): `device flow status` avisa que o registro foi movido e está desligado, com o comando para ligar.
- Teste de ponta a ponta do hangup: socket → roteador → `deviceRunCommand` → plano de 5 passos; o cliente desliga entre o 2º e o 3º e o 3º não executa (sem sleep).
- Documente em uma linha (comentário no código) que a 1ª leitura Android sai sem densidade.
## Critérios de aceite (testes em `FlowMaskFreshnessTests`, ≥ 6)
- Leitura com mais idade que o limite: `device.text` mascarado ou dump refeito; leitura recente e fresca: em claro. Toque externo simulado (tela mudou sem geração) mascara.
- Pasta no lugar de `.1`: rotação conclui, arquivo atual não passa do limite, uma só linha de aviso.
- `device flow status` com `enabled` antigo mostra o aviso.
- O teste do hangup liga socket e roteador.
- `FlowMaskRaceTests`, `FlowLogHardeningTests`, `FlowCancelTests` e `FlowSecureTests` continuam passando.
## Resultado
(o laço preenche)
