# B6.3 Página "Laços" nas Preferências

Pedido do dono (2026-11-19): a seção "Laços sem cartão" ficou no fim de "Desenho e sandbox" e ele não a achou. Ela passa a ter **uma página própria**, "Laços", no grupo "Agentes". Só app (CollieApp); o daemon não muda.

Código: `Sources/CollieApp/PreferencePage.swift` (as páginas, o grupo, o ícone, as palavras-chave da busca), `Sources/CollieApp/PreferencesView.swift` (`loopTrustSection`, hoje usada na página `desenho`, por volta das linhas 160 e 240-265), `Tests/CollieAppTests/PreferencePageTests.swift`.

## Fazer

1. Um caso novo `lacos` em `PreferencePage`: título "Laços", grupo "Agentes" (junto de Desenho e sandbox, Memória e Plug-ins), um ícone de uma só glifo no mesmo estilo dos outros (por exemplo "⟳"), palavras-chave "laço laços loop cartão aprovar aprovação confiar cercado revogar autônomo work run" para a busca.
2. A página mostra, em ordem: uma frase do que é o laço sem cartão ("Quando você escolhe "Sempre neste cercado" no cartão de um laço, os próximos laços desse cercado começam sem cartão. Você recebe o aviso e pode parar com collie work stop."), a lista de cercados confiáveis com **Revogar** (o `loopTrustSection` existente, movido, com o mesmo `admin.paddock.trust-loops`), e o estado vazio "Nenhum cercado. Todo laço pede o cartão antes de começar.".
3. Tirar o `loopTrustSection` da página "Desenho e sandbox" (sem deixar duplicata) e tirar de lá as palavras-chave "laço laços cartão confiar" que só pertencem à página nova.
4. `PreferencePage.matching("laço")` e `matching("revogar")` devolvem a página Laços e não mais a de Desenho; a notificação `collieOpenPreferences` com o objeto `"lacos"` abre a página.
5. Nada novo no daemon, no protocolo nem em comandos.

## Testes (escrever antes) — `PreferencePageTests`

A ordem das páginas e dos grupos com a nova; `matching("laço")` contém `lacos` e não `desenho`; `page(named: "lacos")`; todas as páginas têm título, grupo, ícone e palavras-chave não vazios e sem repetir ícone. O visual o dono confere à mão.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests`, nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt. O app só compila e é verificado à mão pelo dono: não rode o app.
