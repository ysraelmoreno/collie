# PRD A3: primeiro prompt e ask enviados de fato ao Cursor

PRD geral: `README.md` desta pasta (problema 4). Roda depois do A1 (mesmo arquivo).

## Problema

Observado em 2026-11-24: `summon cursor-probe --prompt "…"` deixou o texto na barra do Cursor sem enviar. O `wait`
seguinte respondeu `{"idle":true}` na hora (falso término) e o `ask` seguinte foi digitado na mesma barra
(`…one short sentence.Go.`) e só então enviado.

O caminho de escrita (`AskCoordinator.swift`, `pump`, ~linha 813-845) escreve o texto, espera
`PromptInjector.submitDelay` e manda o Enter. Só o Claude tem confirmação do envio (`confirmSubmit`, linha 990,
que reenvia o Enter uma vez); para o Cursor não há nenhuma. A causa exata de o Enter se perder (Ink ainda montando a
barra, paste entre colchetes, tempo) não foi medida.

## Fazer

1. **Medir primeiro.** Reproduzir com o preset `cursor` numa pasta já confiada (sem diálogo): `summon --prompt` e
   gravar o scrollback cru. Anotar no commit qual é o caso (Enter antes da barra pronta, Enter dentro do paste, outro).
2. **Confirmação para o Cursor** (`cursorTUI`), no mesmo molde do `confirmSubmit`: enviado = o rodapé
   `ctrl+c to stop` (`AskCoordinator.cursorWorking`) aparece nas últimas linhas depois da escrita. Sem ele em
   `submitConfirm`, reenviar o Enter uma vez (com a mesma guarda `approval.inputIfClear`) e registrar `submitRetried`.
   Se o passo 1 mostrar que o problema é a barra ainda não pronta, a correção é na prontidão (`pollReady`, linha 676):
   para `cursorTUI`, pronto só depois de a barra (`→ `) estar na tela.
3. `wait` num Cursor com um inject ainda na fila ou sem envio confirmado não responde `idle:true`.

## Aceite

- Teste com um PTY falso que imita o Cursor (desenha a barra, ignora o primeiro Enter, depois mostra
  `ctrl+c to stop`): o prompt é enviado com um reenvio, e o evento `submitRetried` sai uma vez (em `AskSubmitRetryTests`).
- PTY falso que aceita o primeiro Enter: nenhum reenvio (teste).
- `wait` logo depois de `summon --prompt`, antes do envio confirmado: não responde idle (teste).
- Claude: comportamento igual ao de hoje (os testes existentes passam).

## Check

```
swift test --disable-sandbox --filter AskSubmitRetryTests && swift test --disable-sandbox --filter AskTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
