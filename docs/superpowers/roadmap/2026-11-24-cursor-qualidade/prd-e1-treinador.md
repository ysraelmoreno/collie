# PRD E1: plug-in Treinador (a detalhar)

PRD geral: `README.md` desta pasta. Depende de D1 (eventos do Cursor no contrato) e C1 (ask com portão).

Plug-in externo no contrato dos ganchos (`docs/superpowers/roadmap/2026-11-20-ganchos-plugin/README.md`), como o
Vizinho: determinístico, sem LLM, instalado pelo usuário, o agente não o altera. A política para agentes fracos mora
aqui; o daemon só entrega eventos e vereditos.

## Ideias a detalhar

1. **Escopo da tarefa (`edit`).** Arquivo escrito fora do escopo declarado (o spec do ask com portão ou da tarefa do
   laço lista os arquivos) → `block` com o escopo. Precisa que o evento traga o escopo: mudança de contrato, decidir aqui.
2. **Suíte inteira (`edit`/ferramenta de shell).** Comando de teste sem filtro (regra do repo, `swift test` sem
   `--filter`) → `block`. Depende do evento de shell, que o contrato v1 não tem.
3. **"Pronto" sem check (`stop`).** Turno que termina sem ter rodado o check do ask/da tarefa → `block` uma vez,
   "rode o check antes de encerrar". Precisa que o evento traga se o check rodou: decidir aqui.
4. **Revisão vira caso.** Um formato fixo para o reviewer (`CASO: <entrada> -> <esperado>`) que o Treinador transforma
   em assert e acrescenta ao check do ask. Exige que o plug-in escreva no registro do ask: hoje o contrato não permite
   (o plug-in só lê o projeto). Avaliar se isso fica no daemon (C1) em vez do plug-in.

## Medida

Repetir a rodada 2 de referência (README) com o Treinador instalado: o builder não termina sem tratar o caso que o
reviewer marcou.

## Antes de virar PRD de verdade

Rodar D1 e C1, medir uma semana de uso com Composer 2.5 e escolher, entre as quatro, as que o uso mostrou que fazem
falta.
