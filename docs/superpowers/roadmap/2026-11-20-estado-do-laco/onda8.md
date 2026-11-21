# Estado do laço, Onda 8: LAÇOS em card + modal "Ver tudo" (pedido do dono)

Pedido do dono (2026-11-21, olhando o Trilho com a Onda 7 rodando): (1) o HISTÓRICO sai da lista do Trilho; (2) a seção LAÇOS ganha o botão **Ver tudo**, que abre um **modal** para ver o que está sendo trabalhado e os laços em detalhe; (3) o visual volta ao card do desenho `docs/pages/ui-layouts/a-trilho.html`: título do trabalho, barra de progresso, `3/5`, linha "tentativa 2 · check rodando". Dois defeitos vistos na captura: a linha mostra "tentativa 0/3" com o laço rodando; o histórico lista como trabalhos os terminais de cada tentativa (0/0 feitas, <1 min).

Regras: as de `README.md` da pasta; só cores de `CollieTheme`; nenhum `sleep` nem relógio de parede em teste; acessibilidade (rótulo em texto, Reduzir Movimento); campos novos opcionais e tolerantes. A janela Compacta e as Preferências não mudam.

| # | Tarefa |
|---|---|
| M8.1 | Modelo e daemon: tentativa corrente certa; o histórico só lista trabalhos reais |
| M8.2 | Trilho: LAÇOS em card com barra e **Ver tudo**; HISTÓRICO sai do Trilho |
| M8.3 | Modal "Ver tudo": abas Em andamento e Histórico, detalhe do laço no próprio modal |

Verificação: `scripts/laco-check.sh M8.n`.
