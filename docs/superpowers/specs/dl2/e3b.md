# E3b: device find --scroll

Depende de E3a (find sem rolagem, já integrado). Faça SÓ isto e COMMITE ao final (git add por caminho + git commit).

Seção S2 de `docs/superpowers/specs/2026-11-22-device-screen-find-design.md`, parte da rolagem: `--scroll [--dir down|up] [--max <n>]` no device find. Laço de no máximo --max (padrão 8) rolagens: dump, procura (use o find de E3a), senão desliza de 75% a 35% da altura (Android pixels, iOS pontos), espera o settle e repete. Para ao achar, quando a árvore fica igual à anterior (fim da lista, `endReached`) ou no máximo. Resposta inclui `scrolls` e `endReached`; notFound traz os dois. A palavra endReached deve aparecer em Sources/CollieDaemonKit/Devices/. Testes com adb/AXe falso: achou na 3ª volta, fim de lista, --max.

Regras: só --filter; não rode a suíte completa; não edite scripts/. O check é `scripts/check-device-loop2.sh e3b`.
