# PRD T1: o arquivo de tema

PRD geral: `README.md` desta pasta. Design: `docs/superpowers/specs/2026-11-20-custom-themes-design.md`
(seção "The theme file").

## Problema

Não existe representação de um tema além das duas constantes `Palette.dark` e `Palette.light`. Tudo o mais (aplicar,
listar, editar) depende de ler, validar e escrever um tema.

## Fazer (em `Sources/CollieTheme/`: `ThemeFile.swift` novo e `Palette.swift`; testes em
`Tests/CollieThemeTests/ThemeFileTests.swift` e `PaletteTests.swift`; nenhum outro arquivo)

Tudo puro, sem disco.

1. **Papéis.** `Palette.roles`: a lista ordenada dos 18 papéis, cada um com a chave (o nome da propriedade:
   `background`, `borderSoft`…), o `KeyPath`, o nome em português, o grupo (Fundos, Texto, Destaques, Outros) e o
   papel contra o qual é lido (para o contraste), quando houver:
   - `text`, `textSecondary`, `muted`, `accent`, `attention`, `secondary`, `danger` → `surface`;
   - `onAccent` → `accent`;
   - os demais: sem leitura.
2. **Acesso por chave.** `palette[role: "accent"] -> RGB?` e `palette.replacing(_ overrides: [String: RGB]) -> Palette`
   (chave desconhecida é ignorada aqui; a validação é do item 4).
3. **`RGB`**: `init?(hexString: "#RRGGBB")` (exatamente 7 caracteres, maiúsculas ou minúsculas) e
   `hexString` (maiúsculas).
4. **`ThemeFile`**: `name`, `extends` (`.dark` | `.light`), `colors: [String: RGB]`.
   - `ThemeFile.parse(_ data: Data) throws(ThemeError)`: as regras da tabela do design. `ThemeError` tem uma
     mensagem de uma linha em português (ex.: `papel desconhecido: "fundo"`, `"accent": use #RRGGBB`,
     `falta "extends"`, `JSON inválido`, `arquivo grande demais`). Chave de topo desconhecida é ignorada.
   - `theme.palette -> Palette`: a paleta embutida de `extends` com as cores do arquivo por cima.
   - `theme.data -> Data`: JSON com 2 espaços, chaves na ordem `name`, `extends`, `colors`, e as cores na ordem de
     `Palette.roles`; termina com quebra de linha. `parse(theme.data) == theme`.
   - `ThemeFile.validId(_:) -> Bool`: `[a-z0-9][a-z0-9-]{0,47}`.
5. **Leituras.** `theme.readings -> [(role: String, ratio: Double, low: Bool)]` para os papéis que têm leitura,
   com `contrastRatio`; `low` = abaixo de 4,5.

## Aceite

`ThemeFileTests`: lê o exemplo do design; cada erro da lista com sua mensagem; chave de topo desconhecida passa;
`terminal` é ignorado; arquivo de 64 KiB + 1 é recusado; ida e volta (`parse(data) == theme`); ordem das chaves no
texto; `palette` herda o que falta de `dark` e de `light`; `validId` (aceita `tinta`, `meu-tema-2`; recusa vazio,
maiúscula, `../x`, 49 caracteres); leituras de um tema com `muted` igual ao fundo dão `low`.
`PaletteTests`: `roles` tem 18 chaves distintas e cobre todas as propriedades; `replacing` troca só o pedido.

## Check

```
swift test --disable-sandbox --filter 'ThemeFileTests|PaletteTests'
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Commit com mensagem convencional, só dos seus arquivos; nada de push.
