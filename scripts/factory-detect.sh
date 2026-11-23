#!/usr/bin/env bash
# U2: what stack a project is, for /collie:factory init (docs/fabrica/skill/factory-init/SKILL.md).
# Usage: scripts/factory-detect.sh <dir>. Deterministic, no network, read only: prints one JSON object and writes nothing.
# Only the root's files are read (a monorepo's subprojects are the owner's call during the interview).
set -euo pipefail
dir="${1:?uso: scripts/factory-detect.sh <dir>}"
[ -d "$dir" ] || { echo "não é diretório: $dir" >&2; exit 2; }
PYTHONDONTWRITEBYTECODE=1 exec python3 -I - "$dir" <<'PY'
import json, os, re, sys, glob

root = sys.argv[1]
def p(*a): return os.path.join(root, *a)
def has(name): return os.path.isfile(p(name))
def text(name):
    try:
        with open(p(name), encoding="utf-8", errors="replace") as f: return f.read(256 * 1024)
    except OSError: return ""
# the root is escaped: a folder named "proj [a]*?" is that folder, not a glob
def files(pattern): return sorted(os.path.relpath(x, root) for x in glob.glob(os.path.join(glob.escape(root), pattern)) if os.path.isfile(x))

stacks, tools = [], {}
def found(stack, test=None, lint=None, fmt=None, **extra):
    stacks.append(stack)
    tools[stack] = {"testRunner": test, "linter": lint, "formatter": fmt, **extra}

if has("Package.swift"):
    found("swift", "swift test",
          "swiftlint" if has(".swiftlint.yml") else None,
          "swift-format" if has(".swift-format") else "swiftformat" if has(".swiftformat") else None)

if has("package.json"):
    # any parse failure (bad JSON, RecursionError on deep nesting) is a package.json with no signal, never a traceback
    try: pkg = json.loads(text("package.json"))
    except Exception: pkg = {}
    pkg = pkg if isinstance(pkg, dict) else {}
    deps = {}
    for k in ("dependencies", "devDependencies"):
        if isinstance(pkg.get(k), dict): deps.update(pkg[k])
    scripts = pkg.get("scripts") if isinstance(pkg.get("scripts"), dict) else {}
    # the manager is the lock file's; none: unknown (the init asks, npm is the fallback)
    pm = "pnpm" if has("pnpm-lock.yaml") else "yarn" if has("yarn.lock") else "npm" if has("package-lock.json") or has("npm-shrinkwrap.json") else None
    # npm init's default "test" (echo "Error: no test specified" && exit 1) is no test at all
    st = scripts.get("test")
    real = isinstance(st, str) and "no test specified" not in st
    test = "npx vitest run" if "vitest" in deps else "npx jest" if "jest" in deps else f"{pm or 'npm'} test" if real else None
    found("node", test, "eslint" if "eslint" in deps else None, "prettier" if "prettier" in deps else None,
          typecheck="tsc --noEmit" if "typescript" in deps else None, packageManager=pm)

py = files("requirements*.txt")
if has("pyproject.toml") or py:
    t = text("pyproject.toml") + "".join(text(x) for x in py)
    w = lambda n: re.search(r"(^|[^a-z0-9_-])" + n + r"([^a-z0-9_-]|$)", t, re.I | re.M) is not None
    found("python", "pytest" if w("pytest") else None, "ruff check" if w("ruff") else "flake8" if w("flake8") else None,
          "ruff format" if w("ruff") else "black" if w("black") else None)

gradle = files("build.gradle*")
if gradle:
    t = "".join(text(x) for x in gradle)
    found("kotlin", "./gradlew test" if has("gradlew") else "gradle test", "ktlint" if "ktlint" in t else "detekt" if "detekt" in t else None,
          "ktlint" if "ktlint" in t else None)

if has("pubspec.yaml"):
    found("flutter", "flutter test", "flutter analyze", "dart format")

if has("Cargo.toml"):
    found("rust", "cargo test", "cargo clippy", "cargo fmt")

if has("go.mod"):
    found("go", "go test ./...", "go vet ./...", "gofmt")

ci = files(".github/workflows/*.yml") + files(".github/workflows/*.yaml") + [x for x in ("Makefile", ".gitlab-ci.yml") if has(x)]
stack = stacks[0] if stacks else "unknown"
main = tools.get(stack, {"testRunner": None, "linter": None, "formatter": None})
out = {
    "stack": stack,
    "stacks": stacks,
    "testRunner": main["testRunner"],
    "linter": main["linter"],
    "formatter": main["formatter"],
    "tools": tools,
    "ci": sorted(ci),
    "existing": {
        "collieWork": has("collie-work.json"),
        "checkScripts": files("scripts/check-*.sh"),
        "personas": os.path.isdir(p("docs", "fabrica", "personas")),
    },
}
print(json.dumps(out, indent=2, sort_keys=True))
PY
