# PRD C1: Cercas v1 — minerar, aprovar por arquivo, bloquear no fim do turno

PRD geral: `README.md`; esboço: `prd-c-cercas.md`. Cobre as fatias C1 (mineração), C2 (aprovação), C3 (bloqueio) e
C4 (catraca) do esboço. C5 (correção vira cerca) fica fora.

## Decisões minhas (o dono não respondeu; pode vetar)

1. **Aprovação por arquivo** (opção c do esboço): o dono copia a proposta para `cercas.json` na pasta de dados do
   plug-in. Sem peça nova no daemon nem no app. É a forma mais simples; uma tela vem depois, se o uso pedir.
2. **Limiar de import em 95%** na orientação do Vizinho (era 80%), por causa do ruído medido em
   `Tests/CollieDaemonKitTests` (144 de 173). "Falta teste par" continua em 80%.
3. **Sem medir uma semana antes**, a pedido do dono. O risco: cercas propostas sem saber quais orientações já
   bastavam.

## Onde ficam os arquivos

`$COLLIE_PLUGIN_DATA/<chave>/`, fora do projeto (o agente não alcança):

- `propostas.json`: escrito pelo plug-in; o dono só lê.
- `cercas.json`: escrito só pelo dono; o plug-in só lê (exceto o `baseline`, ver abaixo).

`<chave>`: os 16 primeiros hex do SHA-256 do caminho real da raiz do repositório. Num worktree (`.git` é arquivo com
`gitdir: …/.git/worktrees/<n>`), a raiz é a do repositório principal, para todos os cercados dividirem as cercas.
Sem `.git`: o caminho do projeto.

## Formato (os dois arquivos: um array JSON de cercas)

```json
{ "id": "forbid-import:Sources/ColliePlugins:Panel:CollieDaemonKit",
  "kind": "forbid-import",
  "dir": "Sources/ColliePlugins", "suffix": "Panel", "ext": "swift",
  "module": "CollieDaemonKit",
  "evidence": "0 de 11 importam CollieDaemonKit",
  "baseline": [] }
```

- `kind`: `forbid-import` | `require-import` | `require-test`. `module` só nos dois primeiros.
- `suffix`: `null` = todos os arquivos da pasta com a extensão.
- `id`: `kind:dir:suffix:module`, estável (o dono cola a cerca inteira; o id evita duplicata).
- `baseline`: arquivos (relativos ao projeto) que já quebram a cerca e são tolerados.

## Fazer (em `Sources/VizinhoKit/`, `Sources/collie-vizinho/main.swift`, `Tests/VizinhoKitTests/`,
`Examples/plugins/vizinho/collie-plugin.json`, `docs/plugins/api-v1.md` só se citar o Vizinho, `docs/feature-map.md`)

1. **Limiar**: fato "N de M importam X; este não importa" passa a exigir 95%. Ajustar os testes existentes.
2. **`Fence`** (`Fences.swift`): `Codable`, o formato acima; `Fences.load(_ url:) -> [Fence]` (arquivo ausente ou
   inválido: vazio, nunca erro).
3. **Mineração** (`Mining.swift`): `Mining.propose(project:) -> [Fence]`, reusando a leitura de irmãos e de imports
   do Vizinho (extrair o que for comum, sem duplicar):
   - grupo = pasta + extensão + sufixo, com pelo menos 10 arquivos;
   - `require-import`: módulo importado por ≥ 95% do grupo;
   - `require-test`: ≥ 95% do grupo tem teste par;
   - `forbid-import`: módulo que nenhum arquivo do grupo importa **e** que é importado por pelo menos 10 arquivos
     em outra parte do projeto **e** que é um módulo do próprio projeto (existe pasta ou arquivo com esse nome no
     projeto; nunca `Foundation` e afins);
   - `baseline` de cada proposta: os arquivos do grupo que hoje quebram a cerca (os até 5% restantes);
   - no máximo 50 propostas, ordenadas por tamanho do grupo; varredura limitada a 5000 arquivos e 3 s.
4. **Checagem** (`Fences.check(project:files:fences:) -> [Violation]`): para cada arquivo, as cercas cujo
   `dir`/`ext`/`suffix` casam; quebra = import proibido presente, import exigido ausente ou teste par ausente.
   Arquivo no `baseline` da cerca não quebra. Arquivo apagado ou ilegível: ignorado.
5. **Catraca**: quando um arquivo do `baseline` deixa de quebrar a cerca, a checagem o remove do `baseline` em
   `cercas.json` (única escrita do plug-in nesse arquivo; escrita atômica). O `baseline` nunca cresce sozinho.
6. **`Vizinho.respond`**:
   - `stop`: carrega `cercas.json`, checa os arquivos do turno; havendo quebra devolve `{"block": …}`:

     ```
     Cerca quebrada (aprovada pelo dono do projeto):
     - Sources/ColliePlugins/FooPanel.swift importa CollieDaemonKit; 0 de 11 arquivos *Panel.swift desta pasta importam.
       Causa raiz: o que você precisa de CollieDaemonKit deve chegar pelo que os irmãos usam. Modelo: Sources/ColliePlugins/DiagramPanel.swift
     ```

     no máximo 5 quebras e 1800 caracteres; sem quebra, `{}`.
   - `stop` também regrava `propostas.json` quando ele não existe ou tem mais de 24 h (propostas cujo `id` já está em
     `cercas.json` não entram). Falha ao escrever: ignorada.
   - `edit`: como hoje (orientação).
   - a pasta de dados vem de `COLLIE_PLUGIN_DATA`; ausente: sem cercas, sem propostas, só a orientação.
7. Manifesto do exemplo: `hooks: ["edit", "stop"]`. `ui/index.html`: mais duas linhas dizendo onde ficam
   `propostas.json` e `cercas.json` e como aprovar (copiar a cerca de um para o outro).
8. `docs/feature-map.md`: atualizar a entrada do Vizinho.

## Aceite

`VizinhoKitTests` (suítes novas `MiningTests`, `FencesTests` no mesmo alvo), com projetos em diretório temporário:

- mineração: cada um dos três tipos proposto com grupo de 10+; nada proposto com 9; `forbid-import` não propõe
  `Foundation` nem módulo usado por menos de 10 arquivos fora; `baseline` com os infratores atuais; limite de 50;
- checagem: cada tipo quebra e não quebra; arquivo no `baseline` não quebra; arquivo fora do grupo não é checado;
- catraca: arquivo corrigido sai do `baseline` no arquivo em disco; nenhum caminho o faz crescer;
- `respond(stop)`: bloqueia com o texto acima; sem `cercas.json` devolve `{}`; grava `propostas.json` quando falta
  e não regrava antes de 24 h; proposta já aprovada não reaparece;
- chave: dois worktrees do mesmo repositório dão a mesma chave (montar o `.git` arquivo no teste);
- limiar de 95% na orientação.

## Check

```
swift test --disable-sandbox --filter VizinhoKitTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova; `VizinhoKit` só importa Foundation e CryptoKit. Textos em português. Commit com mensagem convencional, só dos
seus arquivos; nada de push.
