#!/usr/bin/env bash
# Checks of the Fábrica para usuários tasks (docs/superpowers/specs/fabrica/*.md): scripts/check-fabrica-loop.sh u1|u3|u5|u2|u4|f1|f2|f3|f4|f5a|f5b|f6a|f6b
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?u1|u3|u5|u2|u4|f1|f2|f3|f4|f5a|f5b|f6a|f6b}" in
  u1) t --filter FactoryProfileTests --filter ProjectWorkConfigTests --filter WorkAreaTests --filter WorkConfigTamperTests \
        && test -f Sources/CollieCore/FactoryProfile.swift && grep -q "invalidFactory" Sources/CollieCore/ProjectWorkConfig.swift ;;
  u3) t --filter FactoryDoctorTests --filter FactoryProfileTests --filter ProjectWorkConfigTests \
        && test -f Sources/CollieCore/FactoryDoctor.swift && test -f Sources/CollieDaemonKit/FactoryCommands.swift ;;
  u5) t --filter RatchetTests --filter FactoryDoctorTests \
        && test -f Sources/CollieCore/Ratchet.swift && git diff --quiet "$(git merge-base HEAD main)" -- scripts/ci/lint.sh scripts/ci/ci-skip.txt ;;
  u2) t --filter FactoryModelsTests --filter FactoryDoctorTests \
        && scripts/test-factory-detect.sh && test -f docs/fabrica/skill/factory-init/SKILL.md ;;
  u4) t --filter FactoryBaitTests --filter FactoryDoctorTests \
        && test -f docs/fabrica/iscas/catalogo.json && test -f docs/fabrica/skill/factory-bait/SKILL.md ;;
  f1) t --filter RatchetTests --filter FactoryDoctorTests --filter FactoryProfileTests --filter ProjectWorkConfigTests ;;
  f2) t --filter FactoryBaitTests --filter FactoryDoctorTests --filter RatchetTests --filter FactoryModelsTests ;;
  f3) t --filter FactoryModelsTests --filter FactoryBaitTests --filter FactoryDoctorTests && scripts/test-factory-detect.sh ;;
  f4) t --filter WorkCommandTests --filter WorkLoopReviewTests ;;
  f5a) t --filter RatchetTests --filter FactoryBaitTests --filter FactoryDoctorTests --filter FactoryModelsTests --filter FactoryProfileTests ;;
  f5b) t --filter FactoryModelsTests --filter FactoryBaitTests --filter FactoryDoctorTests && scripts/test-factory-detect.sh ;;
  f6a) t --filter RatchetTests --filter FactoryDoctorTests --filter FactoryBaitTests --filter FactoryProfileTests ;;
  f6b) t --filter FactoryModelsTests --filter FactoryDoctorTests --filter FactoryBaitTests && scripts/test-factory-detect.sh ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
