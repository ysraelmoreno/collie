# PRD geral: temas personalizados

Data: 2026-11-20. Estado: direção aprovada pelo dono (junção das opções B e C). Nada construído.
Design: `docs/superpowers/specs/2026-11-20-custom-themes-design.md`. Protótipo: `docs/pages/temas-editor`.

## Problema

O app tem Escuro, Claro e Sistema sobre duas paletas fixas de 18 cores. Quem quer outra cor não tem o que fazer.

## Objetivo

O usuário cria um tema, edita as cores como lista ou como JSON, vê o resultado numa prévia enquanto edita e aplica
ao app inteiro. O tema é um arquivo que ele pode mandar para outra pessoa.

## Não-objetivos

- As 16 cores ANSI do terminal (o app não mexe nelas hoje).
- Importar tema de terminal (Ghostty, iTerm): fica no T7, só esboçado.
- Tema personalizado que acompanha o claro/escuro do sistema.
- Fontes, espaçamento, raios. Catálogo de temas.

## Anti-objetivos

- Agente escrever ou alterar tema (poderia esconder o texto de um cartão de aprovação). Temas ficam fora de
  qualquer projeto e nunca são lidos de dentro de um.
- Tema quebrado derrubar o app ou deixá-lo ilegível sem volta.
- Recriar os terminais ao trocar de tema.

## Medida de resultado

- Criar um tema a partir do Escuro, trocar três cores na lista, ver as três no JSON, e o app inteiro (canvas,
  terminais, Preferências, páginas de plug-in) mudar sem reiniciar e sem recriar terminal.
- Um arquivo de tema copiado para a pasta de outro Mac aparece na galeria e aplica.
- Arquivo inválido aparece como quebrado, com o motivo, e não é aplicado.

## PRDs e ondas

Portão comum a todos: `scripts/ci/lint.sh && scripts/ci/check-architecture.sh`.

| Onda | PRD | O quê | Depende de |
|---|---|---|---|
| 1 | [T1](prd-t1-formato.md) | arquivo de tema: ler, validar, escrever; papéis e contraste | — |
| 2 | [T2](prd-t2-paleta-ativa.md) | paleta ativa trocável e aplicação ao app inteiro | T1 |
| 2 | [T3](prd-t3-biblioteca.md) | biblioteca: pasta, lista, vigia, criar, importar, apagar | T1 |
| 2 | [T4](prd-t4-modelo-editor.md) | modelo do editor: lista e JSON como vistas do mesmo tema | T1 |
| 3 | [T5](prd-t5-galeria.md) | galeria em Preferências › Aparência | T2, T3 |
| 4 | [T6](prd-t6-editor.md) | tela do editor: lista, JSON e prévia | T4, T5 |
| — | [T7](prd-t7-importar-terminal.md) | importar tema de terminal e cores ANSI (a detalhar) | T6 |

T2, T3 e T4 tocam arquivos diferentes e podem rodar em paralelo. T2 tem o único risco técnico (redesenhar sem
piscar e sem recriar terminais) e começa por prová-lo.

## Verificação que os testes não cobrem

T2, T5 e T6 mudam o que se vê. Cada um termina com uma conferência no app real, descrita no PRD; teste de modelo
não substitui.

## Estado em 2026-11-20

T1 a T6 implementados e com testes verdes (alvos de teste do app e do tema inteiros: 287 testes; lint e
arquitetura). **Nada foi visto no app**: quem implementou e quem verificou não podem abri-lo.

Conferência pendente do dono, num `build/Collie.app` deste ramo (cobre as seções "No app real" de T2, T5 e T6):

1. Preferências › Aparência: aparecem os cartões Escuro, Claro, Sistema e "Novo a partir de…".
2. "Novo a partir de…" › Escuro: cria "Escuro (cópia)" e o seleciona.
3. Com dois terminais abertos e um comando rodando num deles, trocar na **Lista** o Fundo, a Superfície e o
   Destaque. Devem mudar, sem piscar: canvas, barra lateral, Preferências, o terminal (fundo, texto, cursor) e uma
   página de plug-in ou Prévia. O comando continua rodando.
4. Mudar para **JSON**: as três cores estão lá. Trocar uma cor no texto: a lista e a prévia acompanham.
5. Deixar o JSON inválido: aparece "não aplicado: …" e o app não muda.
6. Abrir o arquivo em `~/Library/Application Support/Collie/themes/` num editor, salvar outra cor: o app acompanha.
7. Reiniciar o app: o tema vem aplicado desde a primeira janela.
8. Apagar o tema selecionado: o app volta para Escuro.

Se o passo 3 falhar só nas telas SwiftUI (barra lateral, Preferências), ver "Resultado da prova" em
`prd-t2-paleta-ativa.md`, item 2.
