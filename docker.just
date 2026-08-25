# Docker build/buildx/push recipes shared across repos. The build logic itself is
# identical everywhere - only auth, registry, and image name differ per repo, so those
# are the only things this module asks the consumer to set.
# Import with: mod docker 'justfile-modules/docker.just'
#
# Per-repo config, read from real process env vars - module variables are resolved via
# env_var_or_default, which only sees actual OS environment, NOT `export X := "..."`
# assignments in the consumer's own justfile (modules don't inherit those). So set these
# either in your shell, or in a `.env` file next to the consuming justfile with
# `set dotenv-load` at its top:
#   IMAGE       - image name, e.g. "finchkeep"            (required)
#   REGISTRY    - registry host/namespace, e.g. "ghcr.io/cybercinch" (required for push/login)
#   REGISTRIES  - comma-separated registries to push to, e.g. "docker.io/me,123.dkr.ecr.us-east-1.amazonaws.com"
#                 (defaults to REGISTRY, so single-registry repos can ignore this entirely -
#                 push/buildx-push transparently fan out to one registry or many)
#   DOCKERFILE  - defaults to "Dockerfile"
#   CONTEXT     - build context dir, defaults to "."
#   PLATFORMS   - buildx target platforms, defaults to "linux/amd64,linux/arm64"

image := env_var_or_default("IMAGE", "app")
registry := env_var_or_default("REGISTRY", "")
registries := env_var_or_default("REGISTRIES", registry)
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

# 📤 Tag + push a locally-built image to each of `{{registries}}` (+ `:latest`)
push tag also_latest="true":
    #!/usr/bin/env bash
    set -euo pipefail
    # Assumes `just docker::login` already ran for every registry in REGISTRIES.
    if [[ -z "{{registries}}" ]]; then
        echo "❌ REGISTRY/REGISTRIES is not set" >&2
        exit 1
    fi
    IFS=', ' read -ra REGS <<< "{{registries}}"
    for REG in "${REGS[@]}"; do
        [[ -z "$REG" ]] && continue
        echo "📤 push    {{image}}:{{tag}}  →  $REG"
        docker tag "{{image}}:{{tag}}" "$REG/{{image}}:{{tag}}"
        docker push "$REG/{{image}}:{{tag}}"
        if [[ "{{also_latest}}" == "true" ]]; then
            docker tag "{{image}}:latest" "$REG/{{image}}:latest"
            docker push "$REG/{{image}}:latest"
        fi
    done
    echo "✅ pushed  {{image}}:{{tag}}  →  {{registries}}"

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

# 🐳📤 Build + push a multi-arch image straight to each of `{{registries}}`
buildx-push tag dockerfile=dockerfile also_latest="true": buildx-setup
    #!/usr/bin/env bash
    set -euo pipefail
    # Multi-platform images can only be pushed, never loaded locally - see
    # buildx-build for a local single-platform test build.
    if [[ -z "{{registries}}" ]]; then
        echo "❌ REGISTRY/REGISTRIES is not set" >&2
        exit 1
    fi
    IFS=', ' read -ra REGS <<< "{{registries}}"
    TAGS=()
    for REG in "${REGS[@]}"; do
        [[ -z "$REG" ]] && continue
        TAGS+=(-t "$REG/{{image}}:{{tag}}")
        if [[ "{{also_latest}}" == "true" ]]; then
            TAGS+=(-t "$REG/{{image}}:latest")
        fi
    done
    echo "🐳📤 build+push  {{image}}:{{tag}}  [{{platforms}}]  →  {{registries}}"
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
    echo "✅ pushed  {{image}}:{{tag}}  [{{platforms}}]  →  {{registries}}"

# 🔐 Log in to `registry` (defaults to `{{registry}}`) with a token read from an env var
# (never a CLI arg). Call once per registry when pushing to several with different
# credentials, e.g.:
#   just docker::login myuser REGISTRY_TOKEN docker.io/myuser
#   just docker::login AWS ECR_TOKEN 123456789.dkr.ecr.us-east-1.amazonaws.com
login user token_env_var="REGISTRY_TOKEN" registry=registry:
    #!/usr/bin/env bash
    set -euo pipefail
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

# 🔐 Log in to an ECR registry using your current AWS SSO session (run `aws sso login
# --profile <profile>` yourself first - this won't trigger the interactive browser flow).
# Call once per ECR registry/account, e.g.:
#   just docker::login-ecr 123456789.dkr.ecr.us-east-1.amazonaws.com us-east-1 my-sso-profile
login-ecr registry=registry region=env_var_or_default("AWS_REGION", "us-east-1") profile=env_var_or_default("AWS_PROFILE", ""):
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{registry}}" ]]; then
        echo "❌ REGISTRY is not set" >&2
        exit 1
    fi
    PROFILE_ARGS=()
    if [[ -n "{{profile}}" ]]; then
        PROFILE_ARGS=(--profile "{{profile}}")
    fi
    echo "🔐 login   AWS@{{registry}}  (region {{region}})"
    if ! aws ecr get-login-password --region "{{region}}" "${PROFILE_ARGS[@]}" \
        | docker login "{{registry}}" --username AWS --password-stdin; then
        echo "❌ ECR login failed - is your SSO session still active? Try: aws sso login ${PROFILE_ARGS[*]}" >&2
        exit 1
    fi
    echo "✅ logged in to {{registry}}"

# 🧹 Prune dangling images/containers/build cache
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🧹 clean   dangling images/containers/build cache"
    docker system prune -f
    docker image prune -f
    echo "✅ clean"
