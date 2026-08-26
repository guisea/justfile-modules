# docker.just

Build / buildx / push / login recipes shared across repos. The build logic itself is
identical everywhere - only auth, registry, and image name differ per repo, so those
are the only things this module asks the consumer to set.

```just
mod docker 'justfile-modules/docker.just'
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

## Recipes

### `build tag dockerfile=dockerfile also_latest="false"`

Single-arch `docker build`, tagged `{IMAGE}:tag` (and also `{IMAGE}:latest` when
`also_latest=true`, tagged in the same layer cache so a versioned release doesn't need
a second build). Passes `APP_VERSION`, `APP_BUILD_DATE`, `APP_GIT_COMMIT` as build args.

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
