---
name: factory-plan
description: Do PRD aprovado do trabalho ativo, gera o rascunho do pacote de plano (waves.md e tasks/*.md com check, gate e aceite), roda o linter do Collie até passar e pede ao dono UMA aprovação do pacote. Use quando o dono pedir para planejar um PRD ("factory plan", "transformar o PRD em tarefas", "planejar o trabalho a partir do PRD").
---

# /collie:factory plan

Você transforma o PRD do trabalho ativo num pacote de plano que o laço do Collie roda. Fluxo inteiro: `COLLIE/docs/fabrica/plano.md`.
O Collie não fala com Jira, Linear nem GitHub: o PRD já está no trabalho, em markdown, guardado pelo dono.

Fontes (`COLLIE` é a raiz do repositório do Collie):
- o PRD: `collie work prd show` (texto, sha256, origem). Sem PRD: pare e peça ao dono `collie work prd add <arquivo.md> --origin <ref> --terminal <você>`.
- modelos: `COLLIE/docs/fabrica/modelos/plano/` (`waves.md`, `tasks/*.md`, `README.md` com os campos do cartão)
- aceite em runtime: `COLLIE/docs/fabrica/aceite.md`
- as áreas e o gate do projeto: `collie work config`

## Regras que não mudam

- **Você não aprova nem aplica.** `collie work plan apply` é do dono (CLI fora de terminal); você só entrega o pacote e o hash.
- **Nunca rode `collie work run`.** Nem depois da aprovação: o dono decide quando.
- Nada de push, release, tag nem land. Commit local do pacote só com o dono de acordo.
- Não invente requisito: o que o PRD não diz vira pergunta no fim, não tarefa.

## Passos

### 1. Ler o PRD

`collie work prd show`. Anote o sha256 (12 primeiros) e a origem; eles vão no topo do `waves.md`.

### 2. Rascunho do pacote

Numa pasta do projeto (padrão `docs/planos/<slug-do-prd>/`), copie o modelo e escreva:
- `waves.md`: `## Onda N` com `- <id>` de cada tarefa. Tarefa de uma onda depende de todas da anterior; ponha numa onda só o que pode andar junto. A linha `gate:` é o comando comum (lint, build), o mesmo `--gate` do `work run`.
- `tasks/<id>.md`, um por tarefa, **até 1500 caracteres**: `# título`, `check:` (ou `area:` do `collie-work.json`, nunca os dois), `scope:` quando souber os arquivos, `accept:` quando a tarefa tem tela ou serviço (o aceite sobe o que precisa e julga o resultado rodando), `needs:` só para ordem dentro da onda. Depois, o que fazer, "pronto quando" e o que fica fora.
- **Todo cartão cita o teste que prova a tarefa** (`LoginTests`, `test_login`, `login.test.ts`), e o `check:` roda esse teste. Um check que só faz `grep`, `test -f` ou `ls` no arquivo que a tarefa cria é recusado: ele passa sem o código funcionar.
- Cartão grande demais é tarefa grande demais: divida.

### 3. Linter até passar

```bash
collie work plan lint docs/planos/<slug>
```

Cada recusa vem com `arquivo:linha: [regra]`. Conserte e rode de novo até "Passou". Não afrouxe o check para passar: se não há teste para escrever, a tarefa não está pronta para o laço.

### 4. Uma aprovação do dono

Mostre ao dono, numa mensagem só: as ondas (ids e títulos), cada check e aceite, o que ficou fora e as perguntas abertas, e o comando com o hash que o linter imprimiu:

```bash
collie work plan apply docs/planos/<slug> --approve <sha256> --terminal <você>
```

Peça UMA aprovação do pacote inteiro. Se o dono pedir mudança, mude, rode o linter de novo e mostre o hash novo (o antigo deixa de valer: o `apply` recusa hash diferente do pacote).

Termine com: a pasta do pacote, o hash, o que o dono precisa rodar. O `apply` cria as tarefas e não inicia o laço; o `work run` é o passo seguinte do dono.
