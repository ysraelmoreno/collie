# Tela de login

check: swift test --filter LoginViewTests
accept: scripts/accept/login.sh
accept-timeout: 900
scope: Sources/App/Login/**, Tests/AppTests/LoginViewTests.swift

## O que fazer

Tela com e-mail, senha e "Entrar", que chama `Auth.login` e mostra o erro abaixo do campo.

## Pronto quando

- `LoginViewTests`: o botão fica desligado com campo vazio; o erro aparece com a mensagem de `Auth`.
- O aceite abre o app, entra com o usuário de teste e vê a tela inicial.
