# PRD L6: primeiro uso, ⌘K e tour

PRD geral: `README.md`. Spec: "Primeiro uso", "Sai da tela". Onda 3 (depois de L1–L5).

## Problema

Quem abre o Collie pela primeira vez vê um canvas vazio sem saber o que é agente ou cercado. E as entradas que saíram
da tela (Rebanhos, Lotes, Fábrica, Memória, Laços, Tour) precisam de caminho.

## Fazer (`FeatureTour.swift`, `FeatureTourView.swift`, `CommandPalette.swift`, `HerdsSheet.swift`, novo
`Sources/CollieApp/FirstRun.swift`; testes `FeatureTourTests`, novo `CommandPaletteEntriesTests`)

1. **Primeiro uso**: cercado sem agentes → no centro do canvas, uma frase ("Um agente é uma IA trabalhando num
   terminal. Um cercado é uma cópia isolada do seu projeto, para agentes não pisarem um no outro."), botão primário
   "Novo agente" (`ctx.newTerminal`) e link "Usar um rebanho pronto" (`ctx.openHerds(nil)`). Some com o primeiro
   agente.
2. **⌘K**: entradas Rebanhos…, Lotes…, Fábrica, Memória, Laços…, Trabalho, Tour, Diagnóstico — cada uma levando ao
   que já existe (folha, modal ou página de Preferências).
3. **Tour**: o ícone info do trilho saiu; o tour abre por ⌘K "Tour" e Preferências › Geral. Os cartões cujo "como"
   cita o trilho ou o painel de contexto (`+ no trilho`, `menu Rebanhos`…) passam a citar a lateral, o ＋ Novo agente
   ou o ⋯ do cercado; botões dos cartões apontam para as entradas novas. O lint de cobertura do tour segue passando.

## Aceite

`FeatureTourTests` atualizado (nenhum "como" menciona trilho/painel de contexto); `CommandPaletteEntriesTests`: cada
entrada nova existe e tem ação; modelo do primeiro uso: aparece só com zero agentes no cercado atual.

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter '(FeatureTourTests|CommandPaletteEntriesTests|FirstRunTests)'`
mais lint (cobertura do tour).

## No app real

Cercado vazio mostra a frase e "Novo agente"; ⌘K acha Rebanhos, Memória, Laços, Tour; o tour abre pelo ⌘K.
