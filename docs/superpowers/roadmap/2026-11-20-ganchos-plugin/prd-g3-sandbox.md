# PRD G3: perfil de sandbox do helper

PRD geral: `README.md` desta pasta.

## Problema

O helper é código de terceiros que roda a cada edição. Precisa de um perfil Seatbelt próprio: lê o projeto e a
própria pasta, escreve só na sua pasta de dados, sem rede e sem o home.

## Fazer (arquivo novo `Sources/CollieDaemonKit/Plugins/PluginHelperProfile.swift` e
`Tests/CollieDaemonKitTests/PluginHelperProfileTests.swift`; nenhum outro arquivo)

1. `struct PluginHelperInput { helper: URL; pluginDir: URL; project: URL; dataDir: URL }`.
2. `enum PluginHelperProfile { static func render(_:) -> String }`, no estilo de `CuratorSandboxProfile`
   (`Sources/CollieDaemonKit/Curator/CuratorSandboxProfile.swift`), reusando `SandboxProfile.q`/`re`:
   - `(deny default)`;
   - executar: o helper e os interpretadores de sistema (`/bin/sh`, `/bin/bash`, `/usr/bin/env`, e o que estiver
     em `/usr/bin`, `/bin`), para um helper em script funcionar;
   - ler: `pluginDir`, `project`, bibliotecas e frameworks do sistema (o mínimo que um binário Swift e um `sh`
     precisam para iniciar; medir, uma permissão por linha);
   - escrever: só `dataDir` (e `/dev/null`);
   - sem rede, sem sockets Unix, sem leitura do home fora do que está acima.
   Caminhos resolvidos para o caminho real, como o perfil do curador faz.
3. `static func command(_ input:, profile: String) -> (executable: URL, args: [String])`: a linha
   `/usr/bin/sandbox-exec -p <perfil> <helper>`.

## Aceite

`PluginHelperProfileTests`, com execução real de `sandbox-exec` num diretório temporário e um helper `sh`:

- lê um arquivo do projeto e o imprime;
- escreve em `dataDir`;
- falha ao escrever no projeto;
- falha ao ler um arquivo de um diretório temporário fora do projeto e da pasta do plug-in;
- falha ao abrir conexão de rede (`/usr/bin/nc -z 127.0.0.1 <porta>` ou equivalente sem dependência);
- um binário Swift mínimo (compile com `swiftc` no teste só se já houver precedente; senão basta o `sh`).

Se o ambiente de teste não permitir `sandbox-exec` (já dentro de um sandbox), o teste detecta e pula com motivo,
como os testes de sandbox existentes fazem; os testes do texto do perfil rodam sempre.

## Check

```
swift test --disable-sandbox --filter PluginHelperProfileTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
