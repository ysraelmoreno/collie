# A6: aviso de fim e resumo imutável do auto-land

Depende de A4 e A5. Cada execução com `--auto-land` termina com um resumo que o dono lê e que ninguém (nem agente) reescreve depois.

## Comportamento
1. Ao fim da execução (qualquer `stopReason`), grave `.collie/autoland/<AAAA-MM-DD-HHMMSS>.md` no cercado... **no diretório de estado do daemon do cercado, NÃO na árvore do agente** (mesmo cuidado do ratchet: o agente não escreve onde o dono lê para decidir). Use a pasta de estado que o `LoopJournal` já usa. O arquivo é criado com `O_EXCL` e permissão somente leitura (0444); nunca sobrescreve.
2. Conteúdo: hora e duração; `stopReason`; por trabalho integrado: título, tarefas, commit anterior da base e novo, nota do doctor no momento, quem vetou o quê (persona, arquivo:linha) e quem aprovou, tentativas gastas, tempo e a linha exata para reverter (`git -C <base> reset --hard <anterior>` como TEXTO, nunca executado); o que NÃO foi feito
   ("sem push; pronto para você revisar e dar push"); o `stopReason` da falha com as condições que passaram e a que parou.
3. `notify` ao dono no fim: uma linha (`integrou N trabalhos` ou `parou em <stopReason>`) com o caminho do resumo. `work summary` e o cartão do app mostram o mesmo resumo.
4. Segredos: o texto passa pelo mesmo `scrub` das notas; nada de telas cruas do agente (só as linhas já limpas e prefixadas do C1).

## Testes
Resumo escrito uma vez, 0444, no diretório de estado; segundo write com o mesmo nome falha (não sobrescreve); conteúdo traz commits, revisões e a linha de reversão; falha de land traz a condição que parou; segredo no texto não aparece. Sem terminais reais.

Check: `scripts/check-autoland-loop.sh a6`. Commit ao final, só os arquivos da tarefa.

Nome obrigatório da suíte: `AutoLandSummaryTests` (arquivo novo em `Tests/CollieDaemonKitTests`).
