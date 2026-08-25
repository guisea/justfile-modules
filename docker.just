# Docker build/buildx/push recipes shared across repos. The build logic itself is
# identical everywhere - only auth, registry, and image name differ per repo, so those
# are the only things this module asks the consumer to set.
# Import with: mod docker 'justfile-modules/docker.just'
#
# Per-repo config (env vars, or `export`ed from the consumer's own justfile before the
# `mod` line - `just` resolves module variables from the process environment):
#   IMAGE       - image name, e.g. "finchkeep"            (required)
#   REGISTRY    - registry host/namespace, e.g. "ghcr.io/cybercinch" (required for push/login)
#   DOCKERFILE  - defaults to "Dockerfile"
#   CONTEXT     - build context dir, defaults to "."
#   PLATFORMS   - buildx target platforms, defaults to "linux/amd64,linux/arm64"

image := env_var_or_default("IMAGE", "app")
registry := env_var_or_default("REGISTRY", "")
dockerfile := env_var_or_default("DOCKERFILE", "Dockerfile")
context := env_var_or_default("CONTEXT", ".")
platforms := env_var_or_default("PLATFORMS", "linux/amd64,linux/arm64")

_build_date := `date -u +%Y-%m-%dT%H:%M:%SZ`
_git_commit := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

# 🐳 Single-arch build, tagged `{{image}}:tag` (+ `:latest` if also_latest=true)
build tag dockerfile=dockerfile also_latest="false":
    #!/usr/bin/env bash
    set -euo pipefail
    # Builds once and tags both `tag` and `latest` in the same layer cache when
    # also_latest=true, so a versioned release doesn't need a second build.
    echo "🐳 build   {{image}}:{{tag}}  ({{dockerfile}})"
    TAGS=(-t "{{image}}:{{tag}}")
    if [[ "{{also_latest}}" == "true" ]]; then
        TAGS+=(-t "{{image}}:latest")
    fi
    docker build \
      -f "{{dockerfile}}" \
      --build-arg APP_VERSION="{{tag}}" \
      --build-arg APP_BUILD_DATE="{{_build_date}}" \
      --build-arg APP_GIT_COMMIT="{{_git_commit}}" \
      "${TAGS[@]}" \
      "{{context}}"
    echo "✅ built   {{image}}:{{tag}}"

# 📤 Tag + push a locally-built image to `{{registry}}/{{image}}:tag` (+ `:latest`)
push tag also_latest="true":
    #!/usr/bin/env bash
    set -euo pipefail
    # Assumes `just docker::login` already ran for {{registry}}.
    if [[ -z "{{registry}}" ]]; then
        echo "❌ REGISTRY is not set" >&2
        exit 1
    fi
    echo "📤 push    {{image}}:{{tag}}  →  {{registry}}"
    docker tag "{{image}}:{{tag}}" "{{registry}}/{{image}}:{{tag}}"
    docker push "{{registry}}/{{image}}:{{tag}}"
    if [[ "{{also_latest}}" == "true" ]]; then
        docker tag "{{image}}:latest" "{{registry}}/{{image}}:latest"
        docker push "{{registry}}/{{image}}:latest"
    fi
    echo "✅ pushed  {{image}}:{{tag}}"

# 🏗️  Create (or reuse) the multiarch buildx builder with QEMU emulation
buildx-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if docker buildx inspect multiarch >/dev/null 2>&1; then
        echo "✅ buildx builder 'multiarch' ready (already exists)"
        exit 0
    fi
    echo "🏗️  setup   multiarch buildx builder"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
    docker buildx create --name multiarch --driver docker-container --use --bootstrap
    docker buildx inspect multiarch
    echo "✅ buildx builder 'multiarch' ready"

# 🐳 Multi-arch build loaded locally (single platform only - buildx can't --load multi-arch)
buildx-build tag platform dockerfile=dockerfile: buildx-setup
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🐳 build   {{image}}:{{tag}}  [{{platform}}]  ({{dockerfile}})"
    docker buildx build \
      --builder multiarch \
      --platform "{{platform}}" \
      -f "{{dockerfile}}" \
      --build-arg APP_VERSION="{{tag}}" \
      --build-arg APP_BUILD_DATE="{{_build_date}}" \
      --build-arg APP_GIT_COMMIT="{{_git_commit}}" \
      -t "{{image}}:{{tag}}" \
      --load \
      "{{context}}"
    echo "✅ built   {{image}}:{{tag}}  [{{platform}}]"

# 🐳📤 Build + push a multi-arch image straight to `{{registry}}/{{image}}:tag`
buildx-push tag dockerfile=dockerfile also_latest="true": buildx-setup
    #!/usr/bin/env bash
    set -euo pipefail
    # Multi-platform images can only be pushed, never loaded locally - see
    # buildx-build for a local single-platform test build.
    if [[ -z "{{registry}}" ]]; then
        echo "❌ REGISTRY is not set" >&2
        exit 1
    fi
    TAGS=(-t "{{registry}}/{{image}}:{{tag}}")
    if [[ "{{also_latest}}" == "true" ]]; then
        TAGS+=(-t "{{registry}}/{{image}}:latest")
    fi
    echo "🐳📤 build+push  {{image}}:{{tag}}  [{{platforms}}]  →  {{registry}}"
    docker buildx build \
      --builder multiarch \
      --platform "{{platforms}}" \
      -f "{{dockerfile}}" \
      --build-arg APP_VERSION="{{tag}}" \
      --build-arg APP_BUILD_DATE="{{_build_date}}" \
      --build-arg APP_GIT_COMMIT="{{_git_commit}}" \
      "${TAGS[@]}" \
      --push \
      "{{context}}"
    echo "✅ pushed  {{image}}:{{tag}}  [{{platforms}}]"

# 🔐 Log in to `{{registry}}` with a token read from an env var (never a CLI arg)
login user token_env_var="REGISTRY_TOKEN":
    #!/usr/bin/env bash
    set -euo pipefail
    # Reads $REGISTRY_TOKEN by default (or whatever token_env_var names) so the
    # secret never lands in shell history or a process listing.
    if [[ -z "{{registry}}" ]]; then
        echo "❌ REGISTRY is not set" >&2
        exit 1
    fi
    TOKEN="${!token_env_var:-}"
    if [[ -z "$TOKEN" ]]; then
        echo "❌ \${{token_env_var}} is not set" >&2
        exit 1
    fi
    echo "🔐 login   {{user}}@{{registry}}"
    echo "$TOKEN" | docker login "{{registry}}" --username "{{user}}" --password-stdin
    echo "✅ logged in to {{registry}}"

# 🧹 Prune dangling images/containers/build cache
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🧹 clean   dangling images/containers/build cache"
    docker system prune -f
    docker image prune -f
    echo "✅ clean"
