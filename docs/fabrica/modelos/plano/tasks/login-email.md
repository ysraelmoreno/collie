# Login por e-mail e senha

check: swift test --filter LoginTests
scope: Sources/Auth/**, Tests/AuthTests/**

## O que fazer

`Auth.login(email:senha:)` devolve a sessão ou o erro de credencial. Senha errada três vezes bloqueia por 5 min.

## Pronto quando

- `LoginTests` cobre: sucesso, senha errada, bloqueio na terceira e desbloqueio depois de 5 min (relógio injetado).
- Nenhum outro teste muda.

## Fora do escopo

Tela, recuperação de senha.
