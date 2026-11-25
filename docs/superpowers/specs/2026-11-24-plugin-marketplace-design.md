# Design: marketplace de plug-ins do Collie

Data: 2026-11-24. Estado: para aprovação do dono (revisado por um leitor externo; respostas do dono incluídas). Abordagem escolhida pelo dono: **A** (catálogo publicado
nos Releases, lido pelo app). Fase 1: só plug-ins do dono. Fase 2: aberto a terceiros.

## Intenção

Hoje instalar um plug-in é escolher uma pasta (Preferências → Plug-ins → Instalar…, ou `collie plugin install
--path`). Isso serve para quem escreve plug-in, não para quem usa o Collie. Os plug-ins que já existem ou estão a
caminho (Vizinho, Cercas, o Treinador do roadmap de qualidade do Cursor, e mais tarde o motor FigCraft e o draw.io fora
do bundle) precisam de um lugar onde o usuário os ache, veja o que fazem e o que podem fazer, instale e atualize com
um clique. Depois, o mesmo lugar recebe plug-ins de outros autores.

## Objetivos

1. **Descobrir** em Preferências → Plug-ins: lista do catálogo, com nome, autor, descrição curta, permissões,
   tamanho, versão; filtro por tipo (Painéis, Agentes, Motores).
2. **Instalar** do catálogo com a mesma confirmação de hoje (permissões, o que substitui), sem escolher pasta.
3. **Atualizar**: o app avisa quando há versão nova de um plug-in instalado do catálogo; atualizar pede confirmação de
   novo só se a versão nova pede mais permissões (regra do G6).
4. **Recolher (recall)**: o dono marca uma versão como recolhida no catálogo; o app a desliga no próximo carregamento
   do catálogo e diz por quê.
5. **Fase 2, terceiros:** um autor de fora submete um plug-in; o dono revisa e publica; o app mostra o autor e que o
   Collie revisou.

## Não-objetivos

- Pagamento, avaliações, comentários, contagem de downloads.
- Página web do catálogo e link `collie://install` (abordagem C): depois, por cima deste.
- Publicação sem revisão (qualquer um publica): nem na fase 2.
- Agente instalando, ligando ou removendo plug-in: continua só do usuário (regra atual, `docs/plugins/api-v1.md`).

## Anti-objetivos

- Um catálogo adulterado (ou um link trocado) instalar algo que o dono não publicou.
- Um plug-in instalado do catálogo ter menos garantias que um instalado por pasta (pasta só leitura, SHA-256
  fixado, conferência a cada partida).
- O app depender da rede para abrir ou para carregar plug-ins já instalados.

## Restrições do que já existe

- **Instalação**: copia para `<root>/plugins/<id>/<version>/`, só leitura, SHA-256 da pasta em `installed.json`,
  conferido a cada partida; limites de 5 000 entradas e 64 MiB; sem links (`docs/plugins/api-v1.md`).
- **Canal de download**: o atualizador lê `releases/latest/download/update.json` no repositório público e confere o dmg
  pela assinatura do time (spec `2026-11-17-update-downloader-design.md`). O molde de download
  (`AndroidDownload.fetch`) checa https, host e caminho de uma lista, todo redirect e a URL final; `FigcraftInstaller`
  baixa com staging 0700, sha256 antes de extrair, `scan`, `renamex_np`.
- **HTML/JS não tem assinatura de código.** Para um dmg, a assinatura Developer ID é a prova; para um pacote de
  plug-in, não. A prova tem que vir do catálogo.
- **Helper binário** (Vizinho tem um): roda em sandbox por evento (`prd-g3-sandbox`), sem exigência de assinatura nesta
  fase (decisão 0a6d673e).
- `CryptoKit` já é usado no repo (`Herd.swift`, `BuildID.swift`): Ed25519 sem dependência nova.

## Abordagens consideradas

- **A. Catálogo `plugins.json` nos Releases, lido pelo app (escolhida).** Reaproveita o canal do atualizador; plug-in
  atualiza sem versão nova do app; dá para tirar o FigCraft do bundle pelo mesmo caminho.
- **B. Catálogo embutido no app.** Sem rede para listar, mas plug-in novo só com app novo. Descartada: não resolve
  atualização nem o FigCraft baixável.
- **C. Página web + `collie://install`.** Boa para descoberta pública; mais peças (site, esquema de URL, segurança do
  link) e a verificação no app é a mesma. Fica para depois, por cima do A.

## Como funciona

### Catálogo

`https://github.com/ysraelmoreno/collie/releases/download/plugins-catalog/plugins.json` (uma release fixa
`plugins-catalog`, atualizada no lugar), mais `plugins.json.sig`.

```json
{
  "format": 1,
  "generatedAt": "2026-12-01T12:00:00Z",
  "sequence": 42,
  "plugins": [
    {
      "id": "vizinho",
      "name": "Vizinho",
      "publisher": "collie",
      "summary": "Ao editar um arquivo, o agente recebe a forma que os arquivos irmãos seguem.",
      "kind": "agent",
      "minCollie": "0.2.0",
      "versions": [
        { "version": "0.1.0", "url": "https://github.com/ysraelmoreno/collie/releases/download/plugin-vizinho-v0.1.0/vizinho-0.1.0.tar.gz",
          "sha256": "<64 hex do pacote>", "size": 812345, "treeSha256": "<SHA-256 da pasta, o mesmo do installed.json>",
          "permissions": { "project": "read" }, "hooks": ["edit", "stop"], "helperTeamId": "AG8JQAH6YB",
          "recalled": null }
      ]
    }
  ],
  "publishers": [ { "id": "collie", "name": "Collie", "reviewedBy": "collie" } ]
}
```

- **Assinatura:** `plugins.json.sig` = Ed25519 do arquivo exato, com a chave privada do dono (segredo do CI). A chave
  pública vai no app. O app só aceita um catálogo com assinatura válida e `sequence` ≥ a última aceita (guardada):
  impede servir um catálogo velho, com uma versão recolhida ainda limpa.
- **Quem baixa e confere: o daemon**, como todo download que já existe (`AndroidDownload`, `FigcraftInstaller`, o
  atualizador). A chave pública, o último catálogo aceito e o `sequence` ficam no daemon; o app só mostra e pede.
- **Pacote:** tar.gz com a pasta do plug-in. O daemon confere o `sha256` do arquivo, extrai em staging 0700 (sem links,
  sem arquivo especial, limites de hoje), calcula o hash da árvore com o **mesmo esquema do `PluginStore.treeHash`**
  (`SHA256(rel ‖ 0 ‖ SHA256(conteúdo))` em ordem de caminho, não um hash da pasta) e confere com `treeSha256` antes de
  passar à instalação de hoje. O CI calcula `treeSha256` com o mesmo código (um subcomando do `collie`), **depois** de
  assinar o helper (assinar muda os bytes). O bit de execução do helper não entra no hash: a instalação o define
  (`bin/*` 0555), não o tar.
- **Download:** o molde do `AndroidDownload.fetch` com a lista de caminhos permitidos estendida para
  `/ysraelmoreno/collie/releases/download/plugin-` e `/ysraelmoreno/collie/releases/download/plugins-catalog/`; limite
  de bytes pelo `size` do catálogo.
- **Releases:** `plugin-*` e `plugins-catalog` saem com `--prerelease --latest=false`, como o `figcraft.yml`; senão a
  release de plug-in vira a "latest" do GitHub e quebra `releases/latest/download/update.json` e o link do dmg.
- **Validade:** um catálogo com `generatedAt` de mais de 30 dias é aceito para listar, mas a aba mostra "catálogo
  desatualizado"; os instalados continuam funcionando. Isso limita quanto tempo alguém consegue segurar um recall
  reenviando o último catálogo aceito.
- **Quando lê:** ao abrir a aba Descobrir e uma vez por dia em segundo plano (para avisar atualização e recall). Sem
  rede: a aba diz que não carregou; os instalados seguem funcionando.

### No app (Preferências → Plug-ins)

Duas abas: **Instalados** (a tela de hoje, mais selo "do catálogo" e "atualização disponível") e **Descobrir**.

```
┌ Plug-ins ─────────────────────────────────────────────────────────┐
│ [Instalados]  [Descobrir]                     Todos·Painéis·Agentes·Motores │
│                                                                    │
│ ▣ Vizinho                         Collie · revisado    0.1.0  0,8 MB│
│   Ao editar, o agente recebe a forma dos arquivos irmãos.          │
│   ⚠ Roda um programa a cada arquivo que um agente edita            │
│   ⚠ Pode ler os arquivos do projeto                   [ Instalar ] │
│ ─────────────────────────────────────────────────────────────────  │
│ ▣ Treinador                       Collie · revisado    0.1.0  0,3 MB│
│   …                                                   [Instalado ✓]│
└────────────────────────────────────────────────────────────────────┘
```

- **Instalar** abre a confirmação de hoje (`PluginInstallPrompt`) com o que veio do pacote, mais "do catálogo,
  publicado por <publisher>". O daemon confere tudo de novo, como hoje.
- **Atualizar** (Instalados; decidido pelo dono em 2026-11-24): um clique atualiza, **sem confirmação**, quando a
  versão nova não pede permissão nova; pede mais → a confirmação com as linhas novas. Nada atualiza sozinho.
- **Recolhida** (decidido pelo dono em 2026-11-24): o plug-in numa versão recolhida fica **bloqueado** no próximo
  catálogo aceito: desligado, e o interruptor não religa essa versão; só atualizar para uma versão boa ou remover. A
  linha mostra o motivo do catálogo ("recolhido: <motivo>") e o botão para a versão boa, se houver. Estado novo no
  `installed.json` (`recalled: {reason, at}`), respeitado pelo `PluginStore` no carregamento.
- Instalar por pasta continua (Instalar de uma pasta…), para quem desenvolve.

### Fase 1 (só do dono)

- Um workflow `plugins-release.yml`: numa tag `plugin-<id>-v<versão>`, monta a pasta do plug-in (`Examples/plugins/<id>`
  mais o que um alvo gera: o Vizinho precisa do `collie-vizinho` compilado em `bin/vizinho`, que não está na pasta de
  exemplo), assina o helper com o time, publica o pacote, regenera `plugins.json`
  com a nova versão, incrementa `sequence`, assina e sobe para a release `plugins-catalog`.
- `publisher` é sempre `collie`.

### Fase 2 (terceiros, curado)

- **Submissão:** o autor abre um PR num repositório de catálogo (`ysraelmoreno/collie-plugins`) com a pasta do plug-in
  ou um link para uma tag de um repositório público dele, mais um `publisher.json` (nome, contato, link).
- **Revisão:** o dono lê o código (HTML/JS e helper), roda o check do repositório (validação do manifesto e dos limites,
  sem rede no helper) e aprova o PR. Uma versão nova de um plug-in de terceiro passa por PR também.
- **Publicação:** só o CI do repositório de catálogo, com a chave do dono, gera e assina o `plugins.json`: a chave
  pública no app continua uma só. O autor nunca assina o catálogo.
- **Hospedagem:** o CI do `collie-plugins` **rehospeda** o pacote aprovado como release em `ysraelmoreno/collie`
  (`plugin-<id>-v<versão>`). A URL nunca aponta para o repositório do autor: a lista de caminhos do download não cresce,
  e o autor não troca o arquivo depois da revisão. O CI do `collie-plugins` publica com um token de escrita de release do
  repositório do app e a chave do catálogo como segredos.
- **Helper de terceiro:** binário assinado e notarizado pelo Developer ID do próprio autor; o catálogo grava o
  `helperTeamId` dele e o app confere antes de instalar. Sem isso, o plug-in de terceiro não pode ter helper.
- **No app:** o nome do autor e "revisado pelo Collie"; a confirmação de instalação diz que o autor não é o Collie.
- **Recall** como na fase 1, com o motivo.

## Decisões minhas (o dono pode vetar)

1. **Ed25519 no catálogo**, chave pública no app. HTTPS e a lista de hosts não bastam: um link trocado na release ou uma
   conta do GitHub comprometida publicaria um pacote. Rotação de chave: o app aceita uma lista de chaves públicas;
   uma versão nova do app tira a velha.
2. **`sequence` monotônico** contra reenvio de catálogo antigo.
3. **Uma chave só, a do dono, também na fase 2.** Terceiro não assina catálogo; a curadoria é o PR.
4. **Catálogo de terceiros num repositório separado** (`collie-plugins`), para PR de terceiro não tocar no repositório
   do app.
5. **FigCraft e draw.io como `kind: "engine"`** entram depois, com o próprio instalador (`FigcraftInstaller`), não pela
   instalação de plug-in: o motor não é um plug-in de pasta. O catálogo só lista e aponta.

6. **Helper do catálogo assinado pelo time, conferido na instalação** (`signedByTeam` com o `helperTeamId` do item).
   Vale só para o que vem do catálogo; instalar por pasta continua sem exigência (decisão 0a6d673e), então o build
   local do dono segue servindo para desenvolver.
7. **Origem guardada:** `installed.json` ganha `source: "catalog" | "folder"`, para o selo "do catálogo" e para a
   atualização. O recall casa por `treeSha256`, então vale também para um plug-in de mesmo conteúdo instalado por pasta.
8. **Sem rede na partida:** o recall vale a partir do último catálogo aceito, guardado no daemon.
9. **O plano cobre as duas fases**, em ondas separadas: a fase 2 só começa com a fase 1 em uso.

## O que fica para quem constrói

- O formato exato do diff entre "pede mais permissões" (reusar `newPermissions` do `PluginInstallPrompt`).
- Onde o app guarda o último catálogo aceito e o `sequence` (`<root>/plugins/catalog.json` 0600 sugerido).
- Texto e layout finais da aba (prévia em `docs/pages/plugin-marketplace/`).

## Medida

- Instalar o Vizinho pelo Descobrir, num Mac sem a pasta do plug-in, sem terminal.
- Catálogo com assinatura errada, `sequence` menor ou `sha256`/`treeSha256` diferente: recusado, com o motivo (testes).
- Versão recolhida: desligada no carregamento seguinte (teste).
