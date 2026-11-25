# Roadmap: auto-land no cercado fábrica (F4 sem aceite)

Data: 2026-11-24 · Estado: CONCLUÍDO em 2026-11-25 (A1 a A7, F3, F5 e correções C1 a C6; evidência em `a7-evidencia/`; entra na v0.2.0 como preview). Origem: `docs/superpowers/roadmap/2026-11-22-fabrica/README.md` (seção F4) e a decisão de 2026-11-23 de
fazer a F4 **sem** o aceite em runtime (F3) no primeiro recorte. Cartão pai no Quadro: `bcc3aa9b` (Cercado fábrica). Rótulo dos cartões: `autoland`.

## Objetivo
Um cercado marcado como fábrica, ligado só pelo dono, consome a fila de trabalhos aprovados: cada trabalho roda no laço com revisão; quando tudo passa, o laço integra (`paddock land`) e
inicia o próximo trabalho. Para sozinho e chama o dono quando algo exige julgamento. **Nunca faz push nem release.**

## Princípios (herdados da Fábrica para usuários)
- Fail closed: qualquer dúvida para e chama o dono; nunca "segue em frente".
- Só o dono liga a marca (comando de admin; nunca MCP nem terminal de agente).
- O Collie garante o isolamento do juiz, não a qualidade dos checks: o auto-land só vale tanto quanto o gate e a revisão do projeto (o `factory doctor` mostra isso).
- Tudo que o motor aplica vem do perfil COMMITADO no base, nunca da árvore do agente.
- Cada passo que muda o motor (A1, A4, A5, A6) pede bundle novo e instalação do dono.

## Condições de land (F4 sem F3)
Todas as tarefas do trabalho `done`; portão (`gate` do perfil) verde; revisão sem veto na última tentativa de cada tarefa; CI local dos alvos afetados verde
(`scripts/ci/run-tests.sh`); árvore do cercado limpa; sem outro agente trabalhando. A quarta condição, **aceite em runtime (F3)**, entra depois e só aperta.

## Etapas (cada uma um cartão do Quadro, na ordem)

| # | Etapa | Mexe em | Bundle? | Depende de |
|---|---|---|---|---|
| A1 | `work run` aplica o bloco `factory` do perfil (revisão e guardrails como padrões; flag explícita vence; `work status` mostra a origem) | motor | sim | U1 (feito) |
| A2 | Marca do cercado fábrica: `paddock create --factory`, `paddock factory <nome> on\|off` (admin), `paddock list/status` com `factory`, linha no doctor | daemon, CLI | sim | A1 |
| A3 | UI: botão no painel de contexto, caixa em Novo cercado, selo e menu no trilho | app | sim | A2 |
| A4 | `work run --auto-land` (só em cercado marcado): as condições acima, CI local, `paddock land`, `stopReason` próprio por falha | motor | sim | A1, A2 |
| A5 | Próximo trabalho da fila após o land, com teto por execução (`--auto-land-max N`, padrão 1) e teto por dia | motor | sim | A4 |
| A6 | Aviso de fim e resumo imutável: o que entrou, quem aprovou o quê, "pronto para push"; chamada ao dono por `notify` quando para | motor | sim | A4 |
| A7 | Validação ponta a ponta: cercado fábrica descartável (repositório temporário), isca que o portão deve barrar, isca verde que deve integrar, parada por conflito | testes + roteiro | não | A4 a A6 |
| F3 | Aceite em runtime (`--accept`) vira a 4ª condição | motor | sim | A7 |

## Primeiro recorte (a spec desta rodada): A1 e A2
São as duas peças sem as quais o auto-land não tem de onde ler a política nem onde ligar. Specs em `docs/superpowers/specs/autoland/a1-perfil-aplicado.md` e `a2-marca-cercado.md`.
A3 (UI), A4, A5, A6 e A7 ganham spec quando o passo anterior entrar na main, porque dependem de detalhes do motor que A1 e A2 vão fixar.

## Riscos
- **Falsa confiança:** gate fraco gera land de código ruim. Mitigação: cercado fábrica só liga com o doctor sem camada abaixo de 1 em static e judge (A2), e o resumo do land mostra a nota do doctor.
- **Corrida com o dono:** o dono edita o cercado enquanto o laço integra. Mitigação: árvore suja ou outro agente trabalhando para o laço (condição de land).
- **Custo sem teto:** A5 só entra com os dois tetos (execução e dia).
- **Land que quebra a main:** o CI local e o portão rodam antes; o resumo registra o commit anterior para o dono reverter com um comando.
