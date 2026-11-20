# PRD T3: biblioteca de temas

PRD geral: `README.md` desta pasta. Design: seção "The library". Depende de T1.

## Problema

Os temas do usuário precisam morar em algum lugar, aparecer numa lista e recarregar quando o arquivo muda, inclusive
quando é editado fora do Collie.

## Fazer (novo `Sources/CollieApp/ThemeLibrary.swift` e `Tests/CollieAppTests/ThemeLibraryTests.swift`; nenhum
outro arquivo)

A pasta é do app, não do daemon: `~/Library/Application Support/Collie/themes/`. A classe recebe a pasta no `init`,
para os testes usarem um diretório temporário.

1. **Entrada**: `id` (nome do arquivo sem `.json`), `file`, e ou o `ThemeFile` lido ou o motivo de estar quebrado
   (a mensagem de `ThemeError`, ou `nome de arquivo inválido` quando o id não passa em `ThemeFile.validId`).
2. **`reload()`**: lê os `*.json` da pasta (no máximo 200, por nome; nada de subpastas, links simbólicos são
   ignorados), devolve as entradas ordenadas pelo nome do tema, as quebradas no fim. Pasta ausente: lista vazia, sem
   erro.
3. **Vigia**: observa a pasta e chama `onChange` (na main) quando um arquivo é criado, alterado, renomeado ou
   apagado. Eventos que chegam na mesma volta da fila principal viram uma chamada; uma rajada pode gerar mais de
   uma (como construído: sem temporizador, que a catraca do lint recusa). Quem escuta precisa ser idempotente. Parar a vigia no
   `deinit`. Sem `sleep` e sem polling: fonte de eventos do sistema de arquivos.
4. **Operações**, todas com escrita atômica (arquivo temporário na mesma pasta, depois `rename`):
   - `create(from base: ThemeFile, name: String) throws -> id`: cria a pasta se preciso (0700); id = o nome em
     minúsculas com o que não for `a-z0-9` virando `-`, cortado em 48, e `-2`, `-3`… se já existir;
   - `save(_ theme: ThemeFile, id:) throws`;
   - `importFile(_ url: URL) throws -> id`: valida com `ThemeFile.parse` antes de copiar; inválido não entra e o
     erro traz o motivo; id a partir do nome do arquivo, com a mesma regra de colisão;
   - `delete(id:) throws`: manda para o Lixo;
   - `reveal(id:)`: mostra o arquivo no Finder (a pasta, sem id).
5. Nada aqui aplica tema nem conhece a tela.

## Aceite

`ThemeLibraryTests`, em diretório temporário: lista vazia sem pasta; `create` cria a pasta e o arquivo, e o que foi
gravado lê igual; colisão de id; nome com acento e espaço vira id válido; arquivo inválido aparece quebrado com o
motivo; arquivo `Tema.JSON` ou `../x.json` aparece como nome inválido ou é ignorado, nunca lido fora da pasta; link
simbólico ignorado; mais de 200 arquivos: só 200; `importFile` recusa inválido e não deixa arquivo; `save` é atômico
(o arquivo antigo continua inteiro se a escrita falha num diretório sem permissão); a vigia chama `onChange` uma vez
depois de três escritas seguidas e de novo depois de apagar (esperar pelo evento com continuation, não por tempo).

## Check

```
swift test --disable-sandbox --filter ThemeLibraryTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `try!` ou `@unchecked Sendable` novos. Commit com mensagem convencional, só dos seus arquivos;
nada de push.
