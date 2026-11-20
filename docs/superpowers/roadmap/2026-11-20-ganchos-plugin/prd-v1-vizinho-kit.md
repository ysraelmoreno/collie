# PRD V1: `VizinhoKit`, a orientação a partir dos arquivos irmãos

PRD geral: `README.md` desta pasta.

## Problema

O agente cria um arquivo e não sabe a forma que os arquivos daquele tipo seguem no projeto. Hoje alguém precisa
escrever isso como regra. A codebase já contém a resposta: os irmãos.

## Objetivo

Dado a raiz do projeto e um arquivo recém-escrito, devolver um texto curto com o que a maioria dos irmãos faz e um
arquivo modelo. Sem LLM, sem configuração, sem depender do Collie.

## Fazer (alvo novo `VizinhoKit` em `Sources/VizinhoKit/`, testes em `Tests/VizinhoKitTests/`, e as duas linhas
em `Package.swift`; nenhum outro arquivo)

`VizinhoKit` não importa nenhum módulo do Collie (só Foundation).

1. **Irmãos**: arquivos da mesma pasta com a mesma extensão e o mesmo "tipo". Tipo = o sufixo do nome: a última
   palavra CamelCase (`FooPanel.swift` → `Panel`), ou o sufixo pontuado (`foo.test.ts` → `.test`,
   `foo.service.ts` → `.service`). Sem sufixo reconhecível: todos os da mesma pasta e extensão. O próprio arquivo
   não conta. Ignorar pastas `.git`, `.build`, `node_modules`, `build`, `dist`, `DerivedData`.
2. **Mínimo**: menos de 3 irmãos → nenhuma orientação (texto `nil`). Ler no máximo 200 irmãos e 256 KiB por arquivo.
3. **Fatos**, cada um com contagem "N de M":
   - imports que pelo menos 80% dos irmãos têm e o arquivo não tem;
   - imports que nenhum irmão tem e o arquivo tem (só quando M ≥ 5);
   - arquivo de teste par: se pelo menos 80% dos irmãos têm um arquivo cujo nome é `<Nome>Tests`, `<Nome>Test`,
     `<nome>.test` ou `<nome>_test` em algum lugar do projeto e o arquivo novo não tem.
   Imports por regex de linha para Swift, TypeScript/JavaScript, Python, Kotlin e Java; outra linguagem: sem fatos
   de import.
4. **Modelo**: o irmão que mais se parece com a maioria (tem todos os imports da maioria; no empate, o de tamanho
   mediano). Nunca "o mais próximo no nome": o objetivo é não copiar erva daninha.
5. **Texto** (pt-BR, no máximo 1200 caracteres), só quando há pelo menos um fato:

   ```
   Sources/ColliePlugins/FooPanel.swift: 11 arquivos *Panel.swift nesta pasta seguem a mesma forma.
   Modelo: Sources/ColliePlugins/DiagramPanel.swift
   - 11 de 11 importam CollieCore; este não importa
   - 0 de 11 importam CollieDaemonKit; este importa
   - 10 de 11 têm teste (ex.: Tests/ColliePluginsTests/DiagramPanelTests.swift); este não tem
   ```
6. API: `Vizinho.guide(project: URL, file: String) -> String?` e
   `Vizinho.respond(eventJSON: Data) -> Data` (lê `{event, project, files}` do contrato; em `edit` junta as
   orientações dos arquivos, no máximo 3 arquivos e 2000 caracteres; devolve `{"guide": …}` ou `{}`; em `stop`
   devolve `{}`).
7. Duas chamadas para a mesma pasta não precisam de cache nesta tarefa; medir: `guide` numa pasta de 200 arquivos
   em menos de 1 s no teste.

## Aceite

`VizinhoKitTests` monta projetos em diretório temporário e cobre: sufixo CamelCase e pontuado; menos de 3 irmãos;
import faltando; import que ninguém tem; teste par faltando; escolha do modelo; nenhum fato → `nil`; pastas
ignoradas; `respond` com `edit` e com `stop`; limite de tamanho; o tempo do item 7.

## Check

```
swift test --disable-sandbox --filter VizinhoKitTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
