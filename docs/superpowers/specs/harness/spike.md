# Spike H0: o que a harness consegue bloquear, em Claude e em Cursor (medir, não supor)

Spec do spike da harness de desenvolvimento fora de laço (`docs/superpowers/specs/harness/design.md`, seção "Camadas"). **Não é tarefa de laço:** um terminal delegado (mesmo cercado, preset cursor ou claude conforme o ponto) mede e escreve o relatório. Nada de produto muda; nenhum bundle, instalação, push, e nada de `memory save` com laço rodando.

## Perguntas (cada uma com resultado medido: um valor da lista, o comando exato usado e a saída resumida)
1. **Cursor `preToolUse`:** o hook pode recusar uma chamada de ferramenta (um `Shell` com `git push`, um `Write` em `scripts/ci/x.sh`)? Em que formato o hook responde (stdout JSON? exit code?) e o Cursor respeita? Valores: `honored` | `ignored` | `error:<texto>`. Meça com um plugin de teste (como o `cursorPlugin` de `AgentLaunch`, fora do repositório do usuário, `--plugin-dir` temporário), num terminal Cursor de verdade.
2. **Cursor sem hook de fim de turno:** confirme que não há `stop`/equivalente na versão instalada (`cursor-agent --version`) e meça o que o daemon vê no fim do turno (ociosidade): quanto tempo até o fim ser detectado.
3. **Claude `PreToolUse`:** formato de recusa que o Claude Code respeita para `Bash` e para `Edit`/`Write` (`permissionDecision: "deny"` com motivo), e o que o agente vê da recusa. Valores como acima.
4. **Claude `Stop`:** o hook `Stop` pode devolver "bloqueie, continue" com a razão (formato, e o limite de laços para não travar)? Valores como acima.
5. **Git hooks sob o sandbox:** um `pre-commit` e um `pre-push` em `core.hooksPath` apontado para uma pasta gerenciada (fora do worktree do agente) rodam quando o **agente** faz `git commit`/`git push` num terminal do Collie (sandbox strict e open)? O agente consegue contornar com `--no-verify`, ou `git -c core.hooksPath=…`, ou apagando o hook? Valores: `runs` | `blocked-by-sandbox` | `bypassable:<como>`.
6. **Daemon como porteiro de comando:** o terminal do agente permite ao daemon interceptar `git push`/`rm -rf` antes de rodar (wrapper no PATH? shim de `git`?) sem quebrar o resto? Valores: `possible:<como>` | `not-possible:<porquê>`. Se só o git hook e o hook do agente existirem, diga qual é o furo restante.
7. **Latência:** custo medido de um hook de pré-ferramenta que roda um comando de 50 ms, 500 ms e 2 s (por chamada) no turno de cada agente.
## Entrega
Um relatório `docs/superpowers/specs/harness/spike-report.md` (o terminal devolve o texto como resposta de ask, e eu o gravo depois se houver laço rodando) com: a tabela das 7 perguntas (valor medido, comando, evidência), o que **não** deu para medir e por quê, e uma recomendação de qual mecanismo bloqueia de verdade em cada agente (Claude, Cursor) e qual é só feedback. Termine com: "a camada X pode ser `block` em Claude/Cursor: sim/não".
## Regras
Só leitura do repositório do usuário; testes com cercado e plugin temporários; não use `kill` em processos fora do seu terminal; não mexa em `~/.cursor` nem `~/.claude` do dono (use `--plugin-dir`/pastas temporárias); sem rede além do que o Cursor/Claude já usa.
