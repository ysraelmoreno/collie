# F6a: o CLI grava o baseline, o daemon só mede (rodada 3, revisor 1)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-3.md` (revisor 1: A, B, C). Arquivos: `Sources/CollieDaemonKit/FactoryCommands.swift`, `Sources/CollieCore/Ratchet.swift`, `Sources/collie/` (o CLI), `Sources/CollieProtocol/Commands.swift`, `Sources/CollieCore/FactoryDoctor.swift`, testes.

Desenho novo: a classe inteira de achados (daemon grava onde o sandbox do agente negaria) some se QUEM GRAVA É O PROCESSO DO AGENTE.
1. O comando do daemon `factory.ratchet` continua lendo o perfil, validando o nome e rodando o `measure` sob o perfil de sandbox (como hoje, F1), lendo o baseline atual pelo caminho confinado (leitura por `openat`/`O_NOFOLLOW`, como hoje)
   e comparando. Ele NÃO grava mais nada em disco. Para `update` e `raise` (quando há o que gravar) devolve `{output, passed, wrote: false, path, newBaseline: <texto completo>}`; `check` devolve `newBaseline: null`.
2. O CLI `collie factory ratchet update|raise` recebe `path` e `newBaseline` e grava ele mesmo, no processo do agente (sob o sandbox do agente): temporário no mesmo diretório criado com `O_EXCL|O_NOFOLLOW` e modo 0600, depois `fchmod` para 0644 (ou o modo do arquivo
   original, quando ele existe), `fsync` e `rename`; recusa link simbólico no destino e destino não regular. Em seguida imprime a saída como hoje (`wrote: true` só depois de gravar). Quem chama pelo MCP recebe o texto e o caminho e uma instrução curta para gravar (o MCP não grava).
   Como o sandbox decide o que o CLI pode escrever, `.zshenv`, `.git` aninhado e o resto já são negados por ele; o CLI NÃO precisa copiar listas.
3. As guardas do daemon (`place`, raiz = home/ancestral, `confinedPath`, `target`) ficam como defesa extra para a LEITURA e para o caminho devolvido; corrija B de qualquer forma: passe a `mayWrite` o caminho resolvido (`realPath`) e compare sem diferença de caixa em todos os componentes;
   a raiz usa `rec.projectRoot` e `home: sandboxHomeDir` como o resto do daemon (nit E). Remova o código de escrita do daemon (`write`, `renameat`) e o que ficar sem uso; os testes de escrita do daemon viram testes do CLI/escritor (coloque o escritor puro em `Sources/CollieCore` para testar sem processo).
4. Doctor (minor C): `viaPackageScript` varre TODAS as linhas que rodam testes e casa `(npm|yarn|pnpm|bun)\s+(run(-script)?\s+)?(test|t)\b`.
5. Testes (sem `sandbox-exec` real): o daemon nunca cria nem altera o arquivo do baseline (checar mtime/ausência após `update` e `raise`); o escritor grava atômico, 0644, recusa link e não regular, não deixa temporário; `newBaseline` e `path` corretos; `check` não devolve texto; o teste da ligação do sandbox (RatchetTests) segue passando; `mayWrite` com caminho de caixa diferente é recusado.

Check: `scripts/check-fabrica-loop.sh f6a`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`. Atualize os textos de `factory-init/SKILL.md` e dos README se citarem quem grava o baseline.
