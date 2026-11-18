# B4.1 Mapa de funcionalidades do Collie

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b4-mapa-funcionalidades.md` (requisitos 1–2).

## Fazer

1. `docs/feature-map.md`: uma seção por superfície que o usuário vê: canvas; cada `Sources/ColliePlugins/*Panel.swift`
   (citar o nome do arquivo sem extensão); menus e cartões do app (`Sources/CollieApp/`); grupos da CLI
   (`collie <grupo>`, de `docs/referencia.md`). Por seção: nome como aparece na UI (as strings em português do código),
   para que serve (1 linha), arquivos, como verificar (comando, `collie check --screen`, ou passo à mão). Nomes da UI
   tirados do código, não inventados.
2. `scripts/ci/lint.sh`: regra `feature-map`: todo `Sources/ColliePlugins/*Panel.swift` citado (nome sem extensão) em
   `docs/feature-map.md`; erro diz qual falta e onde acrescentar. Sem baseline para essa regra.
3. `scripts/ci/test-lint.sh`: caso de painel não citado falha.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
