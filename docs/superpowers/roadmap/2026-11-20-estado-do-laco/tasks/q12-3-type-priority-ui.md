# Q12.3 UI: tipos e prioridade conforme o protótipo

Leia `onda12.md` e **abra `docs/pages/quadro-design/index.html`** (é a fonte do desenho: tokens, glifos SVG, chips, barra lateral do cartão, filtros, seletor do detalhe). A UI atual está em `Examples/apps/quadro/ui/` (`index.html`, `app.js`, `style.css`) e fala só com a API do contrato; o servidor com os campos novos é feito em paralelo pela Q12.1 (use o contrato de `onda12.md`; cartão sem `type`/`priority` lê como `impl`/`medium`).

## Fazer
1. **Tokens e tema:** troque as variáveis do `style.css` pelas do protótipo (paleta do app, escuro e claro por `prefers-color-scheme`; as cores dos tipos `--t-*`). Fontes: `font-family` "Space Grotesk" e "DM Mono" com fallback do sistema; **sem** fonte nem CDN externos (o painel bloqueia rede fora do serviço).
2. **Tipo:** glifo SVG inline por tipo (os `symbol` do protótipo, construídos por JS com `createElementNS`/atributos, **nunca `innerHTML`**), chip com glifo + rótulo + cor (nunca só cor), barra lateral do cartão na cor do tipo, `chore` com borda tracejada. Filtro por tipo no topo, com contagem e `aria-pressed`, que combina com busca e rótulo.
3. **Prioridade:** marcador de três barras no rodapé do cartão (alta = 3 barras na cor de perigo, média = 2 na de atenção, baixa = 1 na neutra), com `title` e `aria-label` ("Prioridade alta"); filtro por prioridade (Alta, Média, Baixa) ao lado do de tipo.
4. **Criar:** o campo de novo cartão ganha um seletor de tipo (padrão Impl) e de prioridade (padrão Média), enviados em `api/card/create`. **Detalhe:** seletor de tipo (radiogroup de 7, como no protótipo) e de prioridade; salvar envia `type` e `priority` em `api/card/update`. Coluna "Feito" mais apagada, título riscado (como no protótipo).
5. **Segurança e acessibilidade como antes:** todo texto por `textContent`; nenhum `innerHTML`/`outerHTML`/`insertAdjacentHTML`/`eval`/`on*=`/`javascript:`; rótulos `aria-label`, foco visível, `prefers-reduced-motion`; usável em 320 px.

## Testes
`tests/test_ui.py` (o que já existe continua verde): `app.js` referencia os 7 tipos e as 3 prioridades; cada tipo tem glifo e cor definidos em `style.css` (`--t-*`) nos dois temas; nenhum padrão proibido (regex) em nenhum dos três arquivos; nenhuma URL `http(s)://` nem `url(` externa; `node --check ui/app.js` quando o `node` existe; os `id` e `aria-label` usados pelo JS existem no HTML ou são criados no JS.

## Check
`scripts/check-onda12.sh q12-3`.
