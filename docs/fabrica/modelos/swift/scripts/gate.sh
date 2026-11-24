#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh". The loop's judge guards every file the gate's text
# names (substring): this script. swift test has no pure runner config, and the manifest that governs the runner,
#   Package.swift
# stays out of the gate's text on purpose, so a task may add a dependency or a target (the reviewer sees a removed test target).
# Limit: the gate does not see binaries in ignored folders such as .build (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test
