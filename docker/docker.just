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
#   CODEARTIFACT_URL          - optional NuGet CodeArtifact package source URL, passed as a build arg
#   CODEARTIFACT_TOKEN        - optional NuGet CodeArtifact auth token, passed as BuildKit secret id=ca_token
#   CODEARTIFACT_DOMAIN       - optional; derived from CODEARTIFACT_URL when omitted
#   CODEARTIFACT_DOMAIN_OWNER - optional; derived from CODEARTIFACT_URL when omitted
#   CODEARTIFACT_REGION       - optional; defaults to AWS_REGION or is derived from CODEARTIFACT_URL
#   EXTRA_BUILD_ARGS          - optional semicolon-separated build args, e.g. "NPM_REGISTRY_URL=https://..."
#   EXTRA_BUILD_SECRETS       - optional semicolon-separated BuildKit secrets, e.g. "id=npm_token,env=NPM_TOKEN"

image := env_var_or_default("IMAGE", "app")
registry := env_var_or_default("REGISTRY", "")
registries := env_var_or_default("REGISTRIES", registry)
# First entry in `registries` that looks like an ECR host, else falls back to `registry` -
# lets `login-ecr` default sensibly when REGISTRIES mixes ECR with other registries (e.g.
# Docker Hub) and REGISTRY itself points elsewhere.
_ecr_registry := shell('printf "%s" "$1" | tr "," "\n" | grep -m1 "\.dkr\.ecr\." || printf "%s" "$2"', registries, registry)
dockerfile := env_var_or_default("DOCKERFILE", "Dockerfile")
context := env_var_or_default("CONTEXT", ".")
platforms := env_var_or_default("PLATFORMS", "linux/amd64,linux/arm64")

_build_date := `date -u +%Y-%m-%dT%H:%M:%SZ`
_git_commit := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

# 🐳 Build local image.
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
    BUILD_FLAGS=(
      --build-arg APP_VERSION="{{tag}}"
      --build-arg CONTAINER_VERSION="{{tag}}"
      --build-arg APP_BUILD_DATE="{{_build_date}}"
      --build-arg APP_GIT_COMMIT="{{_git_commit}}"
    )
    if [[ -n "${CODEARTIFACT_URL:-}" ]]; then
        if [[ -z "${CODEARTIFACT_TOKEN:-}" ]]; then
            CA_DOMAIN="${CODEARTIFACT_DOMAIN:-}"
            CA_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-}"
            CA_REGION="${CODEARTIFACT_REGION:-${AWS_REGION:-}}"
            if [[ "${CODEARTIFACT_URL}" =~ ^https?://([A-Za-z0-9][A-Za-z0-9_-]*)-([0-9]{12})\.d\.codeartifact\.([A-Za-z0-9-]+)\.amazonaws\.com/ ]]; then
                CA_DOMAIN="${CA_DOMAIN:-${BASH_REMATCH[1]}}"
                CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-${BASH_REMATCH[2]}}"
                CA_REGION="${CA_REGION:-${BASH_REMATCH[3]}}"
            fi
            if [[ -z "${CA_DOMAIN}" || -z "${CA_DOMAIN_OWNER}" || -z "${CA_REGION}" ]]; then
                echo "❌ CODEARTIFACT_URL is set but CodeArtifact domain/owner/region could not be determined" >&2
                echo "   Set CODEARTIFACT_DOMAIN, CODEARTIFACT_DOMAIN_OWNER, and CODEARTIFACT_REGION/AWS_REGION." >&2
                exit 1
            fi
            PROFILE_ARGS=()
            if [[ -n "${AWS_PROFILE:-}" ]]; then
                PROFILE_ARGS=(--profile "${AWS_PROFILE}")
            fi
            echo "🔐 codeartifact token  ${CA_DOMAIN}/${CA_DOMAIN_OWNER}  (${CA_REGION})"
            export CODEARTIFACT_TOKEN="$(aws codeartifact get-authorization-token \
              --domain "${CA_DOMAIN}" \
              --domain-owner "${CA_DOMAIN_OWNER}" \
              --region "${CA_REGION}" \
              "${PROFILE_ARGS[@]}" \
              --query authorizationToken \
              --output text)"
        fi
        BUILD_FLAGS+=(
          --build-arg "CODEARTIFACT_URL=${CODEARTIFACT_URL}"
          --secret id=ca_token,env=CODEARTIFACT_TOKEN
        )
    fi
    if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
        IFS=';' read -ra EXTRA_ARGS <<< "${EXTRA_BUILD_ARGS}"
        for ARG in "${EXTRA_ARGS[@]}"; do
            [[ -z "${ARG}" ]] && continue
            BUILD_FLAGS+=(--build-arg "${ARG}")
        done
    fi
    if [[ -n "${EXTRA_BUILD_SECRETS:-}" ]]; then
        IFS=';' read -ra EXTRA_SECRETS <<< "${EXTRA_BUILD_SECRETS}"
        for SECRET in "${EXTRA_SECRETS[@]}"; do
            [[ -z "${SECRET}" ]] && continue
            BUILD_FLAGS+=(--secret "${SECRET}")
        done
    fi
    docker build \
      -f "{{dockerfile}}" \
      "${BUILD_FLAGS[@]}" \
      "${TAGS[@]}" \
      "{{context}}"
    echo "✅ built   {{image}}:{{tag}}"

# 📤 Push local image.
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

# 🏗️ Prepare buildx.
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

# 🐳 Build one platform.
buildx-build tag platform dockerfile=dockerfile: buildx-setup
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🐳 build   {{image}}:{{tag}}  [{{platform}}]  ({{dockerfile}})"
    BUILD_FLAGS=(
      --build-arg APP_VERSION="{{tag}}"
      --build-arg CONTAINER_VERSION="{{tag}}"
      --build-arg APP_BUILD_DATE="{{_build_date}}"
      --build-arg APP_GIT_COMMIT="{{_git_commit}}"
    )
    if [[ -n "${CODEARTIFACT_URL:-}" ]]; then
        if [[ -z "${CODEARTIFACT_TOKEN:-}" ]]; then
            CA_DOMAIN="${CODEARTIFACT_DOMAIN:-}"
            CA_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-}"
            CA_REGION="${CODEARTIFACT_REGION:-${AWS_REGION:-}}"
            if [[ "${CODEARTIFACT_URL}" =~ ^https?://([A-Za-z0-9][A-Za-z0-9_-]*)-([0-9]{12})\.d\.codeartifact\.([A-Za-z0-9-]+)\.amazonaws\.com/ ]]; then
                CA_DOMAIN="${CA_DOMAIN:-${BASH_REMATCH[1]}}"
                CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-${BASH_REMATCH[2]}}"
                CA_REGION="${CA_REGION:-${BASH_REMATCH[3]}}"
            fi
            if [[ -z "${CA_DOMAIN}" || -z "${CA_DOMAIN_OWNER}" || -z "${CA_REGION}" ]]; then
                echo "❌ CODEARTIFACT_URL is set but CodeArtifact domain/owner/region could not be determined" >&2
                echo "   Set CODEARTIFACT_DOMAIN, CODEARTIFACT_DOMAIN_OWNER, and CODEARTIFACT_REGION/AWS_REGION." >&2
                exit 1
            fi
            PROFILE_ARGS=()
            if [[ -n "${AWS_PROFILE:-}" ]]; then
                PROFILE_ARGS=(--profile "${AWS_PROFILE}")
            fi
            echo "🔐 codeartifact token  ${CA_DOMAIN}/${CA_DOMAIN_OWNER}  (${CA_REGION})"
            export CODEARTIFACT_TOKEN="$(aws codeartifact get-authorization-token \
              --domain "${CA_DOMAIN}" \
              --domain-owner "${CA_DOMAIN_OWNER}" \
              --region "${CA_REGION}" \
              "${PROFILE_ARGS[@]}" \
              --query authorizationToken \
              --output text)"
        fi
        BUILD_FLAGS+=(
          --build-arg "CODEARTIFACT_URL=${CODEARTIFACT_URL}"
          --secret id=ca_token,env=CODEARTIFACT_TOKEN
        )
    fi
    if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
        IFS=';' read -ra EXTRA_ARGS <<< "${EXTRA_BUILD_ARGS}"
        for ARG in "${EXTRA_ARGS[@]}"; do
            [[ -z "${ARG}" ]] && continue
            BUILD_FLAGS+=(--build-arg "${ARG}")
        done
    fi
    if [[ -n "${EXTRA_BUILD_SECRETS:-}" ]]; then
        IFS=';' read -ra EXTRA_SECRETS <<< "${EXTRA_BUILD_SECRETS}"
        for SECRET in "${EXTRA_SECRETS[@]}"; do
            [[ -z "${SECRET}" ]] && continue
            BUILD_FLAGS+=(--secret "${SECRET}")
        done
    fi
    docker buildx build \
      --builder multiarch \
      --platform "{{platform}}" \
      -f "{{dockerfile}}" \
      "${BUILD_FLAGS[@]}" \
      -t "{{image}}:{{tag}}" \
      --load \
      "{{context}}"
    echo "✅ built   {{image}}:{{tag}}  [{{platform}}]"

# 🐳📤 Build and push.
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
    BUILD_FLAGS=(
      --build-arg APP_VERSION="{{tag}}"
      --build-arg CONTAINER_VERSION="{{tag}}"
      --build-arg APP_BUILD_DATE="{{_build_date}}"
      --build-arg APP_GIT_COMMIT="{{_git_commit}}"
    )
    if [[ -n "${CODEARTIFACT_URL:-}" ]]; then
        if [[ -z "${CODEARTIFACT_TOKEN:-}" ]]; then
            CA_DOMAIN="${CODEARTIFACT_DOMAIN:-}"
            CA_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-}"
            CA_REGION="${CODEARTIFACT_REGION:-${AWS_REGION:-}}"
            if [[ "${CODEARTIFACT_URL}" =~ ^https?://([A-Za-z0-9][A-Za-z0-9_-]*)-([0-9]{12})\.d\.codeartifact\.([A-Za-z0-9-]+)\.amazonaws\.com/ ]]; then
                CA_DOMAIN="${CA_DOMAIN:-${BASH_REMATCH[1]}}"
                CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-${BASH_REMATCH[2]}}"
                CA_REGION="${CA_REGION:-${BASH_REMATCH[3]}}"
            fi
            if [[ -z "${CA_DOMAIN}" || -z "${CA_DOMAIN_OWNER}" || -z "${CA_REGION}" ]]; then
                echo "❌ CODEARTIFACT_URL is set but CodeArtifact domain/owner/region could not be determined" >&2
                echo "   Set CODEARTIFACT_DOMAIN, CODEARTIFACT_DOMAIN_OWNER, and CODEARTIFACT_REGION/AWS_REGION." >&2
                exit 1
            fi
            PROFILE_ARGS=()
            if [[ -n "${AWS_PROFILE:-}" ]]; then
                PROFILE_ARGS=(--profile "${AWS_PROFILE}")
            fi
            echo "🔐 codeartifact token  ${CA_DOMAIN}/${CA_DOMAIN_OWNER}  (${CA_REGION})"
            export CODEARTIFACT_TOKEN="$(aws codeartifact get-authorization-token \
              --domain "${CA_DOMAIN}" \
              --domain-owner "${CA_DOMAIN_OWNER}" \
              --region "${CA_REGION}" \
              "${PROFILE_ARGS[@]}" \
              --query authorizationToken \
              --output text)"
        fi
        BUILD_FLAGS+=(
          --build-arg "CODEARTIFACT_URL=${CODEARTIFACT_URL}"
          --secret id=ca_token,env=CODEARTIFACT_TOKEN
        )
    fi
    if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
        IFS=';' read -ra EXTRA_ARGS <<< "${EXTRA_BUILD_ARGS}"
        for ARG in "${EXTRA_ARGS[@]}"; do
            [[ -z "${ARG}" ]] && continue
            BUILD_FLAGS+=(--build-arg "${ARG}")
        done
    fi
    if [[ -n "${EXTRA_BUILD_SECRETS:-}" ]]; then
        IFS=';' read -ra EXTRA_SECRETS <<< "${EXTRA_BUILD_SECRETS}"
        for SECRET in "${EXTRA_SECRETS[@]}"; do
            [[ -z "${SECRET}" ]] && continue
            BUILD_FLAGS+=(--secret "${SECRET}")
        done
    fi
    echo "🐳📤 build+push  {{image}}:{{tag}}  [{{platforms}}]  →  {{registries}}"
    docker buildx build \
      --builder multiarch \
      --platform "{{platforms}}" \
      -f "{{dockerfile}}" \
      "${BUILD_FLAGS[@]}" \
      "${TAGS[@]}" \
      --push \
      "{{context}}"
    echo "✅ pushed  {{image}}:{{tag}}  [{{platforms}}]  →  {{registries}}"

# 🔐 Registry login.
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

# 🔐 ECR login.
login-ecr registry=_ecr_registry region=env_var_or_default("AWS_REGION", "us-east-1") profile=env_var_or_default("AWS_PROFILE", ""):
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

# 🧹 Prune Docker.
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🧹 clean   dangling images/containers/build cache"
    docker system prune -f
    docker image prune -f
    echo "✅ clean"
