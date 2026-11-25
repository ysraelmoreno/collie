# Sparkle como instalador do Collie — design

Status: rascunho para o dono aprovar (2026-11-25). Nada implementado. Substitui, só no **como instalar**, a decisão B de
`2026-11-17-update-downloader-design.md` (atualizador próprio); o resto daquela spec (daemon que não pode cair sem
aviso, versão do bundle, motor figcraft) continua valendo.

## Intenção e porquê

O dono quer atualizar o Collie **com um clique, sem baixar o DMG na mão**, também em máquinas onde ele é administrador mas
o macOS pede senha (ou "Install with privilege management") para mexer em `/Applications`. O atualizador próprio troca o
`.app` por `rename` e não sabe pedir privilégio; o Sparkle 2 sabe. Fonte: <https://sparkle-project.org/documentation/>.

## Metas

- Checar, baixar, conferir, instalar e relançar pelo Sparkle, inclusive com pedido de senha.
- Nenhum agente ou terminal em andamento cai sem aviso por causa da atualização.
- Só instala o que está assinado com a chave EdDSA do projeto **e** pelo time Apple do app.
- Quem está num 0.2.x chega à primeira versão com Sparkle pelo caminho atual (`update.json`), uma única vez.

## Não metas

- Delta, canais beta, UI própria do Sparkle (`SPUUserDriver`): usa-se a janela padrão.
- Usuário padrão **sem** senha de admin (nenhum atualizador escreve em `/Applications`); seria instalar em `~/Applications`,
  outro trabalho.
- Atualizar o motor figcraft (continua pelo pin) e o daemon (continua pelo banner "serviço desatualizado").

## Anti-metas

- Instalar com agentes ocupados sem o dono saber. Aceitar update sem EdDSA válida. A chave privada fora do secret do CI.
  Build local (`swift build`, `bundle-app.sh` sem chave) tentando se atualizar.

## Restrições

- App Developer ID, hardened runtime, notarizado; o app **não** é sandboxed (XPC do Sparkle opcional, ver §Mecânica).
- Sparkle só no alvo `CollieApp`: `collied`, `collie` e o resto não o linkam (regra em `scripts/ci/architecture-rules.txt`).
- Segredos de assinatura são do dono: eu não gero nem toco na chave; o dono guarda a privada como secret do GitHub e me
  passa a **pública**.
- `release.yml` roda no GitHub, assina e notariza; `appcast.xml` e `update.json` saem do mesmo release.

## Abordagens consideradas

- **A. Sparkle completo (escolhida).** Ele checa, baixa, confere, instala (com privilégio) e relança. Custo: dependência,
  chave EdDSA, `CFBundleVersion` incremental, framework embutido e assinado.
- **B. Próprio + `osascript … with administrator privileges`.** Pequeno, mas sem Touch ID e com janela de troca do `.app` por
  outro processo do mesmo usuário entre a conferência e a troca como root.
- **C. Sparkle só para instalar, com o nosso checador.** O Sparkle não instala arquivo local sem passar pelo appcast;
  vira A com mais peças. Descartada.

## Design

1. **Dependência.** `Package.swift`: `Sparkle` (exact, última 2.x com mais de 2 semanas), produto `Sparkle`, só no alvo
   `CollieApp`.
2. **Bundle.** `bundle-app.sh` copia `Sparkle.framework` para `Contents/Frameworks/`, garante o rpath
   `@executable_path/../Frameworks` e assina **de dentro para fora** (`Autoupdate`, `Updater.app`, XPCs se houver, o
   framework, o app) com hardened runtime e `--timestamp`. O laço de `release.sh` que confere cada Mach-O passa a cobrir
   os binários do framework.
3. **Info.plist.** `SUFeedURL` =
   `https://github.com/ysraelmoreno/collie/releases/latest/download/appcast.xml`, `SUPublicEDKey` (pública do dono),
   `SUEnableAutomaticChecks` verdadeiro, `SUAllowsAutomaticUpdates` falso (o dono clica), `SUEnableSystemProfiling` falso
   (nada do usuário sai).
4. **Versão.** `CFBundleVersion` deixa de ser `"1"`: derivada da tag, `MAJOR*1000000 + MINOR*1000 + PATCH` (0.2.2 → `2002`,
   sempre maior que `1`). Escrita por `bundle-app.sh` junto de `CFBundleShortVersionString`; um teste do script cobre a
   conta e recusa tag fora de `vX.Y.Z`.
5. **Appcast no CI.** `release.yml`, depois de notarizar o DMG: assina o DMG com `sign_update` (ferramenta do Sparkle,
   versão e sha256 fixados) usando o secret `SPARKLE_ED_PRIVATE_KEY`, gera `appcast.xml` (um item: versão curta, build,
   `sparkle:edSignature`, tamanho, URL do asset do release, mínimo do sistema, notas) e o sobe **por último**, depois do
   DMG e do `update.json` (um cliente que vê o appcast antes do DMG só tenta de novo). O `update.json` continua publicado.
6. **Cliente.** `SPUStandardUpdaterController` iniciado no app **só se** o `Info.plist` tem `SUPublicEDKey` (build local não
   se atualiza). Preferências ganha "Verificar agora" e o interruptor de checagem automática, ligados ao Sparkle.
7. **Daemon e terminais.** O delegate do Sparkle adia o relançamento (`shouldPostponeRelaunchForUpdate`) enquanto o daemon
   disser que há agente ocupado (mesmo sinal `maintenance` da spec de 2026-11-17) e mostra um aviso com "Atualizar
   mesmo assim" / "Depois". Depois do relançamento o app novo mostra o banner "serviço desatualizado" já existente; o
   daemon só reinicia por ação explícita.
8. **Caminho antigo.** O instalador próprio (troca por `rename`) sai da UI do app novo. O `UpdateChecker` e o
   `update.json` ficam: servem os 0.2.x até a versão com Sparkle. Remoção do código morto fica para depois do próximo
   minor.

## Validação (critérios de aceite)

- Testes automáticos: conta de `CFBundleVersion`; geração do appcast com uma chave de teste; regra de arquitetura (só
  `CollieApp` linka Sparkle); `codesign --verify --deep --strict` do bundle com o framework.
- **Passo do dono (roteiro manual):** (1) gerar o par de chaves e o secret; (2) numa máquina com senha de admin, atualizar
  de uma versão com Sparkle para a seguinte e ver o pedido de senha; (3) com um terminal/agente rodando, conferir que o PID do
  `collied` sobrevive à troca do app e que o aviso de agente ocupado aparece.

## Minhas chamadas (conferir)

- Fórmula de `CFBundleVersion` e `SUAllowsAutomaticUpdates` falso.
- Manter o `update.json` por um minor para a migração dos 0.2.x.
- Se a troca do Sparkle reiniciar o `collied` (escrita por cima do Mach-O), tratar no delegate antes de recomendar; esse é o
  risco principal e o roteiro (3) o mede.

## Deixado ao construtor

Nome exato das chaves do delegate na versão fixada do Sparkle, formato das notas no appcast, texto do aviso de agente
ocupado, override de feed para teste local (só `file://` ou `127.0.0.1`, nunca em release).
