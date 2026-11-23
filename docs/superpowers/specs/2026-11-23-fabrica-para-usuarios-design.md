# Fábrica para usuários: perfil, init, doctor, isca e catraca

Data: 2026-11-23 · Estado: proposta. Vem depois da F2 (revisão por personas no laço, validada de ponta a ponta em 2026-11-23) e
usa a F3 (verificação em runtime) e a F4 (land automático) como pré-requisitos do perfil completo. Cartões no Quadro:
`8f0bc60e` (pai), `11123a3a` (init), `c7483884` (doctor), `443b33ca` (isca), `9a87f53e` (catraca).

## Problema

O Collie já executa uma fábrica de software neste repositório: ideia, tarefas com checks, laço, revisão por personas,
verificação, land. Ela só funciona bem para quem tem a disciplina deste repositório. Para outro projeto não há descoberta de
stack, nem andaime, nem medida de quão forte é a fábrica: a catraca de lint é um script nosso (`scripts/ci/lint.sh`,
`lint-baseline.txt`), ninguém mede a força dos checks do usuário, e uma fábrica fraca parece igual a uma forte até quebrar.

## Princípio

A fábrica é tão forte quanto os checks do usuário. O Collie garante o **isolamento do juiz** e não a qualidade dos checks:

- check e gate rodam fora do controle do agente sobre o commit julgado;
- scripts citados pelo gate, `collie-work.json`, personas e spec são lidos do commit base;
- a revisão é um parecer que nunca aprova sozinho (só um veto `blocker` ou `major` confirmado falha a tentativa), e fica
  sem parecer, sem fingir, quando o revisor cala;
- sandbox, orçamento e tentativas limitados; push e release manuais.

O que o Collie faz a mais é tornar a **fraqueza visível**: cada camada ganha uma nota e uma próxima ação, e uma isca mede se a
fábrica de fato pega um defeito conhecido.

## A pirâmide invertida (camadas)

Empurrar a garantia para cima (mecânica, barata) e depender o mínimo das camadas de baixo.

| Camada | O que o Collie dá hoje | Lacuna |
|---|---|---|
| Análise estática | `--check`, `--gate`, `--precheck`, `areas`/`smoke` em `collie-work.json`; catraca de lint (script nosso) | gate que só compila; catraca não é genérica |
| Verificação em runtime | nada (F3 `--accept` não existe) | cenários de aceite executáveis, aparelho ou navegador |
| Revisão | personas e `--review` (parecer), validado de ponta a ponta | calibrar o revisor carimbador |
| Prosa para regra | `memory enforce` converte armadilha em check; evidência de uso medida em 0,2% | elo mais fraco |
| Humano | push e release manuais; personas substituem a PR no fluxo interno | fail closed chama o dono |
| Codebase | regras de arquitetura e persona de simplicidade ajudam | não garantimos |

## Desenho

Tudo **fora do daemon**: conhecimento em skill e app, o motor só aplica (a mesma decisão dos fluxos).

### U1. Perfil de fábrica declarativo

Um arquivo versionado na raiz do projeto, que estende `collie-work.json` (o motor já o lê do commit base). Por camada:

- `static`: `gate`, `precheck`, `smoke`, `areas`, regras de arquitetura, `ratchets` (U5);
- `verification`: cenários de aceite por área (F3);
- `review`: personas, modelos, limiares, quando chamar o dono;
- `guardrails`: orçamento, tentativas, ações destrutivas, política de land (só em cercado fábrica);
- `prose`: armadilhas a converter em check.

Esquema com `version`; campo desconhecido é erro (mesma regra estrita do leitor atual).

### U2. `/collie:factory init` (skill)

Skill, sem código novo no daemon. Entrevista o projeto e gera o perfil.

- **Detecção:** `Package.swift`, `package.json`, `pyproject.toml`/`requirements`, `build.gradle`, `pubspec.yaml`, `Cargo.toml`,
  `go.mod`; test runner, linter, formatter e CI que já existem.
- **Gera, de modelos por stack versionados:** o perfil; scripts `scripts/check-*.sh` (um check mede só a própria tarefa e nunca só
  "compila"); cópia das personas padrão em `docs/fabrica/personas` (editáveis); esqueleto de CI quando não existe; baseline inicial
  da catraca.
- **Entrevista curta:** o que nunca pode quebrar, quanto o gate pode levar, quais ações são destrutivas, se há aparelho ou
  navegador, política de land.
- **Tarefa piloto** pequena no fim, para calibrar o gate e mostrar o ciclo completo antes de qualquer uso real.

### U3. `collie factory doctor`

Somente leitura, determinístico, sem LLM, menos de 30 s. Pontua cada camada de 0 a 3, com evidência e próxima ação; código de saída
para CI.

- **Estática:** o gate existe e roda em tempo razoável? cobre testes ou só compila (comando só com `build`, `tsc --noEmit`,
  `swift build` sem test runner = FRACO)? há catraca? o CI roda o mesmo gate? o check só faz `grep` no arquivo que a tarefa criou?
- **Isolamento do juiz:** o gate cita script que a tarefa poderia editar sem o guard? `collie-work.json`, personas e specs são
  lidos do commit base?
- **Verificação:** há cenário de aceite executável? aparelho ou navegador disponíveis?
- **Revisão:** personas presentes e roteáveis; modelo diferente do de quem trabalha; histórico do revisor.
- **Prosa:** quantas armadilhas recorrentes (`collie memory list --candidates`) ainda não viraram check.
- **Guardrails e saúde:** orçamento e tentativas; taxa de 1ª tentativa, revertidos depois do land, adiadas, custo por tarefa.

Modo opcional com LLM só para sugerir conserto, nunca para pontuar.

### U4. Tarefa-isca

A medida honesta de que a fábrica **funciona**, e não só de que está configurada. Sob demanda (`collie factory bait`) ou
periodicamente, o Pastor cria uma tarefa com um defeito conhecido plantado numa **cópia descartável** (nunca no repositório
real), roda o ciclo normal e registra qual camada pegou, ou se passou.

- Catálogo por stack, versionado, com o defeito e a camada que deveria pegá-lo.
- Catálogo inicial no Collie (5): lógica, teste enfraquecido, segredo no diff, corrida, spec editado pelo agente.
- Saída: taxa de captura por camada e por persona, iscas que passaram, custo. Uma isca que passa derruba a nota da camada no doctor.

Primeira evidência, medida em 2026-11-23: uma isca com bug pedido na spec (divisor `len(xs) + 1`) passou no check e foi vetada pelo
revisor `correcao` (`[major]` com arquivo e linha); o laço reagiu e a 2ª tentativa corrigiu. A F2 já provou o mecanismo uma vez.

### U5. Catraca genérica

"O número só pode melhorar" é genérico; o script `lint.sh` não. Extrair um recurso reutilizável: baseline versionado por regra
(contagem ou lista), comando que mede, falha se piorar, baixa o baseline quando melhora, recusa subir sem razão registrada. Serve a
qualquer linter (swiftlint, eslint, ruff, ktlint) e à lista de testes pulados (`ci-skip.txt`: só encolhe, com razão).

## Tarefas

| # | Tarefa | Depende de |
|---|---|---|
| U1 | Esquema do perfil (leitor estrito, testes) | `collie-work.json` |
| U5 | Catraca genérica; `lint.sh` e `ci-skip` passam a usá-la sem mudar o comportamento | U1 |
| U3 | `collie factory doctor` | U1 |
| U2 | `/collie:factory init` e modelos por stack | U1, U3, U5 |
| U4 | `collie factory bait` e catálogo de iscas | F2, U3 |

U1 antes de tudo; U3 e U5 podem andar juntos; init por último, porque precisa do doctor para validar o que gera.

## Critérios de aceite

1. Em 3 projetos de stacks diferentes (Swift, Node/TS, Python), `init` produz um perfil que passa no doctor com a nota mínima
   definida e roda a tarefa piloto até o fim, sem o dono.
2. No repositório do Collie a nota por camada bate com o que sabemos: estática forte, verificação baixa até a F3, prosa fraca.
3. Um projeto de exemplo com gate que só compila é marcado FRACO na análise estática.
4. O doctor roda em menos de 30 s e é determinístico.
5. No Collie, o catálogo inicial de iscas tem taxa de captura medida; as que passam viram tarefas de melhoria; a isca nunca toca o
   repositório real.
6. O lint e o `ci-skip` do Collie, na catraca genérica, dão o mesmo resultado de hoje (testes de regressão); um projeto com eslint
   recebe a catraca em um comando.

## Riscos

- **Falsa confiança:** nota alta com checks fracos. A isca (U4) e a regra "o doctor desconfia de check que só compila" mitigam; a nota é
  de configuração, não prova de qualidade.
- **Heurística de stack errada:** projetos fora do comum. O `init` pergunta antes de gravar e nunca sobrescreve arquivo existente.
- **Modelos por stack envelhecem:** versionados no repositório, com dono e data; o doctor avisa quando o modelo usado é mais antigo que
  o instalado.
- **Revisor carimbador:** o parecer não é prova de independência (limite conhecido de `~/.claude.json`); a isca mede a captura real.
- **Escopo:** é um programa de várias ondas. Só U1 e U5 são pré-requisitos de tudo; não abrir o init antes do doctor.
