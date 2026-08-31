# docker.just

Build / buildx / push / login recipes shared across repos. The build logic itself is
identical everywhere - only auth, registry, and image name differ per repo, so those
are the only things this module asks the consumer to set.

```just
mod docker 'justfile-modules/docker/docker.just'
```

Recipes run namespaced: `just docker::build`, `just docker::push`, etc.

## Configuration

Read from real process env vars - module variables are resolved via
`env_var_or_default`, which only sees actual OS environment, **not**
`export X := "..."` assignments in the consumer's own justfile (modules don't inherit
those). Set these either in your shell, or in a `.env` file next to the consuming
justfile with `set dotenv-load` at its top. See
[`.env.example.docker`](.env.example.docker).

| Var          | Required | Default                    | Meaning |
|--------------|----------|-----------------------------|---------|
| `IMAGE`      | yes      | `app`                       | image name, e.g. `finchkeep` |
| `REGISTRY`   | for push/login | *(empty)*             | registry host/namespace, e.g. `ghcr.io/cybercinch` |
| `REGISTRIES` | no       | `REGISTRY`                  | comma-separated registries to push to - set this instead of `REGISTRY` to push the same build to several registries in one call |
| `DOCKERFILE` | no       | `Dockerfile`                 | path to Dockerfile |
| `CONTEXT`    | no       | `.`                          | build context dir |
| `PLATFORMS`  | no       | `linux/amd64,linux/arm64`   | buildx target platforms |
| `CODEARTIFACT_URL` | no | *(empty)* | NuGet CodeArtifact v3 source URL; when set, the module passes it as a build arg and provides a BuildKit secret named `ca_token` |
| `CODEARTIFACT_TOKEN` | no | *(empty)* | CodeArtifact token to pass as `ca_token`; if omitted, the module fetches one with `aws codeartifact get-authorization-token` |
| `CODEARTIFACT_DOMAIN` | no | derived | CodeArtifact domain, used only when token auto-fetch is enabled |
| `CODEARTIFACT_DOMAIN_OWNER` | no | derived | AWS account ID owning the CodeArtifact domain |
| `CODEARTIFACT_REGION` | no | `AWS_REGION` or derived | AWS region for CodeArtifact token lookup |
| `EXTRA_BUILD_ARGS` | no | *(empty)* | semicolon-separated extra Docker build args, e.g. `NPM_REGISTRY_URL=https://...;PYPI_INDEX_URL=https://...` |
| `EXTRA_BUILD_SECRETS` | no | *(empty)* | semicolon-separated BuildKit secrets, e.g. `id=npm_token,env=NPM_TOKEN;id=pypi_token,env=PYPI_TOKEN` |

## Recipes

### `build tag dockerfile=dockerfile also_latest="false"`

Single-arch `docker build`, tagged `{IMAGE}:tag` (and also `{IMAGE}:latest` when
`also_latest=true`, tagged in the same layer cache so a versioned release doesn't need
a second build). Passes `APP_VERSION`, `CONTAINER_VERSION`, `APP_BUILD_DATE`, and
`APP_GIT_COMMIT` as build args.

```bash
just docker::build 1.2.0 also_latest=true
```

### `push tag also_latest="true"`

Tags and pushes a locally-built image (from `build`) to every registry in
`REGISTRIES` (falls back to `REGISTRY` if unset). Assumes you've already logged in to
each target registry.

```bash
just docker::push 1.2.0
```

### `buildx-setup`

Creates (or reuses) the `multiarch` buildx builder with QEMU emulation. A dependency of
`buildx-build` and `buildx-push` - you don't normally call it directly.

### `buildx-build tag platform dockerfile=dockerfile`

Multi-arch-capable build loaded locally for a **single** platform (buildx can't
`--load` a multi-arch manifest). Useful for a local test build before pushing for real.

```bash
just docker::buildx-build 1.2.0 linux/amd64
```

### `buildx-push tag dockerfile=dockerfile also_latest="true"`

Builds and pushes a multi-arch image (across `PLATFORMS`) straight to every registry in
`REGISTRIES` in a single `docker buildx build --push` invocation - one build, fanned
out to as many `-t` tags as you have registries. This is the recipe you want for a real
release.

```bash
just docker::buildx-push 1.2.0
```

### `login user token_env_var="REGISTRY_TOKEN" registry=registry`

Logs in to a token-based registry (Docker Hub, GHCR, Harbor, ...) using a token read
from an env var - never a CLI arg, so it never lands in shell history or a process
listing. Call once per registry when pushing to several with different credentials:

```bash
just docker::login myuser REGISTRY_TOKEN docker.io/myuser
just docker::login myghcruser GHCR_TOKEN ghcr.io/cybercinch
```

### `login-ecr registry=<ecr entry in registries, else registry> region=$AWS_REGION profile=$AWS_PROFILE`

Logs in to an ECR registry using your **current AWS SSO session** - runs
`aws ecr get-login-password` and pipes it into `docker login`. This does *not* trigger
the interactive browser SSO flow; run that yourself first:

```bash
aws sso login --profile my-sso-profile
just docker::login-ecr 123456789012.dkr.ecr.us-east-1.amazonaws.com us-east-1 my-sso-profile
```

If called with no `registry` arg, it defaults to whichever entry in `REGISTRIES` looks
like an ECR host (`*.dkr.ecr.*`), falling back to `REGISTRY` if none match - so mixed
Docker Hub + ECR setups don't need `REGISTRY` itself to point at ECR.

If the SSO session has expired, the recipe fails with a reminder to re-run
`aws sso login`, rather than hanging on a browser prompt.

### `clean`

Prunes dangling images, stopped containers, and build cache (`docker system prune -f`
+ `docker image prune -f`).

## Multi-registry workflow (e.g. Docker Hub + ECR)

```bash
# .env
IMAGE=myapp
REGISTRIES=docker.io/myuser,123456789012.dkr.ecr.us-east-1.amazonaws.com
```

```bash
aws sso login --profile my-sso-profile
just docker::login myuser REGISTRY_TOKEN docker.io/myuser
just docker::login-ecr 123456789012.dkr.ecr.us-east-1.amazonaws.com us-east-1 my-sso-profile
just docker::buildx-push $(just version::version)
```

`buildx-push` builds once and pushes the same multi-arch manifest to both registries.
Single-registry repos can ignore `REGISTRIES` entirely and just set `REGISTRY` - every
recipe above falls back to it transparently.

## Build-Time Package Registry Auth

Use BuildKit secrets for package manager tokens needed during `docker build`. Tokens
should not be passed as Docker build args because build args can appear in build
metadata/history. URLs and usernames are generally fine as build args; passwords and
tokens should be secrets.

Dockerfiles that consume secrets need the BuildKit syntax directive:

```dockerfile
# syntax=docker/dockerfile:1
```

### AWS CodeArtifact for NuGet

The module has first-class support for NuGet feeds hosted in AWS CodeArtifact.

```bash
# .env or CI variables
CODEARTIFACT_URL=https://tuatahi-853650514837.d.codeartifact.ap-southeast-2.amazonaws.com/nuget/nuget/v3/index.json
AWS_REGION=ap-southeast-2
AWS_PROFILE=devops
```

If `CODEARTIFACT_TOKEN` is not set, the module derives the CodeArtifact domain,
domain owner, and region from the URL and runs:

```bash
aws codeartifact get-authorization-token \
  --domain <domain> \
  --domain-owner <account-id> \
  --region <region> \
  --query authorizationToken \
  --output text
```

The token is exported only inside the recipe process and passed to Docker as:

```bash
--secret id=ca_token,env=CODEARTIFACT_TOKEN
```

Example Dockerfile restore:

```dockerfile
ARG CODEARTIFACT_URL

COPY nuget.config .

RUN --mount=type=secret,id=ca_token \
    export CODEARTIFACT_TOKEN="$(cat /run/secrets/ca_token)" && \
    dotnet restore src/MyApp/MyApp.csproj --configfile nuget.config
```

Example `nuget.config`:

```xml
<configuration>
  <packageSources>
    <add key="CodeArtifact" value="%CODEARTIFACT_URL%" protocolVersion="3" />
  </packageSources>
  <packageSourceCredentials>
    <CodeArtifact>
      <add key="Username" value="aws" />
      <add key="ClearTextPassword" value="%CODEARTIFACT_TOKEN%" />
    </CodeArtifact>
  </packageSourceCredentials>
</configuration>
```

For Bitbucket Pipelines with OIDC, set `AWS_ROLE_ARN` and write the OIDC token to
`AWS_WEB_IDENTITY_TOKEN_FILE` before invoking `just docker::buildx-push`. The AWS CLI
then obtains credentials from OIDC, and the module obtains the short-lived
CodeArtifact token.

### Generic NuGet Feeds

For non-CodeArtifact NuGet feeds such as Gitea, pass URL/username as build args and
the token as a secret.

```bash
# .env or CI variables
NUGET_SOURCE_URL=https://gitea.example.com/api/packages/my-org/nuget/index.json
NUGET_SOURCE_USERNAME=my-user
NUGET_SOURCE_TOKEN=...
EXTRA_BUILD_ARGS=NUGET_SOURCE_URL=https://gitea.example.com/api/packages/my-org/nuget/index.json;NUGET_SOURCE_USERNAME=my-user
EXTRA_BUILD_SECRETS=id=nuget_token,env=NUGET_SOURCE_TOKEN
```

Example Dockerfile:

```dockerfile
ARG NUGET_SOURCE_URL
ARG NUGET_SOURCE_USERNAME

RUN --mount=type=secret,id=nuget_token \
    dotnet nuget add source "$NUGET_SOURCE_URL" \
      --name private \
      --username "$NUGET_SOURCE_USERNAME" \
      --password "$(cat /run/secrets/nuget_token)" \
      --store-password-in-clear-text && \
    dotnet restore src/MyApp/MyApp.csproj
```

### npm

Use a registry URL build arg and pass the npm token as a BuildKit secret.

```bash
# .env or CI variables
NPM_REGISTRY_URL=https://gitea.example.com/api/packages/my-org/npm/
NPM_TOKEN=...
EXTRA_BUILD_ARGS=NPM_REGISTRY_URL=https://gitea.example.com/api/packages/my-org/npm/
EXTRA_BUILD_SECRETS=id=npm_token,env=NPM_TOKEN
```

Example Dockerfile:

```dockerfile
ARG NPM_REGISTRY_URL

RUN --mount=type=secret,id=npm_token \
    npm config set registry "$NPM_REGISTRY_URL" && \
    npm config set "$(printf '%s' "$NPM_REGISTRY_URL" | sed 's#^https\?:##'):_authToken" "$(cat /run/secrets/npm_token)" && \
    npm ci
```

For scoped packages, configure the scoped registry in the Dockerfile instead:

```dockerfile
ARG NPM_REGISTRY_URL

RUN --mount=type=secret,id=npm_token \
    npm config set @my-org:registry "$NPM_REGISTRY_URL" && \
    npm config set "$(printf '%s' "$NPM_REGISTRY_URL" | sed 's#^https\?:##'):_authToken" "$(cat /run/secrets/npm_token)" && \
    npm ci
```

### PyPI / pip

For pip, prefer writing a temporary config file during the same `RUN` layer and
removing it before the layer completes.

```bash
# .env or CI variables
PYPI_INDEX_URL=https://pypi.example.com/simple/
PYPI_TOKEN=...
EXTRA_BUILD_ARGS=PYPI_INDEX_URL=https://pypi.example.com/simple/
EXTRA_BUILD_SECRETS=id=pypi_token,env=PYPI_TOKEN
```

Example Dockerfile:

```dockerfile
ARG PYPI_INDEX_URL

RUN --mount=type=secret,id=pypi_token \
    mkdir -p /root/.config/pip && \
    printf '[global]\nindex-url = %s\nextra-index-url = https://__token__:%s@pypi.org/simple\n' "$PYPI_INDEX_URL" "$(cat /run/secrets/pypi_token)" > /root/.config/pip/pip.conf && \
    pip install --no-cache-dir -r requirements.txt && \
    rm -f /root/.config/pip/pip.conf
```

Adjust the URL/auth format for the package host you are using. Some registries put the
token in the username position; others use basic auth.

### Composer

Composer credentials can be supplied through `COMPOSER_AUTH` as a BuildKit secret.

```bash
# .env or CI variables
COMPOSER_AUTH={"http-basic":{"composer.example.com":{"username":"my-user","password":"my-token"}}}
EXTRA_BUILD_SECRETS=id=composer_auth,env=COMPOSER_AUTH
```

Example Dockerfile:

```dockerfile
RUN --mount=type=secret,id=composer_auth \
    export COMPOSER_AUTH="$(cat /run/secrets/composer_auth)" && \
    composer install --no-interaction --prefer-dist --no-progress
```

### Fully Generic Build Args and Secrets

For package managers not covered above, use the generic pass-through variables:

```bash
EXTRA_BUILD_ARGS=FOO_URL=https://example.com;FOO_USERNAME=build-user
EXTRA_BUILD_SECRETS=id=foo_token,env=FOO_TOKEN;id=bar_key,env=BAR_KEY
```

The module emits:

```bash
--build-arg FOO_URL=https://example.com
--build-arg FOO_USERNAME=build-user
--secret id=foo_token,env=FOO_TOKEN
--secret id=bar_key,env=BAR_KEY
```

The consuming Dockerfile owns the package-manager-specific authentication commands.
