# PRD C: Cercas, convenção minerada vira bloqueio (a detalhar depois de V2)

PRD geral: `README.md` desta pasta. Depende de V2 rodando em uso real.

## Problema

O Vizinho orienta, mas não impede. O que é quase unânime no projeto (um módulo nunca importa outro, todo arquivo
de um tipo tem teste) deveria bloquear, sem o dono escrever a regra.

## Objetivo

O plug-in propõe cercas a partir da mesma estatística do Vizinho; o dono aprova; daí em diante o gancho `stop`
bloqueia o turno que as quebra, com a causa raiz na mensagem.

## Fatias previstas (cada uma vira PRD próprio)

- **C1 Mineração**: varredura do projeto → propostas (`pasta X: 0 de 40 importam Y`), só acima de 95% e com pelo
  menos 10 arquivos. Pura, em `VizinhoKit`. Check: testes da suíte.
- **C2 Aprovação**: onde o dono vê e aprova as propostas. **Decisão em aberto, do dono:**
  (a) página do plug-in, o que exige comandos `runs: "helper"` (mais uma peça da fase 2 de plug-ins);
  (b) `collie plugin` ganha um comando genérico de configuração por plug-in, só do usuário;
  (c) arquivo na pasta de dados do plug-in, editado pelo dono à mão.
  Em qualquer uma: o agente nunca aprova nem edita (as cercas ficam fora do projeto).
- **C3 Bloqueio**: no `stop`, os arquivos do turno são checados contra as cercas aprovadas; quebra → `block` com
  o arquivo, a cerca e o modelo a seguir.
- **C4 Catraca**: adotar uma cerca num projeto que já a quebra: as violações existentes entram num baseline que
  só pode diminuir (o que `scripts/ci/lint.sh` faz hoje para o próprio Collie).
- **C5 Correção vira cerca**: correção repetida do usuário (`repeatCorrections`) gera proposta; aprovada, a
  memória correspondente passa a `enforced` (`collie memory enforce`).

## Antes de detalhar

Medir o Vizinho por uma semana: quantas orientações entregues, quantas seguidas (o arquivo passou a ter o import
ou o teste no mesmo turno). Se a orientação já resolve a maioria, C3 começa só pelas convenções que continuam
sendo quebradas.
