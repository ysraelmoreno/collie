# Estado do laço, Onda 5: economia de tokens dentro do daemon

Pedido do dono (2026-11-21): as práticas que cortam gasto de tokens devem **estar no daemon, valendo para todo usuário**, e não só no comportamento de um Pastor. Continua `README.md`, `onda2.md`, `onda3-paralelismo.md`, `onda3c.md`.

## Medição que motivou (2026-11-19 a 21, índice relativo de tokens, transcripts do Claude Code)
- O **Pastor** foi ~53% do gasto; os agentes dos laços ~37%; revisores e CI ~9%. Um agente de laço custa ~0,35 M por tentativa; o Pastor ~45 mil **por chamada** porque relê o contexto inteiro.
- Cerca de **62% do gasto do Pastor foi disparado por eventos automáticos**: avisos do laço (27%) e notificações de tarefas em segundo plano (35%); só 38% por mensagens do dono.
- Stop hook: o pedido "registre decisões e armadilhas" volta a cada turno enquanto o laço commita (`MemoryCapture.hasNewWork` olha commits novos, inclusive os do próprio laço).
- Tentativas inteiras perdidas por: limite de uso do modelo (o agente trava no diálogo até o timeout de 1 h), suítes instáveis.

## Princípio
O daemon **não acorda o Pastor** (nem gasta turno de ninguém) sem necessidade, **diz o que custou** e **evita desperdício previsível**. Nada disso muda o que o laço faz com o código; só o que ele diz, quando e a que custo. Texto vindo de transcript/agente é dado: só **contagens** são lidas, nunca conteúdo.

## Tarefas (nesta ordem)

| # | Tarefa | Ganho esperado |
|---|---|---|
| M5.1 | Avisos do laço: padrão `end` (+ agrupar avisos em janela) | ~−70% dos turnos de aviso |
| M5.2 | Stop hook: pedir memória só quando faz sentido (limite de frequência, nunca durante laço do mesmo trabalho) | ~−2 a 3% + menos ruído |
| M5.3 | Detectar o limite de uso do modelo e parar o laço na hora, com razão clara | evita 1 h de timeout e tentativas queimadas |
| M5.4 | Contabilidade de tokens por tentativa (só contagens) em `work status` e no resumo | torna o gasto visível |
| M5.5 | Conselho de contexto grande no Stop hook (uma vez, curto) | induz sessão nova: ~−60% do custo do Pastor |
| M5.6 | Modelo padrão dos agentes do laço configurável; orientação do Pastor sobre esperar | agentes no modelo certo |

## Fora do escopo
Mudar o prompt das tentativas; cobrar/limitar uso; ler conteúdo de transcripts; qualquer UI além de ler campos novos opcionais (o histórico de laços do Trilho 2 mostrará os tokens depois).

## Regras
As do roadmap do laço (`README.md`, "Regras aprendidas na prática"). Verificação: `scripts/laco-check.sh M5.n`. **Esta onda toca hooks e o motor: revisão independente antes do bundle.**
