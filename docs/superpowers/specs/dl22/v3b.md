# V3b: o arquivo temporário da gravação de ~/.claude.json nasce 0600

Achado do `motor-concorrencia` na V3 (`Sources/CollieDaemonKit/Work/WorkLoopReview.swift`, a gravação atômica de `~/.claude.json`): o arquivo temporário é
criado com `FileManager.createFile` no modo padrão (0644 sob o umask usual) e só depois recebe `chmod`; por uma janela curta uma cópia de
`~/.claude.json` (pode ter `primaryApiKey` e `oauthAccount`) fica legível por outros usuários.
Fazer: criar o temporário já com 0600 (`open(path, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0o600)` e escrever pelo descritor), depois o `rename` e o modo
final igual ao do arquivo original; apagar o temporário se algo falhar. Adicionar os dois testes que o revisor `testes` pediu na V3: falha de escrita
(a regra 4: o laço segue e a nota diz o motivo) e `projects` ou a entrada que não é objeto (não toca). Teste de que o temporário nasce 0600 (leia o
modo de um temporário parado antes do rename, ou injete a criação). Check: `scripts/check-f2fix9-loop.sh v3b`. Commit ao final.
