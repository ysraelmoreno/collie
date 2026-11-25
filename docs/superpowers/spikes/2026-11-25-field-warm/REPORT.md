# Spike F0: `.build` clonado compila incremental noutro caminho?

Data: 2026-11-25. HEAD `e33e40fa`. Swift 6.2.4 (arm64-apple-macosx15.0). Comando: `lockf -k .collie/build.lock swift build --build-tests`.
Worktree do spike em `.collie/paddocks/field-spike` (removida no fim). `.build` do cercado: 12 GB, quente (rebuild no-op: 6,5 s).

## Resultados

| # | Caso | Tempo | Resultado | Módulos compilados (alvos com `Compiling`) |
|---|------|-------|-----------|------------------------------------------|
| 1 | frio (sem `.build`) | 505 s | ok | 34 (676 linhas `Compiling`) |
| 2 | clonado (`cp -c -R`, 36 s para clonar 12 GB) | 7,6 s | **erro** | 6 antes de falhar |
| 3 | clonado + `touch Sources/CollieCore/Work.swift` | 4,1 s | **erro** | idem, falha igual |
| 4 | caminho fixo `--scratch-path <raiz>/.collie/build-cache/fixed`: semente no cercado | 436 s | ok | 34 |
| 5 | caminho fixo, build no field-spike (outra raiz de fontes) | 354 s | ok | 32 de 34 (654 linhas) |
| 6 | caminho fixo, field-spike + 1 arquivo tocado | 2,9 s | ok | 2 (4 linhas) |

Erro dos casos 2 e 3 (o clone não é aproveitado nem como cache, o build aborta):

```
error: PCH was compiled with module cache path '<cercado>/.build/arm64-apple-macosx/debug/ModuleCache/1YI5N4MN8ROEJ', but the path is currently '<cercado>/.collie/paddocks/field-spike/.build/arm64-apple-macosx/debug/ModuleCache/1YI5N4MN8ROEJ'
error: missing required module 'SwiftShims'
```

## Notas

- Build concorrente ("clonado" com o build do cercado rodando junto): não medido. O lock compartilhado serializa os builds por regra, e o caso já falha sozinho.
- Caso 5: o caminho fixo evita o erro de PCH, mas as fontes estão noutra raiz e quase tudo recompila (32 de 34 alvos, 354 s contra 436–505 s do frio). Ganho dentro da variação de um build frio. O caso 6 é incremental normal dentro do mesmo field, não efeito do cache.
- `-file-prefix-map` não foi testado: os dados do build incremental (swiftdeps, dependências) guardam caminhos das fontes, que mudam por worktree; o caso 5 mostra que o caminho do scratch sozinho não basta.

## Decisão

`warm` **sai do F1/F2** (não vale). Clonar `.build` não funciona (erro de PCH/module cache por caminho absoluto), e usar `--scratch-path` fixo roda, mas recompila quase tudo (≈ frio), sem ganho que justifique a complexidade. O field faz build frio na primeira vez (~7–8 min) e incremental depois (segundos), dentro do próprio `.build`.
