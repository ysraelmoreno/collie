# Layout "Trilho" (prévia A) — só UI

Pedido do dono (2026-11-19): implementar o layout A das prévias (`docs/pages/ui-layouts/a-trilho.html`, abrir no painel Prévia para ver), **somente interface**. Nada de daemon, protocolo, comandos novos nem mudança em `CollieCore`/`CollieDaemonKit`.

## O que muda

- A estrutura **Completa** deixa de ser "sidebar de 240 px + cabeçalho + barra de status" e vira **Trilho**: uma coluna estreita (64 px) de cercados à esquerda, um painel de contexto (248 px) com a **árvore de agentes**, e a área principal com uma **faixa de abas** (Canvas, Preferências).
- A **Compacta** (barra flutuante) **não muda em nada**: o layout é feito só em cima da estrutura Completa, e na Compacta as Preferências continuam abrindo a janela de Ajustes.
- Na **Completa**, as **Preferências substituem o canvas** na janela principal (aba "Preferências"), em vez de abrir a janela de Ajustes. O canvas continua vivo atrás: terminais rodando, zoom e posições intactos.
- **Árvore de agentes** (como no B das prévias): o Pastor na raiz, os terminais ligados a ele por coleira indentados abaixo, os demais na raiz depois. Selo com o número de cartões pendentes do terminal.

## Fora do escopo (não fazer)

Qualquer mudança na estrutura Compacta, aba "Laços" própria (o painel Work existente continua), cartões de aprovação desenhados no canvas, mudanças nos cartões atuais, mudar o conteúdo das páginas de Preferências, tema/paleta, qualquer mudança em `Sources/CollieDaemonKit`, `Sources/CollieCore`, `Sources/CollieProtocol`.

## Ordem (cada tarefa deixa o app compilando)

1. T1 `AgentTree`: o modelo puro da árvore (testado).
2. T2 `PaddockRail`: a coluna de cercados.
3. T3 `ContextPanel`: o painel de contexto com a árvore, trocando a sidebar atual.
4. T4 `MainView`: o estado "canvas ou preferências", a faixa de abas e as Preferências embutidas.
5. T5 Entradas das Preferências: ⌘, , paleta, notificação `collieOpenPreferences`, engrenagem, Esc.

## Regras de todas as tarefas

Testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests`, nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais, um por tarefa, só com os arquivos da tarefa; nada de push. Não tocar em `scripts/ci/` nem em `architecture-rules.txt`. Os módulos-base não importam AppKit/SwiftUI (`CollieApp` pode). Sem `try!`, `as!`, `sleep`, nem `DispatchQueue.main.asyncAfter` novo (o lint do repo barra). O app só compila e é verificado à mão pelo dono: não rode o app. Respeitar acessibilidade: rótulo (`accessibilityLabel`) em todo botão só com ícone, e o estado nunca só por cor (o ponto de status tem forma ou texto junto).
