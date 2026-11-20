# PRD T4: modelo do editor (lista e JSON como vistas do mesmo tema)

PRD geral: `README.md` desta pasta. Design: seção "The screen", Editor. Depende de T1.

## Problema

A lista e o JSON têm de mostrar sempre o mesmo tema, nos dois sentidos, e um JSON pela metade não pode estragar o
tema que está aplicado. Isso é lógica, e deve existir e ser testada sem tela.

## Fazer (novo `Sources/CollieTheme/ThemeEditorModel.swift` e `Tests/CollieThemeTests/ThemeEditorModelTests.swift`;
nenhum outro arquivo)

Um tipo de valor, puro (sem disco, sem relógio, sem UI): `ThemeEditorModel`.

1. **Estado**: `theme: ThemeFile` (o último tema válido), `jsonText: String`, `jsonError: String?`.
   `init(theme:)` deixa `jsonText` igual a `theme.data` e sem erro.
2. **Linhas da lista** (`rows`): uma por papel de `Palette.roles`, na ordem e nos grupos de lá, com: chave, nome em
   português, grupo, cor em uso (a do tema ou a herdada), `changed` (está no arquivo), e a leitura (razão e `low`)
   quando o papel tem.
3. **Editar pela lista**:
   - `set(_ role: String, _ color: RGB)`: grava a cor no tema; se for igual à herdada, continua contando como
     alterada (o usuário pediu);
   - `reset(_ role: String)`: tira do arquivo, volta a herdar;
   - `rename(_ name: String)`: nome inválido (vazio, mais de 48, caractere de controle) é recusado e nada muda.
   Depois de qualquer um, `jsonText` vira o texto novo do tema e `jsonError` some.
4. **Editar pelo JSON**: `setJSON(_ text: String)` sempre guarda o texto como está. Se o texto é um tema válido,
   `theme` passa a ser ele e `jsonError` some; se não, `theme` não muda e `jsonError` é a mensagem de
   `ThemeError` com o prefixo `não aplicado: `. Mudar `extends` pelo JSON é permitido.
5. **O que gravar**: `pendingSave: ThemeFile?` devolve o tema quando ele difere do último marcado como gravado
   (`markSaved()`), e `nil` caso contrário. O modelo não grava; quem grava é a tela (T6), com espera de 300 ms.
6. **Paleta para a prévia**: `palette` = `theme.palette` (sempre a do último tema válido).

## Aceite

`ThemeEditorModelTests`: `rows` tem 18 linhas nos grupos certos; `set` aparece no JSON e marca `changed`; `reset`
tira a chave do JSON; mudar uma cor de fundo muda a leitura dos papéis lidos contra ele; `setJSON` válido muda as
linhas; `setJSON` inválido guarda o texto, mantém o tema e as linhas, e dá o erro com prefixo; voltar a um texto
válido limpa o erro; depois de um `setJSON` inválido, um `set` pela lista substitui o texto pelo do tema; `rename`
inválido não muda nada; `pendingSave` é `nil` logo após `init` e após `markSaved`, e traz o tema após uma edição
válida; um JSON inválido não gera `pendingSave`.

## Check

```
swift test --disable-sandbox --filter ThemeEditorModelTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Commit com mensagem convencional, só dos seus arquivos; nada de push.
