# M2.4 Orientação do Pastor e `/collie:loop`

Leia `onda2.md` e `README.md`. Depende de M2.3. Código: `Sources/CollieDaemonKit/Work/LoopCommand.swift` (o texto do `/collie:loop`), a orientação que o daemon injeta no início da sessão do Pastor (procure onde `collie work` e `collie summon` são ensinados: `Orientation*`, hooks de `sessionStart`), `Sources/CollieDaemonKit/Work/WorkStatusText.swift` (`loopEnded`, `taskEnded`: o texto dos avisos).

## Fazer

1. `/collie:loop` (os passos 5 e 6 do texto): depois do `collie work run`, **não esperar** o aviso `[collie] Laço…` no terminal. Para acompanhar: `collie work wait` (e de novo com `--since <versão>` que ele devolve) ou `collie work status`; o aviso digitado no terminal é só uma dica e pode não chegar. Ao ver `ended`/`laço terminou`, rodar `collie work status` e reportar o que passou, o que foi adiado e por quê (já era o passo 6). Manter tudo o mais do texto igual.
2. A orientação do Pastor tem a mesma frase curta (onde ela já ensina `collie work status`): "para esperar um laço, use `collie work wait`; não dependa de aviso no terminal".
3. Os avisos (`loopEnded`, `taskEnded`) ganham o final `· estado: collie work status` (uma vez, curto) para reforçar a leitura do estado. Não mude o resto do texto: testes e a regra de que um aviso não é lido como pergunta continuam valendo.
4. A skill `/collie:loop` mora também fora do repo? Procure uma cópia do texto em `plugins/`, `Resources/` ou na pasta de skills do projeto e mantenha todas as cópias iguais (um teste compara).

## Testes (escrever antes)

Em `WorkStatusTextTests` (e onde o texto de `LoopCommand` já tem teste): `/collie:loop` contém `collie work wait` e o aviso de que o texto digitado é só uma dica, e **não** contém a instrução antiga de esperar o aviso; a orientação do Pastor contém a frase nova; os avisos terminam com a dica de estado e continuam em uma linha; cópias do texto da skill idênticas.
