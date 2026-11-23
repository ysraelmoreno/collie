#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # Package.swift". The loop's judge guards every file
# the gate's text names (substring): this script and the manifest that governs the runner:
#   Package.swift
# Limit: the gate does not see binaries in ignored folders such as .build (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test
