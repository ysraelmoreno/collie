# Design: múltiplos idiomas (inglês primeiro)

Data: 2026-11-26. Estado: aprovado pelo dono em 2026-11-26. Decidido pelo dono na conversa: o objetivo é abrir o
Collie para quem não fala português; os agentes também passam a receber o idioma escolhido; caminho A (tabela em Swift).

## Intenção

Hoje todo texto do Collie está fixo em português: ~900 no app (`Sources/CollieApp`), ~780 na CLI, daemon e cliente.
O repositório é público; quem não lê português não consegue usar o app nem entende o que o Collie diz aos agentes.
Adicionar inglês, com troca nas Preferências, e deixar a estrutura pronta para outros idiomas depois.

## Objetivos

1. App inteiro em inglês ou português, conforme a preferência.
2. Texto que o Collie manda aos agentes (cabeçalhos de memória, orientação, personas, mensagens de erro, saídas da CLI)
   no mesmo idioma.
3. Preferências › Interface ganha "Idioma": Sistema (padrão) / Português / English.
4. Padrão "Sistema": Mac em português → português; qualquer outro idioma → inglês.
5. Teste que falha se alguma chave não tiver os dois idiomas.

## Não-objetivos

- Trocar o idioma ao vivo: a troca vale depois de reiniciar o app (o app avisa e oferece reiniciar). Terminais e agentes
  já abertos continuam com o texto que receberam; o daemon usa o idioma novo a partir da próxima mensagem que emitir.
- Traduzir dados do usuário: memórias salvas, nomes de cercados, temas, planos, CHANGELOG, docs.
- Terceiro idioma agora. A estrutura aceita, mas só pt e en entram.
- Mudar descrições das ferramentas MCP e `summary` de `Commands.swift`: já estão em inglês e ficam assim nos dois
  idiomas (agentes leem inglês bem; evita duplicar 199 comandos).

## Anti-objetivos (falha mesmo funcionando)

- Texto em inglês "quebrado" visível ao usuário (tradução literal, termos inconsistentes). O vocabulário segue o
  CHANGELOG: paddock, Shepherd, leash, loop, herd, lot, Pasture.
- CLI ou daemon quebrando por falta de arquivo de recurso: nada de `Bundle.module`.
- Um texto sem tradução cair em branco ou na chave crua.

## Restrições

- SwiftPM, sem `Bundle.module`; `bundle-app.sh` copia tudo à mão. Nada novo no empacotamento.
- Três processos (app, `collied`, `collie`) precisam do mesmo idioma.
- Regra do projeto: só rodar testes alterados/criados com `--filter`, nunca a suíte inteira.

## Abordagens

- **A. Tabela em Swift no CollieCore (escolhida pelo dono).** Funciona igual nos três processos, sem recursos; um
  teste garante completude. Custa: traduções no código, sem editor do Xcode, plurais à mão.
- B. String Catalog (`.xcstrings`) via recursos do SwiftPM. Nativo, com editor e plurais; mas introduz `Bundle.module`
  nos três executáveis, muda o empacotamento e ainda exige escolher o `.lproj` à mão para ignorar o idioma do sistema.
- Descartada: JSON próprio em `Resources/` — mesmos problemas de caminho do B sem as vantagens.

## Como (decidido)

### Onde fica o idioma

- `CollieSettings` (`preferences.json`, `SandboxCommands.swift:212`) ganha `language: String?` com valores
  `system|pt|en`; nil = `system`. String, não enum, pelo mesmo motivo de `cursorMemory`: valor desconhecido não pode
  invalidar o arquivo.
- Daemon: comando `admin.language` (lê/grava, `exposedToMCP: false`), no molde de `admin.sandbox`.
- Daemon segue a troca ao vivo: o `collied` é job do launchd e sobrevive ao reinício do app (reiniciá-lo mata os
  terminais), então `admin.language` atualiza o valor guardado no daemon, como `sandboxPref`. Cada texto emitido lê
  esse valor no momento. *(Chamada do agente.)*
- Terminais: o daemon injeta `COLLIE_LANG=pt|en` no ambiente de cada terminal que lança. Motivo: o sandbox dos
  terminais nega leitura da raiz de dados (`SandboxProfile.swift:274`), então a CLI e os hooks dentro de um terminal
  não conseguem ler `preferences.json`. Terminal já aberto mantém o idioma com que nasceu, coerente com o não-objetivo.
  *(Chamada do agente.)*
- CLI: ordem `COLLIE_LANG` → `CollieSettings.load` → idioma do sistema. Funciona com o daemon desligado.
- App: lê e grava via `admin.language`; guarda cópia em `UserDefaults` para decidir o idioma no início, antes de
  conectar ao daemon.

### Tabela

- Em `CollieCore`: `enum Lang { case pt, en }`, um resolvedor (`system` → `Locale.preferredLanguages.first` começa com
  `pt` ? pt : en) e o idioma ativo do processo (no app e na CLI, fixo no início; no daemon, atualizável, ver acima;
  nos testes, forçável por teste).
- Textos com chave tipada e os dois idiomas lado a lado; interpolação por função com parâmetros
  (ex.: `t.paddockDeleted(name)`), nunca concatenação de pedaços traduzidos.
- Arquivos da tabela por área (app, memória, laço, CLI…), para não virar um arquivo gigante nem dar conflito entre
  agentes trabalhando em paralelo.

### Textos que o código compara

Alguns pontos reconhecem mensagens pelo texto: `OpenPanelSheet.swift:30` (`hasPrefix("Prévia:")`),
`CuratorPreferences.swift:23` (`contains("cobrança por uso")`), `Curator.swift:504` (`hasPrefix("resposta ilegível")`).
Antes de migrar o daemon, esses casos passam a comparar contra um código estável (campo no erro/resposta), e não
contra o texto traduzido. Primeiro passo da migração: achar todos com grep (`hasPrefix(`, `contains(`, `==` contra
literal em português) e listar. *(Chamada do agente.)*

### Texto que o Collie grava

Commits, mensagens de land, notas de histórico e eventos escritos pelo próprio Collie ficam no idioma ativo na hora
da escrita e nunca são reescritos. *(Chamada do agente.)*

### Migração

- Por área, um commit por área, cada uma deixando o app compilando e usável.
- O inglês escrito à mão, revisado contra o vocabulário do CHANGELOG.
- Testes que comparam texto em português continuam valendo com o idioma forçado em `pt` no teste.

## Deixado para quem construir

- Nome exato dos tipos/funções da tabela e como dividir os arquivos.
- Ordem das áreas na migração (sugestão: Preferências e chrome do app primeiro, depois agentes, depois CLI).
- Como o app reinicia ao trocar (relançar o bundle ou só pedir para o usuário reabrir).
- Como tratar os poucos plurais.
