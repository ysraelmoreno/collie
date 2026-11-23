---
name: factory-init
description: Monta a fábrica do Collie num projeto (/collie:factory init) - detecta a stack, entrevista o dono, gera collie-work.json, checks, personas e CI a partir dos modelos versionados sem sobrescrever nada, cria o baseline da catraca, roda o doutor e termina com uma tarefa piloto. Use quando o dono pedir para preparar um projeto para o laço do Collie ("factory init", "montar a fábrica", "preparar o projeto para o collie work run").
---

# /collie:factory init

Você prepara o projeto do dono para o laço autônomo do Collie. Spec: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U2.
O que vale aqui: **o Collie garante o isolamento do juiz, não a força dos checks.** Seu trabalho é deixar checks fortes no repositório do dono.

Fontes (no repositório do Collie, `COLLIE` abaixo é a raiz dele):
- detector: `COLLIE/scripts/factory-detect.sh`
- modelos por stack: `COLLIE/docs/fabrica/modelos/<swift|node|python>/` (`profile.json`, `scripts/check-feature.sh`, `ci.yml`, `README.md`)
- personas padrão: `COLLIE/docs/fabrica/personas/*.md` (as mesmas que o `collie work run --review` lê)

## Regras que não mudam

- **Nunca sobrescreva arquivo existente.** Se o destino existe: mostre o diff (`diff -u <existente> <modelo>`), pergunte, e só então mescle o que o dono aprovar.
- **Nunca faça push, release, tag nem land.** Commits locais só com o dono de acordo.
- Uma pergunta por vez. Se o dono não souber, use o valor do modelo e diga qual foi.
- Não invente comando: todo comando que for para o `collie-work.json` precisa rodar no projeto (rode uma vez e mostre a saída antes de gravar).
- Um check mede **só a própria tarefa** e **nunca só compila**: roda os testes da tarefa e falha quando nenhum teste rodou.

## Roteiro

### 1. Detectar

```bash
COLLIE/scripts/factory-detect.sh .
```

Mostre `stack`, `stacks`, `testRunner`, `linter`, `formatter`, `ci` e `existing` em poucas linhas e pergunte: "está certo?".
- `unknown` ou stack sem modelo (`kotlin`, `flutter`, `rust`, `go`): siga com o modelo mais próximo como referência de forma e
  troque os comandos pelos que o dono confirmar (`tools.<stack>` do detector já sugere `testRunner`/`linter`).
- Várias stacks (monorepo): pergunte qual é a principal; as outras viram `areas`.
- `testRunner` nulo: o projeto não tem teste rodável. Pare e combine com o dono o primeiro teste antes de seguir; sem teste não há gate.

### 2. Entrevista curta (uma pergunta por vez)

1. **O que nunca pode quebrar?** Vira áreas (`areas.<nome>`), cenários (`factory.verification.scenarios`) e, se for regra estrutural, `factory.static.architecture`.
2. **Quanto o gate pode levar?** Rode o gate e meça. Mais lento que o aceito: proponha `precheck` rápido e `areas` por parte. Vira `factory.guardrails.budgetSeconds` (60 a 86400).
3. **Quais ações são destrutivas?** (apagar dado, deploy, publicar pacote, migração) Vira `factory.guardrails.destructive`.
4. **Há aparelho ou navegador para verificar?** Sim: um cenário por área de UI em `factory.verification.scenarios`. Não: registre que a camada de verificação fica fraca.
5. **Política de land:** `manual` (o dono revisa e integra, padrão) ou `factory-paddock`. Vira `factory.guardrails.land`.

### 3. Gerar a partir do modelo (sem sobrescrever)

Para cada item, só se o destino **não existe**; se existe, diff + pergunta:
- `collie-work.json`: do `profile.json` do modelo com as respostas da entrevista. Já existe: mescle só a chave `factory` e as chaves que faltam; nunca troque o `gate` do dono sem ele dizer.
- `scripts/check-feature.sh` (e um `scripts/check-<tipo>.sh` por tipo de tarefa que o dono citar), executável.
- `docs/fabrica/personas/*.md`: copie as personas padrão; os nomes vão em `factory.review.personas`. O dono pode editar.
- `.github/workflows/ci.yml`: só quando `ci` veio vazio no detector; o CI roda o mesmo comando do `gate`.

Valide o arquivo antes de seguir: `collie factory doctor` recusa um `collie-work.json` inválido com o caminho do erro; conserte até passar.

### 4. Baseline da catraca

Para cada catraca em `factory.static.ratchets` (o modelo traz `todo`):

```bash
collie factory ratchet update <nome>    # grava o baseline inicial (o arquivo em 'baseline')
collie factory ratchet check <nome>     # tem que passar logo em seguida
```

O baseline entra no repositório. Subir o número depois só com `collie factory ratchet raise <nome> --reason "..."`.

### 5. Doutor

```bash
collie factory doctor
```

Mostre a tabela. Toda camada FRACO (0 ou 1): leia a próxima ação (→) e resolva com o dono agora, ou registre por que fica para depois.
Meta mínima para sair daqui: `static` >= 2 (o gate roda testes) e `judge` >= 2.

### 6. Tarefa piloto

Uma mudança trivial **com check**, para calibrar o gate e mostrar o ciclo inteiro antes de uso real. Exemplo: uma função pequena e o teste dela.
Escreva o spec da tarefa em uma linha, o `--check` com `scripts/check-feature.sh <o teste novo>`, e rode via `/collie:loop`.
Mostre ao dono: o agente fez commit, o check rodou, o gate rodou, o resultado. Se o check passou sem o teste existir, o check está fraco: conserte.

Termine com um resumo: o que foi criado, o que foi mesclado, notas do doutor, o que ficou pendente. Nada de push.
