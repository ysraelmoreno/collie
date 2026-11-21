# Q11.3 Quadro: a UI do quadro

Leia `onda11.md` e `q11-contrato.md`. Crie `Examples/apps/quadro/ui/index.html`, `ui/app.js`, `ui/style.css` (e `Examples/apps/quadro/tests/test_ui.py`). A UI fala só com a API do contrato (a Q11.2 faz o servidor em paralelo; **use URLs relativas**, `fetch('api/board')`, para funcionar dentro do painel do Collie).

## Fazer
- Quatro colunas (as de `board.columns`), cartões arrastáveis entre colunas e dentro da coluna (arrastar do HTML5: `dragstart`/`dragover`/`drop` → `POST api/card/move` com `index`); o mesmo movimento **por teclado e leitor de tela**: cada cartão tem botões "mover para a coluna anterior/seguinte" com `aria-label`; foco visível; contraste suficiente.
- Criar cartão (campo no topo de cada coluna, Enter cria), clicar no cartão abre painel lateral com título, corpo, rótulos, responsável, comentários (adicionar) e "Arquivar". Filtro por rótulo e busca (`api/cards?q=`), contagem por coluna, "Arquivados" (liga `?archived=1`) com "Restaurar".
- **Ao vivo:** `EventSource('api/stream')`; cada documento redesenha o quadro (sem perder o foco nem o rascunho que o usuário está digitando; arrastando, adia o redesenho até soltar). Se a conexão cair, mostra "reconectando" e volta sozinha (o `EventSource` já refaz; só mostre o estado).
- Se `window.collie` existir, publique o cartão aberto em `collie.context` (id, título, coluna); se não existir, funciona igual.
- Tema claro/escuro pelo sistema (`prefers-color-scheme`), tokens em variáveis CSS; usável em 320 px de largura (colunas rolam na horizontal); `prefers-reduced-motion` respeitado.
- **Segurança:** todo texto de cartão/comentário/`by` entra por `textContent` ou `createTextNode`. **Nenhum `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval`, `new Function`, atributo `on*=` ou `javascript:`** em nenhum dos três arquivos. Sem biblioteca externa, sem fonte nem CDN, sem rede além de `api/*`. Texto que parece instrução ("ignore as regras…") é só texto.

## Testes
`tests/test_ui.py` (`unittest`): os três arquivos existem; `index.html` referencia `app.js` e `style.css` com caminhos relativos e tem `lang`, `<meta viewport>`, título; **nenhum** dos padrões proibidos acima aparece em `app.js`/`index.html` (regex); nenhuma URL `http://` ou `https://` em nenhum dos três (exceto namespaces SVG se houver); `node --check ui/app.js` passa quando o `node` existe (senão `skipTest` com motivo); todos os `aria-label` e ids referenciados em `app.js` existem no HTML ou são criados no JS (confira por regex o que for estático); `style.css` tem o bloco `prefers-color-scheme: dark` e `prefers-reduced-motion`.

## Check
`cd Examples/apps/quadro && python3 -m unittest tests.test_ui -v`.
