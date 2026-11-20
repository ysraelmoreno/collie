# PRD F1: "O que o Collie faz", modal com carrossel de funcionalidades

Data: 2026-11-20. Design aprovado pelo dono: `docs/pages/funcionalidades/index.html` (protótipo que funciona; a
tabela dos 17 cartões, os textos e as ilustrações estão nele).

## Problema

Quem abre o Collie não tem onde descobrir o que ele faz. As funcionalidades estão em `docs/feature-map.md`, que é
para quem desenvolve.

## Objetivo

Um ícone de informação, acima do indicador de uso dos agentes, abre um modal com um carrossel: um cartão por
funcionalidade, com o que ela é, como chamar, e um botão que leva até ela.

## Não-objetivos

- Abrir sozinho (nem na primeira execução).
- Capturas de tela, vídeo, texto longo. Tradução.
- Cartão para o que não é funcionalidade de uso: barra de menus, folha do terminal, atualização e serviço, CLI.

## Fazer

Arquivos: novo `Sources/CollieApp/FeatureTour.swift` (a tabela e o modelo), novo
`Sources/CollieApp/FeatureTourView.swift` (o modal e as ilustrações), `Sources/CollieApp/PaddockRail.swift` e
`Sources/CollieApp/Shell.swift` (o ícone), onde o estado de "aberto" precisar morar (`ShellContext`);
`scripts/ci/lint.sh` e `scripts/ci/test-lint.sh` (a regra nova); `Tests/CollieAppTests/FeatureTourTests.swift`;
`docs/feature-map.md`; `CHANGELOG.md` (uma linha em "Unreleased › Added", em inglês).

1. **Tabela** (`FeatureTour.cards`): os 17 cartões do protótipo, na mesma ordem e nos mesmos quatro grupos
   (Trabalhar, Painéis, Controle, Personalizar). Cada cartão: `id` estável (ex.: `canvas`, `paddocks`), grupo,
   título, texto, "como chamar", a ilustração, a ação do botão (ou nenhuma) e os tipos de painel que cobre
   (ex.: `["BrowserPanel"]`; "Plug-ins" cobre `WebPluginPanel`; "Prévia e Artifacts" cobre `PreviewPanel` e
   `ArtifactsPanel`; "Design e Design Systems" cobre os dois). Textos copiados do protótipo, sem reescrever.
2. **Modelo** (`FeatureTourModel`, tipo de valor, sem UI): índice atual; `next`, `previous` (param nas pontas, sem
   dar a volta); `jump(to group:)` vai ao primeiro cartão do grupo; `group` atual; os cartões vistos.
3. **Vistos**: um conjunto de ids em `UserDefaults` (`tour.seen`). Um cartão conta como visto quando é mostrado.
   `hasUnseen` é verdadeiro quando existe cartão cujo id não está no conjunto. Ao abrir, o modal começa no primeiro
   cartão não visto; se todos foram vistos, no primeiro. Ids desconhecidos no conjunto são ignorados.
4. **Ícone**: SF Symbol `info.circle`, com `help` e rótulo de acessibilidade "O que o Collie faz".
   - No Trilho (`PaddockRail`): no pé, **acima** do resumo de uso e da engrenagem.
   - Na Compacta (`CompactBar` em `Shell.swift`): à esquerda do `UsageButton`.
   - Um ponto na cor de destaque no canto do ícone enquanto `hasUnseen`.
5. **Modal**: uma folha (use o padrão de folhas que o app já tem, ex.: `HerdsSheet`), ~700 × 400 pt.
   - Cabeçalho: "O que o Collie faz", as quatro abas de grupo (a do cartão atual marcada), botão de fechar.
   - Corpo: à esquerda a ilustração sobre a grade de pontos; à direita o grupo, o título, o texto, "Como chamar"
     com o valor em monoespaçada, e o botão da ação.
   - Rodapé: anterior, os pontos (um por cartão, separados por grupo, o atual alongado), "N de 17", próxima.
   - Teclado: ← e → trocam de cartão; Esc fecha; Tab alcança tudo. Leitor de tela: o cartão novo é anunciado.
   - Sem animação que dependa de tempo; com "reduzir movimento" ligado, nenhuma.
6. **Ilustrações**: as 17 do protótipo (função `art` no `<script>` da página), portadas para SwiftUI com formas
   simples (retângulos arredondados, barras, círculos, linhas, poucas curvas), num espaço de 190 × 150, usando só as
   cores do tema (`CollieColor`): acompanham tema personalizado. Curva difícil de portar pode virar segmentos retos;
   a composição de cada uma se mantém.
7. **Ação do botão**: usar somente entradas que o app já tem (abrir a folha de terminal, criar cercado, abrir um
   painel pelo id do plug-in, abrir uma página de Preferências, abrir a paleta, abrir Rebanhos). O botão fecha o
   modal e executa. Cartão cuja ação não tem entrada pronta no app fica **sem botão**; não inventar caminho novo.
   Liste no relatório quais ficaram sem.
8. **Lint** (`scripts/ci/lint.sh`): regra nova `feature-tour`, ao lado da `feature-map`: todo
   `Sources/ColliePlugins/*Panel.swift` precisa ter o nome do tipo citado em `Sources/CollieApp/FeatureTour.swift`.
   Mensagem no mesmo estilo da regra vizinha, dizendo o que acrescentar. `scripts/ci/test-lint.sh` ganha os casos
   (painel citado passa; painel não citado falha com o nome dele).
9. `docs/feature-map.md`: entrada nova em "Menus e cartões do app" (nome na UI, para que serve, arquivos, como
   verificar).

## Aceite

`FeatureTourTests`: 17 cartões, ids distintos, os quatro grupos na ordem, cada grupo contíguo; `next`/`previous`
param nas pontas; `jump` vai ao primeiro do grupo; abrir com nada visto começa no primeiro; com os 3 primeiros
vistos começa no quarto; com todos vistos começa no primeiro e `hasUnseen` é falso; mostrar um cartão o marca;
id desconhecido salvo é ignorado; todo `*Panel.swift` de `Sources/ColliePlugins` está coberto por algum cartão.

**No app real** (o dono confere; registrar aqui): o ícone nas duas estruturas; o ponto some depois de ver tudo;
setas, abas, Esc; cada botão leva ao lugar certo; as ilustrações num tema claro, num escuro e num personalizado.

## Check

```
swift test --disable-sandbox --filter FeatureTourTests && scripts/ci/test-lint.sh
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `asyncAfter`, `try!` ou `@unchecked Sendable` novos. Textos que o dono vê em português; o
CHANGELOG em inglês. Commit com mensagem convencional, só dos seus arquivos; nada de push.
