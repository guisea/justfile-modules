# Semantic version resolution, shared by every repo that tags images by version.
# Import with: mod version 'justfile-modules/version.just'

# 🏷️  Resolve the next version (semantic-release → git tag → commit hash → dev fallback)
version:
    #!/usr/bin/env bash
    set -euo pipefail
    # Prints only the version to stdout (status goes to stderr) - safe to capture
    # with VERSION=$(just version::version).
    VERSION=$(semantic-release --dry-run --no-ci 2>/dev/null | grep "next release version" | cut -d' ' -f4 || true)
    SOURCE="semantic-release"

    if [[ -z "${VERSION:-}" ]]; then
        VERSION=$(git describe --tags --exact-match 2>/dev/null || true)
        SOURCE="git tag"
    fi

    if [[ -z "${VERSION:-}" ]]; then
        VERSION=$(git rev-parse --short HEAD 2>/dev/null || true)
        SOURCE="commit hash"
    fi

    if [[ -z "${VERSION:-}" ]]; then
        VERSION="dev-$(date +%Y%m%d-%H%M%S)"
        SOURCE="dev fallback"
    fi

    echo "🏷️  version  $VERSION  (from $SOURCE)" >&2
    echo "$VERSION"

# 📦 Print version/commit/branch/build-date together - a release sanity check
version-info:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "📦 Version Information"
    echo "===================="
    echo "Next version: $(just --justfile '{{ justfile() }}' version 2>/dev/null)"
    echo "Git commit:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "Branch:       $(git branch --show-current 2>/dev/null || echo unknown)"
    echo "Build date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
