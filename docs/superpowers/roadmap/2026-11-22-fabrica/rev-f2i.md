# Revisão independente, rodada 9 (A5 e A6)

Revisores: seguranca (approve; 1 minor, 1 nit) e motor-concorrencia (approve; 2 minor, 2 nit). JSON em `rev-f2i/`.
Nenhum blocker nem major: o critério da F2 (uma rodada sem blocker ou major) está cumprido. Blocker da rodada 8 (revisor mais fraco que o julgado): fixed.

Abertos (minor/nit, sem efeito além do parecer, que nunca aprova):
- `agentsOpen`: o ramo por terminal é código morto, porque o agente julgado é dispensado antes da revisão (`WorkLoop` `.dismiss`); decide sempre o `sandboxMode` de agora. Julgado de lane (strict) em workspace open pula o `plantedConfig`; julgado open com o modo virado para strict roda o check. Correção: guardar o modo do julgado no passo `.dismiss`, antes do `dismissReaping`.
- Sem teste que falhe se A5 ou A6 sumirem (revisor nasce `strict` num workspace open; `loopAgentSandboxed(strict: true)` recusa terminal open; `RouterLoopHost.agentsOpen` com e sem terminal).
- Busca por nome em `agentsOpen`; comentário de `LoopHost.agentsOpen` com premissa contestada; dois saltos ao actor.
- Doc: "o revisor nasce sempre em strict" só vale com sandbox de terminal (corrigido em `docs/referencia.md`).
