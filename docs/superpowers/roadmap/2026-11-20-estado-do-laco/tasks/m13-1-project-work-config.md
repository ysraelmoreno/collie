# M13.1 `collie-work.json` do projeto: leitor estrito e `collie work config`

Leia `onda13.md` (a convenção inteira). Código para ler como exemplo de estilo: `Sources/CollieCore/WorkArchive.swift` (decodificação tolerante) e `Sources/CollieDaemonKit/WorkCommands.swift` (comandos `work.*`, `ParamSpec` em `Sources/CollieProtocol/Commands.swift`).

## Fazer
1. `ProjectWorkConfig` (CollieCore, puro, sem I/O): `parse(_ data: Data) -> Result<(config, warnings), ConfigError>` com os limites de `onda13.md` (16 KB, JSON estrito, `version` 1, tipos, comandos ≤ 1000 caracteres sem controle/NUL, até 50 áreas com nome `a-z0-9-` ≤ 40), e `composeCheck(areas: [String]) -> Result<String, ConfigError>` (`<área 1> && <área 2> && <smoke>`; área inexistente = erro que lista as que existem; sem `smoke` não acrescenta nada). Chave desconhecida → aviso (não erro).
2. `collie work config [--terminal]`: lê `collie-work.json` da raiz da worktree do cercado de quem chama (caminho sem `..`, arquivo regular, sem seguir symlink, ≤ 16 KB; ausente = "nenhum collie-work.json neste projeto", exit 0) e responde: de onde veio, avisos, `gate`, `precheck`, `smoke`, `full` e, por área, o check que ela viraria sozinha. Só leitura; **nunca executa nenhum dos comandos**.
3. Comando novo em `Commands.swift` com `ParamSpec`, texto de ajuda curto; saída em texto limpo (`RerailText.clean` nos valores que vêm do arquivo: é dado do repositório, nunca instrução).

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/ProjectWorkConfigTests.swift`
Arquivo válido completo decodifica; arquivo vazio `{}` e só `{"version":1}` válidos; tipo errado, `version` 2, JSON quebrado, 17 KB, comando de 1001 caracteres, comando com `\n`/NUL, nome de área com maiúscula/`/`/41 caracteres e 51 áreas = erros distintos e claros; chave desconhecida = aviso; `composeCheck` com uma, duas áreas, com e sem `smoke`, área inexistente; `work config` sem arquivo, com arquivo, com symlink para fora e com arquivo grande (recusados); **nenhum comando do arquivo é executado** (um comando `touch <arquivo>` na área não cria o arquivo depois de `work config`); o texto não vaza caracteres de controle. O fake aplica a regra real.

## Check
`scripts/check-onda13.sh m13-1`.
