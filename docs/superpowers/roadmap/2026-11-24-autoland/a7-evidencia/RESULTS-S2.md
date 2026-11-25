# RESULTS S2

BASE0: 290b9711c797ee01914444c48b7fb314adef27be

## collie work status --events 100 (antes do done)
```
S2 portao — E2e, branch collie/e2e-fabrica [8918db1b-f0ca-42f3-909e-b2d423e4011d]
laço terminou (2 tentativas)
portão: bash scripts/gate.sh
avisos: só no fim
revisão: ligada, personas auto (só correcao, testes), veto a partir de major
origem revisão: flag
origem orçamento: perfil
origem tentativas: flag
aviso: factory.guardrails.destructive tem 1 padrão(ões); ainda não bloqueia comando
laço: 0/1 feitas · 0 na 1ª · 1 adiada · média 2,0 tentativas · 0s
tokens: 133,4 mil (índice relativo) · 6 msgs
Deferred (1):
  - S2 sub — loop: gate failed (exit 1) [acb64864]
Jobs:
  - shell /private/tmp/claude-501/-Users-USER-Documents-codes-collie-e2e-e2e1-repo (running)
Notes:
  - [loop acb64864] S2 sub, tentativa 1/2: gate failed (exit 1) (agente s2-portao-s2-sub-t1)
======================================================================
FAIL: test_sub_isca (tests.test_calc.CalcTests)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "~/Documents/codes/collie-e2e/e2e1/repo/.collie/paddocks/e2e-fabrica/tests/test_calc.py", line 12, in test_sub_isca
    self.assertEqual(sub(5, 3), 99)
AssertionError: 2 != 99

----------------------------------------------------------------------
Ran 3 tests in 0.000s

FAILED (failures=1)

  - [loop acb64864] S2 sub, tentativa 2/2: gate failed (exit 1) (agente s2-portao-s2-sub-t2)
======================================================================
FAIL: test_sub_isca (tests.test_calc.CalcTests)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "~/Documents/codes/collie-e2e/e2e1/repo/.collie/paddocks/e2e-fabrica/tests/test_calc.py", line 12, in test_sub_isca
    self.assertEqual(sub(5, 3), 99)
AssertionError: 2 != 99

----------------------------------------------------------------------
Ran 3 tests in 0.000s

FAILED (failures=1)

  - [loop] auto-land: 1 tarefa(s) não terminaram feitas; nada integrado
Commits:
  - 2f6e842 feat(calc): add sub with intentional red-gate bait test
Diário do laço:
00:53:13 attemptStarted Tacb64864#1
00:53:13 agentSummoned Tacb64864#1 s2-portao-s2-sub-t1
00:53:33 turnEnded Tacb64864#1 hook 20s ocupado
00:53:48 commitSeen Tacb64864#1 2f6e842
00:53:48 agentDismissed Tacb64864#1
00:53:49 checkStarted Tacb64864#1
00:53:49 checkFinished Tacb64864#1 exit 0
00:53:49 gateStarted Tacb64864#1
00:53:49 gateFinished Tacb64864#1 exit 1
00:53:49 verdict Tacb64864#1 gate failed (exit 1)
00:53:50 discarded Tacb64864#1 acb64864-1.patch
00:53:50 attemptStarted Tacb64864#2
00:53:50 agentSummoned Tacb64864#2 s2-portao-s2-sub-t2
00:54:11 turnEnded Tacb64864#2 hook 21s ocupado
00:54:26 commitSeen Tacb64864#2 d5da3ad
00:54:26 agentDismissed Tacb64864#2
00:54:26 checkStarted Tacb64864#2
00:54:27 checkFinished Tacb64864#2 exit 0
00:54:27 gateStarted Tacb64864#2
00:54:27 gateFinished Tacb64864#2 exit 1
00:54:27 verdict Tacb64864#2 gate failed (exit 1)
00:54:27 discarded Tacb64864#2 acb64864-2.patch
```
## git -C base log --oneline -4
```
290b971 e2e: specs S2 to S5
4777038 Land paddock (auto-land): S1 verde
cbe71fb feat(calc): add mul with test_mul
a0fadd4 e2e: spec S1
```
BASE HEAD agora: 290b9711c797ee01914444c48b7fb314adef27be
## git -C origin.git log --oneline
```
b8e3f6c e2e fixture: calc with unittest, gate and factory profile
```
## collie work done
```
{"id":"8918db1b-f0ca-42f3-909e-b2d423e4011d"}
```
## history --id 8918db1b-f0ca-42f3-909e-b2d423e4011d (notes, stopReason)
```
{"branch":"collie/e2e-fabrica","closedAt":"2026-11-25T03:54:41Z","id":"8918db1b-f0ca-42f3-909e-b2d423e4011d","loopSummary":"laço: 0/1 feitas · 0 na 1ª · 1 adiada · média 2,0 tentativas · 0s","notes":["[loop acb64864] S2 sub, tentativa 1/2: gate failed (exit 1) (agente s2-portao-s2-sub-t1)\n======================================================================\nFAIL: test_sub_isca (tests.test_calc.CalcTests)\n----------------------------------------------------------------------\nTraceback (most recent call last):\n  File \"~/Documents/codes/collie-e2e/e2e1/repo/.collie/paddocks/e2e-fabrica/tests/test_calc.py\", line 12, in test_sub_isca\n    self.assertEqual(sub(5, 3), 99)\nAssertionError: 2 != 99\n\n----------------------------------------------------------------------\nRan 3 tests in 0.000s\n\nFAILED (failures=1)\n","[loop acb64864] S2 sub, tentativa 2/2: gate failed (exit 1) (agente s2-portao-s2-sub-t2)\n======================================================================\nFAIL: test_sub_isca (tests.test_calc.CalcTests)\n----------------------------------------------------------------------\nTraceback (most recent call last):\n  File \"~/Documents/codes/collie-e2e/e2e1/repo/.collie/paddocks/e2e-fabrica/tests/test_calc.py\", line 12, in test_sub_isca\n    self.assertEqual(sub(5, 3), 99)\nAssertionError: 2 != 99\n\n----------------------------------------------------------------------\nRan 3 tests in 0.000s\n\nFAILED (failures=1)\n","[loop] auto-land: 1 tarefa(s) não terminaram feitas; nada integrado"],"openedAt":"2026-11-25T03:53:12Z","paddock":"e2e-fabrica","paddockId":"24c40b15-0cd3-4b9d-a0d0-599c82c4dd94","reconstructed":false,"tasks":[{"attempts":[{"agentSeconds":36,"checkSeconds":0,"n":1,"tokens":{"cacheRead":156809,"cacheWrite":35917,"input":6,"messages":3,"model":"claude-opus-5-5","output":929}},{"agentSeconds":36,"checkSeconds":0,"n":2,"tokens":{"cacheRead":164319,"cacheWrite":36523,"input":6,"messages":3,"model":"claude-opus-5-5","output":1210}}],"commits":[],"failure":"gate failed (exit 1)","id":"acb64864","state":"deferred","title":"S2 sub","tokens":{"cacheRead":321128,"cacheWrite":72440,"input":12,"messages":6,"model":"claude-opus-5-5","output":2139},"tries":2}],"terminal":"E2e","terminalId":"08edb699-e3f8-4690-9b65-fe39812e9431","timeline":[{"at":"2026-11-25T03:53:13Z","detail":"","kind":"attemptStarted","task":"acb64864"},{"at":"2026-11-25T03:53:13Z","detail":"s2-portao-s2-sub-t1","kind":"agentSummoned","task":"acb64864"},{"at":"2026-11-25T03:53:33Z","detail":"hook 20s ocupado","kind":"turnEnded","task":"acb64864"},{"at":"2026-11-25T03:53:48Z","detail":"2f6e842","kind":"commitSeen","task":"acb64864"},{"at":"2026-11-25T03:53:48Z","detail":"","kind":"agentDismissed","task":"acb64864"},{"at":"2026-11-25T03:53:49Z","detail":"","kind":"checkStarted","task":"acb64864"},{"at":"2026-11-25T03:53:49Z","detail":"exit 0","kind":"checkFinished","task":"acb64864"},{"at":"2026-11-25T03:53:49Z","detail":"","kind":"gateStarted","task":"acb64864"},{"at":"2026-11-25T03:53:49Z","detail":"exit 1","kind":"gateFinished","task":"acb64864"},{"at":"2026-11-25T03:53:49Z","detail":"gate failed (exit 1)","kind":"verdict","task":"acb64864"},{"at":"2026-11-25T03:53:50Z","detail":"acb64864-1.patch","kind":"discarded","task":"acb64864"},{"at":"2026-11-25T03:53:50Z","detail":"","kind":"attemptStarted","task":"acb64864"},{"at":"2026-11-25T03:53:50Z","detail":"s2-portao-s2-sub-t2","kind":"agentSummoned","task":"acb64864"},{"at":"2026-11-25T03:54:11Z","detail":"hook 21s ocupado","kind":"turnEnded","task":"acb64864"},{"at":"2026-11-25T03:54:26Z","detail":"d5da3ad","kind":"commitSeen","task":"acb64864"},{"at":"2026-11-25T03:54:26Z","detail":"","kind":"agentDismissed","task":"acb64864"},{"at":"2026-11-25T03:54:26Z","detail":"","kind":"checkStarted","task":"acb64864"},{"at":"2026-11-25T03:54:27Z","detail":"exit 0","kind":"checkFinished","task":"acb64864"},{"at":"2026-11-25T03:54:27Z","detail":"","kind":"gateStarted","task":"acb64864"},{"at":"2026-11-25T03:54:27Z","detail":"exit 1","kind":"gateFinished","task":"acb64864"},{"at":"2026-11-25T03:54:27Z","detail":"gate failed (exit 1)","kind":"verdict","task":"acb64864"},{"at":"2026-11-25T03:54:27Z","detail":"acb64864-2.patch","kind":"discarded","task":"acb64864"}],"title":"S2 portao","truncated":false,"version":1}
```

## stopReason
Campo `stopReason` ausente no resumo do trabalho (loop terminou sem land). Nota: "auto-land: 1 tarefa(s) não terminaram feitas; nada integrado". Tarefa `acb64864` state `deferred`, failure "gate failed (exit 1)" nas 2 tentativas (patches descartados).

## ESPERADO x OBTIDO
ESPERADO: nada integrado, tarefa não `done` (ou `landed` se corrigisse o 99). OBTIDO: nada integrado (BASE0 290b971 inalterada, origin só b8e3f6c), tarefa adiada após 2 tentativas; agente respeitou a isca e não corrigiu o 99, portão reprovou (2 != 99). Ramo sem stopReason explícito.
