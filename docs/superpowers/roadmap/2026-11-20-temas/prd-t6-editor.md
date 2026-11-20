# PRD T6: tela do editor (lista, JSON e prévia)

PRD geral: `README.md` desta pasta. Design: seção "The screen", Editor e Preview. Protótipo:
`docs/pages/temas-editor`. Depende de T4 (modelo do editor) e T5 (galeria).

## Problema

Com a galeria o usuário escolhe e cria temas, mas ainda não muda nenhuma cor dentro do app.

## Fazer

Arquivos: novo `Sources/CollieApp/ThemeEditorView.swift` (editor) e `Sources/CollieApp/ThemePreview.swift`
(prévia); `Sources/CollieApp/ThemeGallery.swift` (mostrar o editor sob a galeria quando o selecionado é do
usuário); testes em `Tests/CollieAppTests/ThemeEditorTests.swift`; `docs/feature-map.md`.

1. **Onde aparece**: abaixo da galeria, só quando o tema selecionado é do usuário e está válido. Cabeçalho: o nome
   (editável), "estende Escuro" ou "estende Claro", o nome do arquivo, e o seletor **Lista | JSON**.
2. **Lista**: as linhas de `ThemeEditorModel.rows`, agrupadas. Cada linha: nome do papel, seletor de cor do sistema
   (`ColorPicker`, sem opacidade), o hex (campo editável, aceita com ou sem `#`; inválido volta ao anterior ao
   sair do campo), "alterado" com o botão de voltar ao herdado, ou "herdado"; e a leitura quando houver ("5,8", ou
   "3,7 baixo" na cor de atenção).
3. **JSON**: editor de texto monoespaçado com o texto do modelo; sem correção automática, sem aspas inteligentes.
   Com erro, a linha "não aplicado: …" aparece embaixo, na cor de atenção.
4. **Prévia** (`ThemePreview(palette:)`): à direita, desenhada **só** com a paleta recebida, nunca com
   `CollieColor` (senão não mostra um tema que não é o aplicado). Conteúdo do protótipo: trilho, canvas com grade,
   um nó de terminal com linhas nas cores de texto, apagado, destaque, secundário, perigo e atenção, o cartão de
   aprovação com o botão primário, e um cartão de memória.
5. **Gravar**: a cada mudança válida, a prévia muda na hora; o arquivo é gravado 300 ms depois da última mudança
   (`ThemeLibrary.save`), e então o modelo é marcado como gravado. Sair da página ou fechar a janela grava o que
   estiver pendente. Erro ao gravar: uma linha de aviso no editor, o texto fica.
6. **Mudança vinda de fora**: se o arquivo muda em disco e o editor não tem edição pendente, o editor recarrega; se
   tem, a edição do usuário vence e é gravada.
7. **O app acompanha**: o tema em edição é o selecionado, então cada gravação passa por T5 e reaplica.
8. **Largura estreita**: abaixo de 720 pt de conteúdo, a prévia vai para baixo do editor.
9. **Teclado e leitor de tela**: todos os controles alcançáveis por Tab; cada seletor de cor tem o nome do papel
   como rótulo; a leitura baixa é dita ("contraste baixo").
10. `docs/feature-map.md`: como verificar o editor.

## Aceite

`ThemeEditorTests` (o que é testável sem tela: o coordenador entre modelo, espera e biblioteca, com relógio
injetado): uma edição grava depois da espera e só uma vez para uma rajada; JSON inválido não grava; sair grava o
pendente; mudança externa sem pendência recarrega o modelo; com pendência, a edição vence; erro de gravação mantém
o texto e expõe o aviso. `ThemePreview` recebe uma paleta de teste e não lê `ActivePalette` (verificar por código:
o arquivo não menciona `CollieColor`).

**No app real** (registrar o resultado neste PRD): trocar três cores na lista e vê-las no JSON; editar o JSON e ver
a lista mudar; deixar o JSON inválido e ver que o app não muda; abrir o arquivo num editor externo, salvar, e ver o
editor recarregar; com um terminal rodando um comando, conferir que nada é recriado; conferir a leitura baixa.

## Check

```
swift test --disable-sandbox --filter 'ThemeEditorTests|ThemeEditorModelTests' && ! grep -q CollieColor Sources/CollieApp/ThemePreview.swift
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `try!` ou `@unchecked Sendable` novos. Textos que o dono vê em português. Commit com mensagem
convencional, só dos seus arquivos; nada de push.
