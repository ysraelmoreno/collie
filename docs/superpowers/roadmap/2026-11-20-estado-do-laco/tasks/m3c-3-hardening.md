# M3c.3 Endurecer o perfil da faixa, o `remove`, o SIGKILL do portão e a marca

Leia `onda3c.md` e os **achados 4, 5 e 6** de `rev-onda3b-report.md`. Código: `Sandbox/SandboxProfile.swift` (~180 `sub(worktree)`, ~245-253 denies de `gitdir|commondir|config.worktree|collie-lane`), `Work/LaneWorktree.swift` (~53-57 `ownsPath`, ~131-137 `isMarked`, ~144-149 `remove`), `BoundedProcess.swift` (~64-67 `onCancel`, ~97, ~139), `Tests/CollieDaemonKitTests/LaneRefsProfileTests.swift`, `LaneHostTests.swift` (`ProfileRules`).

## Fazer
1. **Perfil da faixa:** `deny file-write*` nas **pastas em si** da faixa (`lit(<faixa>)`) e da sua pasta de administração (`lit(<common>/worktrees/lane-X)`): o conteúdo continua gravável, mas a pasta não pode ser renomeada nem apagada (o git não precisa disso dentro da faixa). Mantenha os denies atuais.
2. **`ownsPath` e `remove`:** recusar quando o caminho **é** (ou contém no caminho) um symlink: `realPath(path) == padronizado(path)`; uma faixa trocada por symlink não é removida e vira nota de aviso.
3. **SIGKILL do portão cancelado:** guardar o **pgid** separado do pid e enviar o sinal ao grupo mesmo depois de o líder ser colhido, enquanto os drains não terminaram.
4. **Marca:** `isMarked` compara o **UUID inteiro** do trabalho (não só os 8 primeiros caracteres).
5. Faixas sem marca ou com branch órfão: o varredor continua **poupando** (nunca remove sem marca), mas a nota de aviso sai **uma vez por daemon** em vez de a cada fim de laço.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneHardeningTests.swift`
`ProfileRules` do perfil da faixa A: escrita **negada** em renomear/apagar a pasta da faixa e a pasta de admin, **permitida** no conteúdo e no que o commit grava; `ownsPath`/`remove` recusam um symlink no lugar da faixa (git real em repositório temporário, sem tocar na faixa de outro trabalho); um filho que sobrevive ao líder é morto pelo grupo no cancelamento (processo de teste simples, sem `sleep`); `isMarked` com UUIDs que só compartilham os 8 primeiros caracteres não confunde; a nota de faixa sem marca sai uma vez. Suítes de perfil e de varredor seguem verdes.
