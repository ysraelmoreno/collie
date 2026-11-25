# E3a: device find sem rolagem

A tarefa E3 (find completo) falhou 3 vezes sem deixar commit (provável: grande demais). Esta é a primeira metade; faça SÓ isto e COMMITE ao final (git add por caminho dos seus arquivos + git commit).

Seção S2 de `docs/superpowers/specs/2026-11-22-device-screen-find-design.md`, sem --scroll: `device find <texto> [--role tab|button|field] [--then screen]`. Em Plugins.swift o comando entra como dcmd("find"...). Casamento igual ao de `tap --text` (M3, já existe: reutilize o resolvedor, não copie) filtrando por papel do ScreenModel (E1, já existe). Devolve {found, ref, label, role, center, clickable} ou notFound com até 5 rótulos parecidos; os refs ficam válidos depois (tap --ref sem outro ui). Android e iOS. Testes em DeviceCommandTests e SimCommandTests: achou, não achou, --role.

Regras: só --filter; não rode a suíte completa; não edite scripts/. O check é `scripts/check-device-loop2.sh e3a`.
