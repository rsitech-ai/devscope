#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$DEFAULT_ROOT_DIR"
ROOT_WAS_EXPLICIT=0
SKIP_DEPENDENCY_CHECK=0

usage() {
  cat <<'EOF'
Usage: check_open_source_readiness.sh [--root PATH] [--skip-dependency-check]

Validates the repository's public-source policy, collaboration metadata, and
dependency declaration. The dependency check may be skipped only for isolated
checker tests that do not contain a Swift package.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "error: --root requires a path" >&2; exit 2; }
      ROOT_DIR="$2"
      ROOT_WAS_EXPLICIT=1
      shift 2
      ;;
    --skip-dependency-check)
      SKIP_DEPENDENCY_CHECK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$ROOT_DIR" ]] || { echo "error: repository root does not exist: $ROOT_DIR" >&2; exit 2; }
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

if [[ "$SKIP_DEPENDENCY_CHECK" -eq 1 ]]; then
  if [[ "$ROOT_WAS_EXPLICIT" -ne 1 ]]; then
    echo "error: --skip-dependency-check requires an explicit isolated --root fixture" >&2
    exit 2
  fi
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: --skip-dependency-check cannot be used for a Git working tree" >&2
    exit 2
  fi
fi

failures=0

fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

required_files=(
  LICENSE
  NOTICE
  README.md
  CHANGELOG.md
  CODE_OF_CONDUCT.md
  CONTRIBUTING.md
  GOVERNANCE.md
  PRIVACY.md
  SECURITY.md
  SUPPORT.md
  THIRD_PARTY_NOTICES.md
  TRADEMARKS.md
  .gitleaks.toml
  .github/CODEOWNERS
  .github/PULL_REQUEST_TEMPLATE.md
  .github/dependabot.yml
  .github/ISSUE_TEMPLATE/bug.yml
  .github/ISSUE_TEMPLATE/config.yml
  .github/ISSUE_TEMPLATE/feature.yml
  .github/workflows/release-gates.yml
  .github/workflows/secret-scan.yml
  script/check_open_source_readiness.sh
  script/package_community_preview.sh
  docs/ARCHITECTURE.md
  docs/INSTALLATION.md
  docs/RELEASING.md
  docs/open-source/OPEN_SOURCE_MANIFEST.json
  docs/open-source/OPEN_SOURCE_STATUS.md
  docs/open-source/PUBLICATION_GATE_MATRIX.md
  docs/open-source/SBOM.spdx.json
)

for relative_path in "${required_files[@]}"; do
  [[ -s "$ROOT_DIR/$relative_path" ]] || fail "required public-source file is missing or empty: $relative_path"
done

if [[ -s "$ROOT_DIR/NOTICE" ]]; then
  grep -Fq "Copyright 2026 Rafal Sikora" "$ROOT_DIR/NOTICE" \
    || fail "public identity is missing copyright owner Rafal Sikora from NOTICE"
  grep -Fq "RSI Tech" "$ROOT_DIR/NOTICE" \
    || fail "public identity is missing maintainer RSI Tech from NOTICE"
  grep -Fq "https://rsitech.ai" "$ROOT_DIR/NOTICE" \
    || fail "public identity is missing website https://rsitech.ai from NOTICE"
  grep -Fq "info@rsitech.ai" "$ROOT_DIR/NOTICE" \
    || fail "public identity is missing project contact info@rsitech.ai from NOTICE"
fi

internal_publication_paths=(
  .codex
  docs/audits
  docs/monetization
  docs/superpowers
)

for relative_path in "${internal_publication_paths[@]}"; do
  if [[ -e "$ROOT_DIR/$relative_path" ]]; then
    fail "internal publication material must not be present: $relative_path"
  fi
done

if [[ -s "$ROOT_DIR/LICENSE" ]]; then
  grep -Fq "Apache License" "$ROOT_DIR/LICENSE" || fail "LICENSE must identify the Apache License"
  grep -Fq "Version 2.0, January 2004" "$ROOT_DIR/LICENSE" || fail "LICENSE must contain Apache-2.0 version text"
  license_digest="$(shasum -a 256 "$ROOT_DIR/LICENSE" | awk '{print $1}')"
  [[ "$license_digest" == "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30" ]] \
    || fail "LICENSE differs from the official Apache-2.0 text"
fi

public_surface=(
  README.md
  CHANGELOG.md
  CODE_OF_CONDUCT.md
  CONTRIBUTING.md
  GOVERNANCE.md
  PRIVACY.md
  SECURITY.md
  SUPPORT.md
  THIRD_PARTY_NOTICES.md
  TRADEMARKS.md
  docs/ARCHITECTURE.md
  docs/INSTALLATION.md
  docs/RELEASING.md
  docs/open-source/OPEN_SOURCE_STATUS.md
  docs/open-source/PUBLICATION_GATE_MATRIX.md
)

if ! python3 - "$ROOT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
paths = []
for directory in (root / "docs", root / ".github"):
    if directory.is_dir():
        paths.extend(path for path in directory.rglob("*") if path.is_file())
paths.extend(
    root / name
    for name in (
        "README.md", "CHANGELOG.md", "CODE_OF_CONDUCT.md", "CONTRIBUTING.md",
        "GOVERNANCE.md", "PRIVACY.md", "SECURITY.md", "SUPPORT.md",
        "THIRD_PARTY_NOTICES.md", "TRADEMARKS.md", "NOTICE",
    )
    if (root / name).is_file()
)
text_suffixes = {"", ".md", ".json", ".toml", ".txt", ".yaml", ".yml"}
patterns = (
    re.compile(r"/Users/(?!example(?:/|\b))[^/\s]+/"),
    re.compile(r"/private/var/folders/"),
    re.compile(r"/Volumes/(?!Example(?:/|\b))[^/\s]+/"),
    re.compile(r"[A-Za-z]:\\Users\\(?!example(?:\\|\b))", re.IGNORECASE),
)
for path in sorted(set(paths)):
    if path.suffix.lower() not in text_suffixes:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for line_number, line in enumerate(text.splitlines(), 1):
        if any(pattern.search(line) for pattern in patterns):
            relative = path.relative_to(root)
            raise SystemExit(f"workstation-specific path in {relative}:{line_number}")
PY
then
  fail "published text contains a workstation-specific path"
fi

if command -v ruby >/dev/null 2>&1; then
  if ! ruby - "$ROOT_DIR" <<'RUBY'
require "yaml"

def validate_action_references(node, path)
  case node
  when Hash
    node.each do |key, value|
      if key.to_s == "uses"
        reference = value.to_s
        next if reference.start_with?("./")
        if reference.start_with?("docker://")
          unless reference.match?(/@sha256:[0-9a-f]{64}\z/i)
            raise "Docker action is not pinned to an image digest in #{path}: #{reference}"
          end
        elsif !reference.match?(/@[0-9a-f]{40}\z/i)
          raise "GitHub Action is not pinned to a full commit SHA in #{path}: #{reference}"
        end
      else
        validate_action_references(value, path)
      end
    end
  when Array
    node.each { |value| validate_action_references(value, path) }
  end
end

def validate_permission_map(permissions, context)
  unless permissions.is_a?(Hash) && !permissions.empty?
    raise "workflow must declare an explicit permission map: #{context}"
  end
  unexpected = permissions.reject { |_scope, access| ["read", "none"].include?(access) }
  unless unexpected.empty?
    raise "workflow requests unexpected write permission: #{context}: #{unexpected.inspect}"
  end
end

root = ARGV.fetch(0)
paths = Dir[File.join(root, ".github", "**", "*.{yml,yaml}")].sort
paths.each do |path|
  document = YAML.safe_load(
    File.read(path, encoding: "UTF-8"),
    permitted_classes: [],
    permitted_symbols: [],
    aliases: false
  )
  next unless path.include?(File.join(".github", "workflows"))

  validate_permission_map(document["permissions"], path)
  jobs = document["jobs"]
  unless jobs.is_a?(Hash) && !jobs.empty?
    raise "workflow must declare at least one job: #{path}"
  end
  jobs.each do |job_name, job|
    next unless job.is_a?(Hash) && job.key?("permissions")
    validate_permission_map(job["permissions"], "#{path} job #{job_name}")
  end
  validate_action_references(document, path)
end
RUBY
  then
    fail "GitHub YAML metadata is not syntactically valid"
  fi
else
  fail "Ruby is required to validate GitHub YAML metadata"
fi

if ! python3 - "$ROOT_DIR" "${public_surface[@]}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for relative in sys.argv[2:]:
    path = root / relative
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(r"!?\[[^\]]*\]\(([^)]+)\)", text):
        target = match.group(1).strip().strip("<>")
        if not target or target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = target.split("#", 1)[0]
        resolved = (path.parent / target).resolve()
        if not resolved.exists():
            raise SystemExit(f"broken local Markdown link in {relative}: {target}")
PY
then
  fail "public documentation contains a broken local Markdown link"
fi

while IFS= read -r workflow; do
  [[ -s "$workflow" ]] || continue
  grep -Eq '^permissions:' "$workflow" || fail "workflow must declare top-level permissions: ${workflow#"$ROOT_DIR/"}"
done < <(find "$ROOT_DIR/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort)

manifest="$ROOT_DIR/docs/open-source/OPEN_SOURCE_MANIFEST.json"
if [[ -s "$manifest" ]]; then
  if ! python3 - "$manifest" <<'PY'
import json
import pathlib
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)

required = {
    "schemaVersion",
    "project",
    "license",
    "sourcePublication",
    "productionDistribution",
    "dependencies",
    "security",
}
missing = sorted(required - manifest.keys())
if missing:
    raise SystemExit("missing keys: " + ", ".join(missing))
if manifest["license"] != "Apache-2.0":
    raise SystemExit("license must be Apache-2.0")
if not isinstance(manifest["dependencies"], list):
    raise SystemExit("dependencies must be a list")
if manifest.get("sbom") != "docs/open-source/SBOM.spdx.json":
    raise SystemExit("manifest SBOM pointer is invalid")
PY
  then
    fail "open-source manifest is invalid: docs/open-source/OPEN_SOURCE_MANIFEST.json"
  fi
fi

sbom="$ROOT_DIR/docs/open-source/SBOM.spdx.json"
if [[ -s "$sbom" ]]; then
  if ! python3 - "$sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("spdxVersion") != "SPDX-2.3":
    raise SystemExit("spdxVersion must be SPDX-2.3")
if document.get("dataLicense") != "CC0-1.0":
    raise SystemExit("dataLicense must be CC0-1.0")
namespace = document.get("documentNamespace", "")
if not namespace.startswith("https://github.com/") or "/devscope/" not in namespace.lower():
    raise SystemExit("documentNamespace must identify the DevScope GitHub source document")
packages = document.get("packages")
if not isinstance(packages, list) or not packages:
    raise SystemExit("SBOM must contain the DevScope package")
package = next((item for item in packages if item.get("name") == "DevScope"), None)
if (
    package is None
    or package.get("versionInfo") != "0.1.0"
    or package.get("licenseDeclared") != "Apache-2.0"
    or package.get("licenseConcluded") != "Apache-2.0"
):
    raise SystemExit("SBOM package identity or license is invalid")
relationships = document.get("relationships", [])
if not any(
    relationship.get("spdxElementId") == "SPDXRef-DOCUMENT"
    and relationship.get("relationshipType") == "DESCRIBES"
    and relationship.get("relatedSpdxElement") == package.get("SPDXID")
    for relationship in relationships
):
    raise SystemExit("SBOM must describe the DevScope package")
PY
  then
    fail "SPDX SBOM is invalid: docs/open-source/SBOM.spdx.json"
  fi
fi

if [[ -d "$ROOT_DIR/docs" ]]; then
  while IFS= read -r json_file; do
    if ! python3 -m json.tool "$json_file" >/dev/null; then
      fail "JSON document is invalid: ${json_file#"$ROOT_DIR/"}"
    fi
  done < <(find "$ROOT_DIR/docs" -type f -name '*.json' -print | LC_ALL=C sort)
fi

if [[ -d "$ROOT_DIR/.git" ]] || git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for relative_path in "${required_files[@]}"; do
    if ! git -C "$ROOT_DIR" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
      fail "required public-source file is not tracked by Git: $relative_path"
    fi
  done
  tracked_artifacts="$(git -C "$ROOT_DIR" ls-files | grep -E '(^|/)(\.build|dist|DerivedData)(/|$)|(^|/)\.DS_Store$' || true)"
  [[ -z "$tracked_artifacts" ]] || fail "generated artifacts are tracked: ${tracked_artifacts//$'\n'/, }"
fi

if [[ "$SKIP_DEPENDENCY_CHECK" -eq 0 ]]; then
  [[ -s "$ROOT_DIR/Package.swift" ]] || fail "Package.swift is required for dependency validation"
  if [[ -s "$ROOT_DIR/Package.swift" ]]; then
    dependency_json="$(mktemp)"
    trap 'rm -f "$dependency_json"' EXIT
    if swift package --package-path "$ROOT_DIR" show-dependencies --format json >"$dependency_json"; then
      if ! python3 - \
        "$dependency_json" \
        "$ROOT_DIR/docs/open-source/OPEN_SOURCE_MANIFEST.json" \
        "$ROOT_DIR/docs/open-source/SBOM.spdx.json" \
        "$ROOT_DIR/THIRD_PARTY_NOTICES.md" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)
actual_entries = package.get("dependencies")
if actual_entries is None:
    raise SystemExit("dependency output omitted the dependencies field")
actual_identities = set()
pending = list(actual_entries)
while pending:
    entry = pending.pop()
    identity = (entry.get("identity") or entry.get("name") or "").lower()
    if not identity:
        raise SystemExit("dependency output contains an unidentified package")
    actual_identities.add(identity)
    pending.extend(entry.get("dependencies") or [])
actual = sorted(actual_identities)

with open(sys.argv[2], encoding="utf-8") as handle:
    manifest = json.load(handle)
declared_entries = manifest.get("dependencies")
if not isinstance(declared_entries, list):
    raise SystemExit("manifest dependencies must be a list")
declared = []
for entry in declared_entries:
    identity = entry if isinstance(entry, str) else entry.get("identity", "")
    if not identity:
        raise SystemExit("manifest dependency entry is missing identity")
    declared.append(identity.lower())
declared.sort()
if actual != declared:
    raise SystemExit(f"dependency manifest mismatch: actual={actual}, declared={declared}")

with open(sys.argv[3], encoding="utf-8") as handle:
    sbom = json.load(handle)
sbom_dependencies = sorted(
    entry.get("name", "").lower()
    for entry in sbom.get("packages", [])
    if entry.get("name") != "DevScope"
)
if actual != sbom_dependencies:
    raise SystemExit(f"SBOM dependency mismatch: actual={actual}, sbom={sbom_dependencies}")

notices = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8").lower()
missing_notices = [identity for identity in actual if identity not in notices]
if missing_notices:
    raise SystemExit("dependencies missing from third-party notices: " + ", ".join(missing_notices))
PY
      then
        fail "Swift dependency declarations do not match the manifest, SBOM, and notices"
      fi
    else
      fail "Swift dependency graph could not be generated"
    fi
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  echo "Open-source readiness check failed with $failures issue(s)." >&2
  exit 1
fi

echo "Open-source readiness check passed."
