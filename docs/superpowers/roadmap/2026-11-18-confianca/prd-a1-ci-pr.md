# PRD A1: CI em PR com testes dos targets afetados

## Problema

Nenhum workflow roda em PR ou em push na `main`: `release.yml` e `figcraft.yml` só disparam por tag ou à mão. Um commit
de agente que quebra o build só aparece quando alguém builda. A regra "nunca a suíte completa" (memória `no-full-suite`)
é aplicada à mão: cada agente adivinha o `--filter` certo.

## Objetivo

- Todo PR e todo push na `main` rodam build, lint (A2), arquitetura (A3) e os testes dos targets afetados.
- O mapeamento "arquivos mudados → suítes de teste" é um script determinístico, usado pelo CI e pelos agentes (e pelo
  laço como check).

## Não-objetivos

- Assinar, notarizar ou empacotar (fica no `release.yml`).
- Cache sofisticado de build. Só o cache simples de `.build` do `actions/cache`, se couber em poucas linhas.
- Rodar a suíte inteira em PR, exceto quando o script disser `ALL`.

## Requisitos

1. `scripts/ci/affected-tests.sh [<base>]`: lista arquivos mudados entre `<base>` (padrão `origin/main`) e `HEAD`.
   `--files <f>…` recebe a lista direto (para teste).
2. Saída (stdout, uma linha):
   - vazia: nada a testar (só `docs/`, `scripts/` exceto `scripts/ci/`, `.md`);
   - `ALL`: `Package.swift`, `Package.resolved` ou `Resources/` mudaram;
   - senão um regex de `--filter` com os test targets afetados, ex.: `CollieThemeTests|CollieAppTests`.
3. `Sources/<T>/…` afeta todo test target que depende de `<T>` direta ou transitivamente; `Tests/<X>/…` afeta `<X>`;
   `Tests/Fixtures/…` → `ALL`.
4. O grafo vem de `swift package dump-package` + `jq` (ambos já disponíveis; sem dependência nova).
5. `.github/workflows/ci.yml`: `pull_request` e `push` em `main`; `runs-on: macos-26` (o mesmo do `release.yml`);
   `fetch-depth: 0`; passos: `swift --version`, `scripts/ci/lint.sh`, `scripts/ci/check-architecture.sh`,
   `swift build --build-tests`, testes conforme a saída do script. Nenhum `secrets.` no arquivo.
6. Testes do script em `scripts/ci/test-affected-tests.sh`, no estilo de `scripts/ci/test-update-pin.sh`.

## Medida de resultado

- O primeiro PR depois do land mostra o check verde em < 20 min.
- Um PR que só toca `docs/` termina sem rodar testes.
- Um PR com erro de compilação de propósito fica vermelho.

## Tarefas

- A1.1 `affected-tests.sh` e seu teste (`tasks/a1-1-affected-tests.md`)
- A1.2 `ci.yml` (`tasks/a1-2-ci-workflow.md`), depois de A2.1 e A3.1 (chama os scripts deles)

## Riscos

- O runner `macos-26` precisa de Swift 6.2: copiar a seleção de Xcode do `release.yml`.
- `dump-package` lento a frio: aceitável (segundos).
