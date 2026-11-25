# A3: UI do cercado fábrica

A2 entregou `paddock factory <nome> on|off` (admin) e `paddock create --factory`, e `paddock list/status` com o campo `factory`. A3 põe isso no app. Só o dono, pela UI do app (o caminho admin); nada de MCP nem terminal de agente.

## O que fazer
1. **Painel de contexto** (`Sources/CollieApp/ContextPanel.swift`): uma seção "Fábrica" do cercado atual, com um interruptor Ligar/Desligar. Ligar chama o mesmo comando admin de `paddock factory <nome> on` (veja como o app chama outros comandos admin em `DaemonClient`/`PaddockActions`).
   Se o daemon recusar (doctor abaixo do mínimo, árvore suja, perfil ignorado), a mensagem exata da recusa aparece sob o interruptor (nada de erro genérico). Ligada: mostra a nota do doctor (as camadas, uma linha cada).
2. **Novo cercado** (`PaddockBar.swift`, `NewPaddockForm`): caixa "Cercado fábrica" (desligada por padrão). Só habilitada quando a pasta é git; marcada, o criar passa `factory: true`. `canCreate` e o estado da forma ficam testáveis sem SwiftUI (campo `factory` em `NewPaddockForm`).
3. **Trilho**: selo discreto (ícone ou "F") nos cercados fábrica, com texto de acessibilidade "cercado fábrica"; menu do cercado com "Ligar/Desligar fábrica".
4. O estado vem do mesmo dado de `paddock list` que o resto da UI já usa; mudou no daemon, o selo muda sem reiniciar.

## Testes (`Tests/CollieAppTests`, só modelos, sem SwiftUI renderizado)
Modelo do botão (rótulo, habilitado, mensagem de recusa), `NewPaddockForm` com `factory` (só com pasta git), selo do trilho. O texto de recusa do daemon chega inteiro ao modelo.

Check: `scripts/check-autoland-loop.sh a3`. Não faça mudanças de motor. Commit ao final, só os arquivos da tarefa.

Nomes obrigatórios das suítes (o check filtra por elas): `ContextPanelFactoryTests` e `NewPaddockFormTests` (arquivos novos em `Tests/CollieAppTests`).
