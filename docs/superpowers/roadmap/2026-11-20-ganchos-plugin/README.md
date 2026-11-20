# PRD geral: ganchos de agente para plug-ins ("Vizinho" e "Cercas")

Data: 2026-11-20. Estado: caminho escolhido pelo dono na conversa (plug-in com `hooks`, não lógica no daemon).

## Problema

Hoje o agente só segue um padrão do projeto se alguém o escreveu como regra em texto (memória, CLAUDE.md). Texto
não é cobrado por máquina, o dono precisa lembrar de escrever, e agentes mais fracos ignoram ou interpretam mal.
A palestra que motivou isto: a codebase é a maior entrada do agente; correção deve virar verificação determinística,
não mais uma linha de regra.

O Collie já tem peças soltas (`memory enforce`, `work task add --check`, a catraca de `scripts/ci/lint.sh`), mas
nenhuma infere o padrão da codebase nem conduz o agente na hora da edição.

## Objetivo

1. **Ponto de extensão no daemon**: um plug-in externo declara `hooks` e um `helper`; o daemon entrega a ele os
   eventos do agente (arquivo editado, fim de turno) e devolve ao agente a resposta (orientar ou bloquear).
2. **Plug-in "Vizinho"** (A): sem configuração, ao editar um arquivo o agente recebe a forma que os arquivos irmãos
   seguem, tirada da própria codebase.
3. **Plug-in "Cercas"** (B, onda posterior): convenções quase unânimes viram propostas; aprovadas pelo dono, passam
   a bloquear.

A lógica de padrões mora no plug-in, que o usuário instala no Collie dele. O daemon só conhece o contrato.

## Não-objetivos

- Cursor e Codex nesta entrega. Só terminais Claude (o gancho de edição do Cursor não foi verificado).
- Helper de vida longa (JSON-RPC). Um processo por evento; ver "Decisões minhas".
- Comandos `runs: "helper"`, rede para helper, escrita no projeto.
- Distribuição assinada (`.collieplugin`), catálogo.
- Revisor por LLM. Tudo aqui é determinístico.

## Anti-objetivos

- O agente conseguir instalar, alterar ou desligar o que o julga.
- O gancho atrasar ou quebrar o agente: qualquer falha do helper é silêncio (fail open), nunca erro para o agente.
- O plug-in ver o pedido do usuário ou o conteúdo da conversa (decisão 1 do design de plug-ins): recebe só caminhos.

## Contrato (apiVersion 1, chaves novas)

Manifesto:

```json
{ "helper": "bin/vizinho",
  "hooks": ["edit", "stop"],
  "permissions": { "project": "read" } }
```

Evento, no stdin do helper (um JSON, depois EOF):

```json
{ "apiVersion": 1, "event": "edit", "project": "/abs/worktree", "files": ["Sources/X/FooPanel.swift"],
  "agent": "claude", "paddock": "nome" }
```

- `edit`: depois de uma ferramenta de escrita do agente; `files` são os arquivos escritos, relativos a `project`.
- `stop`: fim de turno; `files` são os arquivos escritos no turno (sem repetição).

Resposta, no stdout (um JSON; vazio ou `{}` = nada):

```json
{ "guide": "texto para o agente" }
{ "block": "motivo e a causa raiz a atacar" }
```

- `edit`: `guide` chega ao agente como contexto; `block` chega como bloqueio da ferramenta.
- `stop`: `block` impede o fim do turno uma vez (um Stop continuado nunca é bloqueado de novo); `guide` é ignorado.
- Texto: no máximo 2000 caracteres por plug-in, 4000 somados; o excesso é cortado.
- Prazo: 3 s por evento, todos os plug-ins juntos. Estouro, exit ≠ 0 ou JSON inválido: ignorado, uma linha em log.

Sandbox do helper: `(deny default)`; lê o projeto e a própria pasta; escreve só em `<root>/plugins-data/<id>/`;
sem rede; sem ler o home.

## Decisões minhas (o dono pode vetar)

1. **Um processo por evento**, não helper de vida longa. Reusa `BoundedProcess`; sem ciclo de vida para gerenciar.
   O cache é do plug-in (na pasta de dados dele). Trocar por JSON-RPC quando a latência medida pedir.
2. **Helper sem exigência de assinatura de código** nesta fase. O design de 2026-10-25 pede binário assinado; aqui
   a pasta é fixada por SHA-256, somente leitura, instalada só pelo usuário e roda em sandbox. A assinatura volta
   na fase de distribuição. Sem isso o usuário não consegue escrever o próprio helper como script.
3. **Vizinho compilado em Swift**, lógica num alvo próprio (`VizinhoKit`) sem dependência do Collie, para ter teste
   e partida rápida. Python não existe em todo Mac.
4. **`ui` continua obrigatório** no manifesto. O Vizinho traz uma página mínima; mexer nisso tocaria o app inteiro.

## Medida de resultado

- Num terminal Claude com o Vizinho instalado, criar um `*Panel.swift` novo devolve a orientação com o arquivo
  modelo, sem nenhuma regra escrita.
- Helper que trava ou falha: o agente não percebe (teste).
- Depois de 7 dias: `repeatCorrections` de `collie memory stats` não sobe e há orientações entregues no log.

## PRDs e ondas

Cada PRD tem seu check; todos passam também pelo portão comum:

```
scripts/ci/lint.sh && scripts/ci/check-architecture.sh
```

| Onda | PRD | O quê | Depende de |
|---|---|---|---|
| 1 | [G1](prd-g1-manifesto.md) | manifesto aceita `helper`, `hooks`, `project: read` | — |
| 1 | [G2](prd-g2-contrato.md) | tipos puros do contrato: evento, veredito, saída para o Claude | — |
| 1 | [G3](prd-g3-sandbox.md) | perfil de sandbox do helper | — |
| 1 | [V1](prd-v1-vizinho-kit.md) | `VizinhoKit`: a orientação a partir dos irmãos | — |
| 2 | [G4](prd-g4-executor.md) | executor no daemon e comando `plugin.hook` | G1, G2, G3 |
| 2 | [G5](prd-g5-ganchos-claude.md) | `collie hook claude-tool` / `claude-stop` imprimem a resposta | G2 |
| 2 | [G6](prd-g6-instalacao.md) | instalação mostra as permissões; `plugin list`; docs | G1 |
| 3 | [V2](prd-v2-vizinho-plugin.md) | plug-in Vizinho empacotado e teste de ponta a ponta | G4, G5, V1 |
| 4 | [C](prd-c-cercas.md) | Cercas: convenção minerada vira bloqueio (a detalhar) | V2 |

As tarefas de uma mesma onda tocam arquivos diferentes e rodam em paralelo, cada uma num terminal.
