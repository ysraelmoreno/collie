# PRD T5: galeria de temas em Preferências › Aparência

PRD geral: `README.md` desta pasta. Design: seção "The screen", Gallery. Protótipo: `docs/pages/temas-editor`.
Depende de T2 (aplicar) e T3 (biblioteca).

## Problema

A página Aparência oferece três botões fixos. Falta o lugar onde os temas do usuário aparecem, são escolhidos,
criados, importados e apagados.

## Fazer

Arquivos: `Sources/CollieApp/PreferencesView.swift` (só a seção de tema da página Aparência); novo
`Sources/CollieApp/ThemeGallery.swift` (a view e o seu modelo); `Sources/CollieApp/CollieApp.swift` (carregar e
aplicar o tema escolhido na partida e quando a biblioteca muda); testes em
`Tests/CollieAppTests/ThemeGalleryTests.swift`; `docs/feature-map.md`.

1. **Modelo** (`ThemeGalleryModel`, testável sem tela): junta os embutidos (Escuro, Claro, Sistema) com as entradas
   de `ThemeLibrary`, sabe qual está selecionado (`appearance.theme`) e expõe as ações abaixo. Recarrega quando a
   biblioteca avisa mudança.
2. **Cartões**, na ordem: Escuro, Claro, Sistema, os do usuário por nome, os quebrados, e "Novo a partir de…".
   Cada cartão: miniatura desenhada com a paleta do tema (fundo, duas linhas de texto, um bloco de destaque), nome,
   e a origem ("do Collie" ou o nome do arquivo). O selecionado tem a borda de destaque.
3. **Selecionar** um cartão aplica o tema (T2) e grava `appearance.theme`. Tema quebrado: o cartão mostra o motivo
   em uma linha, não seleciona, e oferece "Mostrar no Finder" e "Apagar".
4. **"Novo a partir de…"**: menu com os temas válidos; cria uma cópia chamada "<nome> (cópia)" e a seleciona.
   A partir de "Sistema" não é oferecido.
5. **"Importar…"**: painel de abrir arquivo, só `.json`; inválido mostra o motivo num alerta e não entra.
6. **"Mostrar no Finder"**: abre a pasta de temas (criando-a).
7. **Apagar** (menu de contexto do cartão do usuário, com confirmação): manda para o Lixo; se era o selecionado, o
   app volta para Escuro.
8. **Mudança no disco**: se o arquivo do tema selecionado muda, o app reaplica; se some ou quebra, o app volta para
   Escuro e o cartão (se existir) fica quebrado.
9. **Partida**: com `custom:<id>` salvo, o tema é carregado e aplicado antes da primeira janela aparecer; arquivo
   ausente ou quebrado aplica Escuro sem apagar a preferência.
10. Embutidos não têm "Apagar" nem editor.
11. `docs/feature-map.md`: atualizar a entrada de Preferências (Aparência).

## Aceite

`ThemeGalleryTests`, com biblioteca em diretório temporário e `UserDefaults` de teste: ordem dos cartões; selecionar
grava a preferência e chama a aplicação com o tema certo; quebrado não seleciona; "novo a partir de" cria, nomeia e
seleciona; apagar o selecionado volta para Escuro; arquivo do selecionado alterado em disco dispara nova aplicação;
arquivo do selecionado apagado em disco volta para Escuro; partida com `custom:<id>` ausente aplica Escuro e mantém
a preferência.

**No app real** (registrar o resultado neste PRD): criar um tema a partir do Escuro; selecionar; reiniciar o app e
ver o tema aplicado desde a primeira janela; importar um arquivo válido e um inválido; apagar o tema selecionado.

## Check

```
swift test --disable-sandbox --filter 'ThemeGalleryTests|ThemeLibraryTests'
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Commit com mensagem convencional, só dos seus arquivos; nada de push.
