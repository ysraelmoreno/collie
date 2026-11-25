# R1: uma só mensagem e uma só validação de `preset`

Origem: auditoria de simplicidade de 2026-11-23 (cartão de refactor). A string `"preset must be shell|claude|codex|cursor|custom"` aparece 4 vezes: `Sources/CollieDaemonKit/CommandRouter.swift` (linhas ~728 e ~799), `ShepherdCommands.swift:96`, `WorkLoopCommands.swift:67`.

Fazer: um único ponto que valida o texto do preset e lança o erro `invalidArgs` com a mesma mensagem (por exemplo `Preset.parse(_ s: String) throws(ProtocolError) -> Preset` numa extensão em `Sources/CollieDaemonKit`, ou o nome que casar com o resto do código), e os 4 lugares passam a usá-lo. Comportamento e texto da mensagem idênticos; nenhum outro arquivo muda. Sem mudar a API pública do protocolo.

Não mude: o que cada comando faz depois de validar, nem testes existentes. Acrescente um teste pequeno (Swift Testing, junto de `WorkCommandTests`) que chama o helper com `"claude"` (ok) e com `"nope"` (erro `invalidArgs` com a mensagem exata).

Check: `scripts/check-refactor-loop.sh r1`. Commit ao final, só os arquivos da tarefa.
