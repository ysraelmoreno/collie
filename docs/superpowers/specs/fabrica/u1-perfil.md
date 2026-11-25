# U1: esquema do perfil de fábrica (leitor estrito)

Contexto: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U1. Só o leitor puro e os testes. Nada de daemon, CLI, skill nem
comando novo.

Hoje `Sources/CollieCore/ProjectWorkConfig.swift` lê `collie-work.json` (gate, precheck, smoke, full, areas; chave de topo desconhecida = aviso). O perfil
entra nesse mesmo arquivo, sob uma chave nova de topo `factory`, e é lido por um tipo novo, puro e estrito, num arquivo novo
`Sources/CollieCore/FactoryProfile.swift`. Não mude o comportamento atual de `ProjectWorkConfig.parse` além de uma coisa: a chave `factory` passa a ser
conhecida (não gera mais o aviso "chave desconhecida"). Os campos antigos (gate, precheck, smoke, areas) continuam onde estão: o perfil não os duplica.

## Esquema (dentro de `factory`)

```json
{ "version": 1,
  "static":       { "architecture": ["cmd"], "ratchets": [{"name": "lint", "measure": "cmd", "baseline": "scripts/lint-baseline.txt"}] },
  "verification": { "scenarios": [{"area": "ui", "command": "cmd"}] },
  "review":       { "personas": ["correcao"], "threshold": "major", "callOwner": true },
  "guardrails":   { "budgetSeconds": 2400, "maxTries": 3, "destructive": ["rm -rf"], "land": "manual" },
  "prose":        { "traps": ["07d5be97"] } }
```

Todas as camadas e campos são opcionais; `version` é obrigatório dentro de `factory` e só o 1 vale (número, não booleano).

## Regras (estritas, ao contrário do leitor atual)

- Campo desconhecido, em qualquer nível de `factory`, é ERRO com o caminho (`factory.review.foo`), não aviso.
- Tipo errado é erro com o caminho e o tipo esperado.
- Comandos (`architecture[]`, `ratchets[].measure`, `scenarios[].command`): mesmas regras de `command()` do leitor atual (texto, até 1000 caracteres, sem
  controle nem formato, não vazio). Reuse, não copie: torne o helper acessível ao novo tipo.
- `ratchets[].name` e `scenarios[].area` usam `validAreaName`; `ratchets[].name` único; `baseline` é caminho relativo ao repositório (sem `..`, sem `/`
  inicial, sem NUL, até 200 caracteres).
- `review.personas`: nomes `validAreaName`, sem repetição, até 20. `threshold`: `"blocker"` ou `"major"` (padrão `"major"`). `callOwner`: booleano.
- `guardrails.budgetSeconds` inteiro de 60 a 86400; `maxTries` inteiro de 1 a 10; `destructive` até 50 textos de até 200 caracteres sem controle;
  `land`: `"manual"` ou `"factory-paddock"` (padrão `"manual"`).
- `prose.traps`: até 200 ids de 8 caracteres hexadecimais minúsculos, sem repetição.
- Limites de listas: `architecture` até 50, `ratchets` até 50, `scenarios` até 100.
- O tamanho total do `collie-work.json` continua no limite atual de 16 KB (não mude `maxBytes`).

## API

`public struct FactoryProfile: Sendable, Equatable` com os campos tipados e valores padrão acima, e
`public static func parse(_ factory: Any) -> Result<FactoryProfile, FactoryProfile.ProfileError>` (recebe o valor de `factory` já decodificado), com
`ProfileError: Error, Sendable, Equatable` e `message` em português, uma linha, com o caminho. Em `ProjectWorkConfig`: propriedade nova
`public var factory: FactoryProfile?`; `parse` a preenche quando a chave existe e devolve falha (um novo caso `.invalidFactory(FactoryProfile.ProfileError)`
com `message` que repete a do perfil) quando ela é inválida. Sem a chave, `factory == nil` e o resultado é idêntico ao de hoje.

## Testes (`Tests/CollieDaemonKitTests/FactoryProfileTests.swift`, Swift Testing, junto de `ProjectWorkConfigTests`)

Perfil completo válido lido por inteiro; perfil só com `version`; sem `factory` (resultado igual ao de hoje e sem aviso); cada regra acima rejeitada com a
mensagem certa (campo desconhecido em dois níveis, tipo errado, `version` 2, `version` booleano, nome repetido, `..` no baseline, `threshold` inválido,
`land` inválido, orçamento fora da faixa, id de armadilha inválido ou repetido, comando com quebra de linha); `factory` presente e inválida faz o `parse` de
`ProjectWorkConfig` falhar; os testes antigos de `ProjectWorkConfigTests` seguem passando. Os testes de `ProjectWorkConfig` que checam o aviso de chave
desconhecida não podem passar a usar `factory` como a chave desconhecida.

Check: `scripts/check-fabrica-loop.sh u1`. Commit ao final, só os arquivos da tarefa.
