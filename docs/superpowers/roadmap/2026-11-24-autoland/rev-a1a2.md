# Revisão independente de A1 e A2 (`e324e0b0..ec100c95`)

Resultado: **approve, sem blocker**; A2: approve; A1: approve com 2 majors a corrigir antes da A4. Revisor opus, somente leitura; achados NÃO conferidos linha a linha por mim. Na A2 os 4 revisores do laço ficaram mudos: esta é a única revisão dela.

## A2: segurança da marca (canais fechados)
MCP (`exposedToMCP: false`); terminal de agente (`guard caller == nil`); Shepherd/leashed; `paddock create --factory` de agente; principal forjado (`adminOnly`); `paddock.status`/`land`/herd apply/import (`save(_:)` copia só `status` e `landedAt`; o herd cria sem `factory`); `workspace.json` editado à mão (o sandbox nega o diretório do Collie; terminal sem sandbox com mesmo uid é o teto já documentado de `adminOnly`, vale igual para `trustLoops`); decodificação tolerante (campo ausente ou ilegível = `false`); o doctor só lê arquivos.

## A1: perfil lido do commit base (HEAD por sha), precedência flag > perfil > padrão, `--review` com `--no-review` recusado, `factory` inválido recusa antes do cartão: corretos.

## Achados
- MAJOR 1: o cartão de aprovação não mostra a revisão vinda do perfil (`loopCardText`, `WorkLoopCommands.swift:347-348`): só "revisão por personas: auto" ou o flag. Não mostra `reviewOnly`, `reviewThreshold` nem que `--no-review` desligou uma revisão que o perfil pede.
  Cenário: um Shepherd commita `factory.review: {personas:["correcao"], threshold:"blocker"}` e roda `work run`; o dono aprova "auto" e só `correcao` roda e um major passa. Com `trustLoops` não há cartão nenhum. Correção: o cartão diz "(só X)" e "veto só por blocker (collie-work.json)"; com `--no-review` e perfil que pede revisão: "sem revisão: --no-review desliga a do perfil".
- MAJOR 2: o filtro `only` corta a `seguranca` da regra X4 (`Persona.swift:104`, `names.formIntersection(only)` depois das regras): perfil com `personas:["correcao","testes"]` e uma tentativa que altera `docs/fabrica/personas/**` ou o spec não passa pela `seguranca`, e o cartão não mostra. Correção: manter a `seguranca` quando a X4 disparar (como a `correcao`), ou recusar o perfil sem `seguranca` quando o catálogo a tem.
- MINOR 1 (`WorkLoopCommands.swift:171-186`): arquivo inválido fora do `factory` (gate com tipo errado, base ilegível) deixa `config` nil e o `factory.review` é ignorado sem aviso (com `needed=false` nenhum aviso; com `needed=true` o aviso não cita que revisão, orçamento e tentativas também caíram). Avisar sempre que um arquivo presente for ignorado e citar a revisão.
- MINOR 2 (`~121-124`): o aviso do `guardrails.land` ("o cercado não tem a marca de fábrica") sai sempre, mesmo em cercado marcado pela A2; `if factory.land == .factoryPaddock, !paddock.factory`, ou texto "auto-land ainda não existe (A4); segue manual".
- MINOR 3 (`PaddockCommands.swift:58` → `WorkConfigFile.config(root:)`): `paddock factory on` valida o perfil da ÁRVORE, não do commit: um agente deixa um `collie-work.json` não commitado que passa no doctor, o dono liga a marca, e a base que o laço lê (HEAD) não passaria. Rodar o doctor sobre o perfil de HEAD, ou recusar com o arquivo sujo.
- MINOR 4 (`Commands.swift:445`): `paddock.create` segue exposto ao MCP com o param `factory` no schema; dentro do Collie a chamada é recusada, mas fora (`collie mcp` sem `COLLIE_TOKEN`) a CLI usa o admin token e o create com a marca passa. O spec diz "nunca por MCP": recusar `factory` quando a chamada vem pelo MCP, ou tirar o param do schema MCP.
- MINOR 5 (`WorkLoopCommands.swift:243`): com o perfil ligando a revisão e sem personas em HEAD, o `work run` recusa com "--review: sem personas…" sem o usuário ter passado `--review`; dizer "factory.review do collie-work.json liga a revisão…".
- MINOR 6 (`:119`): os nomes de `factory.review.personas` não são validados contra o catálogo (o flag `--personas` é, na linha 246); "segurança" com ç zera a interseção e roda só a `correcao` em silêncio.
- MINOR 7 (`CLI.swift:187-189`): `paddock list` e `status` em texto perderam o `path` (antes saía o JSON; `docs/referencia.md:1176` diz que traz caminhos); incluir o `path` na linha.
- NIT: o orçamento do perfil é cortado de 86400 para 43200 em silêncio (`:104`; `work status` diz "origem orçamento: perfil" sem citar o corte); `originLines` com `--no-review` mostra "origem revisão: flag" sem dizer que a revisão está desligada.

Não verificado: testes e build, `adminOnly` na prática, `RemoteSurface` (celular), o perfil SBPL real, o lado do app (`DaemonClient.createPaddock` não envia `factory`; é a A3).
