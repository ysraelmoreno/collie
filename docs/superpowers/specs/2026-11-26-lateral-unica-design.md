# Lateral única: remanejamento da janela do Collie

**Data:** 2026-11-26 · **Estado:** aprovado pelo dono
**Protótipo aprovado:** `docs/pages/remanejamento/2-uma-lateral.html` (opção 2; comparação em `docs/pages/remanejamento/index.html`)

## Problema

A janela mostra informação demais ao mesmo tempo, e o caminho até cada função confunde quem não conhece orquestração
de agentes. Medido no app real (print de 2026-11-26):
- **Trilho:** cercados aparecem como letras soltas, sem como saber qual é qual.
- **Painel de contexto:** seis seções sempre abertas (Agentes, Painéis, Rebanhos, Lotes, Fábrica, Laços).
- **Cabeçalho do terminal:** seis etiquetas.
- **Barra de status:** contadores internos (`analytics 1 · preview 10`).

O dono não quer estrutura nova. Quer manter a lateral e o canvas, mais sóbrios, como no Maestri.

## Decisões do dono (2026-11-26)

1. **Opção 2:** o trilho e o painel de contexto viram uma lateral única.
2. **Substitui Completa e Compacta.** Fica uma estrutura só, e a lateral recolhida (⌘\) faz o papel da Compacta. Sai a preferência `WindowStructure`.
3. **Preferências em folha** sobre a janela, aberta por ⌘, ou pelo pé da lateral. Substitui a página embutida no lugar do canvas (T5).
4. **Memória e Laços (histórico) sem lugar fixo,** como no protótipo: entram pelo ⌘K e por Preferências.

## Desenho

**Lateral (~240 pt, ⌘\ recolhe a ~56 pt)**
- **Topo:** "＋ Novo agente". O menu traz Terminal simples, Painel… e A partir de rebanho….
- **Lista "Cercados":** nome do cercado e estado em texto ("espera você", "2 trabalhando"), com a cor sempre acompanhada de palavra. O ＋ ao lado do rótulo cria um cercado.
- **Cercado atual expandido:**
  - **Cabeçalho:** nome, e o ramo em mono embaixo (completo no hover). O menu ⋯ traz Lotes…, Fábrica com uma frase do que faz, renomear, land e apagar.
  - **Árvore:** cercado → agentes → painéis. Agentes chamados por um Pastor aparecem aninhados embaixo dele, e o papel "Pastor" aparece só aqui. Cada painel fica embaixo do agente que o abriu.
- **Pé da lateral:**
  - "Precisa de você (n)": pedidos de sandbox, de coleira e de app. Abre a lista, e clicar num item leva o canvas até o agente.
  - "Uso n%", com uma dica do que significa.
  - "Preferências ⌘,".
  - Aviso de desconexão, só quando acontece.
- **Recolhida:** duas letras do cercado, com o nome no hover e um número quando o cercado precisa de você.

**Canvas: a janela inteira, sem abas**
- **Barra flutuante fina no canto:** ⌘K, zoom (− n% +), Ajustar e minimapa, que vem desligado por padrão.
- **Cabeçalho do terminal:** nome e estado. Papel, ferramenta, modelo, livre/sandbox e lote vão para o ⋯, que aparece no hover ou na seleção.
- **Painéis:** nascem colados ao agente que os abriu, com coleira curta.
- **Laço:** vira um painel flutuante preso ao lado do terminal que o roda. Mostra tarefas, tentativa e check, com parar e adiar, e recolhe numa pílula ("laço 3/7 · check rodando"). O histórico fica no ⌘K, em "Laços…".
- **Pedido de sandbox:** aparece como cartão dentro do terminal que pediu. Aprovar ali tira o pedido do pé da lateral, e vice-versa.

**Sai da tela**
- **Barra de status:** sai inteira. Memória do processo e contadores vão para Preferências › Diagnóstico.
- **Ícone info do tour:** vai para Preferências › Geral e para o ⌘K ("Tour").
- **Seções do painel de contexto:** Rebanhos vai para o ＋ Novo agente e o ⌘K. Lotes e Fábrica vão para o ⋯ do cercado e o ⌘K. Lote vazio não ocupa tela.
- **Rótulos em caixa-alta espaçada:** saem. Fica só "Cercados", como rótulo discreto.

**Primeiro uso** (cercado sem agentes): o canvas mostra uma frase sobre o que é um agente e um cercado, o botão "Novo agente" e um link "Usar um rebanho pronto". Nada além disso.

## Fora do escopo

Mudar o daemon ou o protocolo; novas funções; temas, cores e fontes (usa a paleta ativa); o canvas fullscreen (7881e098); iOS.

## Riscos

- **Preferências em folha** desfaz o T5 (página embutida). A folha precisa de navegação própria e de Esc, e o código de `MainViewState` sai.
- **Remover `WindowStructure`** exige migrar quem tinha Compacta. A lateral começa recolhida para esses usuários.
- **A conferência visual é do dono,** no app real. Os testes não cobrem o layout.
- **O lint de cobertura do tour** (todo painel tem cartão) precisa seguir passando, com os botões dos cartões apontando para as novas entradas.

## Corte em PRDs

Ver `docs/superpowers/roadmap/2026-11-26-lateral-unica/README.md`. Onda 1: L1 lateral, L4 cabeçalho do terminal, L5
laço flutuante (arquivos separados). Onda 2: L3 casca (janela, folha de Preferências, remove Completa/Compacta) e L2 pé
da lateral. Onda 3: L6 primeiro uso, ⌘K e tour. No fim, `scripts/bundle-app.sh` e conferência do dono no app real.
