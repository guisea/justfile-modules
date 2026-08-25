# justfile-modules

Reusable [`just`](https://github.com/casey/just) recipe modules, shared across
cybercinch/guise repos as a git submodule + `just`'s native `mod` import. The goal:
build/push/version logic lives here once; each repo's own justfile only supplies the
bits that actually differ - image name, registry, auth.

## Usage

Add as a submodule at `justfile-modules/` in your repo root:

```bash
git submodule add https://hub.cybercinch.nz/cybercinch/justfile-modules.git justfile-modules
```

In your root `justfile`, set the per-repo config and import the modules you need:

```just
export IMAGE := "finchkeep"
export REGISTRY := "hub.cybercinch.nz/cybercinch"
export DOCKERFILE := "Dockerfile"

mod docker 'justfile-modules/docker.just'
mod version 'justfile-modules/version.just'
```

Recipes are then namespaced under the module name:

```bash
just version::version              # -> next semver
just docker::build $(just version::version) also_latest=true
just docker::login myuser
just docker::push $(just version::version)
```

Wrap the ones you use often in thin recipes of your own if the full `module::recipe
arg` form is more typing than you want day-to-day - that's normal `just` composition,
not something this repo needs to know about.

## Modules

- **`docker.just`** - build / buildx / push / login / clean. Parameterized by `IMAGE`,
  `REGISTRY`, `DOCKERFILE`, `CONTEXT`, `PLATFORMS` (all env vars) so the build logic
  itself never changes between repos - only auth, registry, and image name do. See the
  header comment in the file for the full list.
- **`version.just`** - semantic-release-aware version resolution
  (`semantic-release` → exact git tag → short commit hash → dev-timestamp fallback),
  shared by every repo that tags images by version.
- **`semrel.just`** - scaffolds `.release.yml` for
  [go-semantic-release](https://github.com/go-semantic-release/semantic-release), the
  tool that actually cuts releases in CI (via `go-semantic-release/action@v1`). One
  recipe per provider - `scaffold-gitea`, `scaffold-github`, `scaffold-gitlab`,
  `scaffold-git` (tag-only, no hosted release object - the fallback for anything
  without a plugin, e.g. Bitbucket). Owner/repo/host default to whatever `git remote
  get-url origin` resolves to, so most repos just need e.g.
  `just semrel::scaffold-gitea` with no args. Refuses to overwrite an existing
  `.release.yml`. Distinct from `version.just`: that one resolves a version for local
  use (build tags, etc); this one configures the tool that publishes the release
  itself.

  ```bash
  just semrel::detect                          # see what would be auto-detected
  just semrel::scaffold-gitea                  # gitea, using origin's owner/repo/host
  just semrel::scaffold-github myorg myrepo    # github, explicit owner/repo
  just semrel::scaffold-git me@example.com     # plain git tags - e.g. Bitbucket
  ```

## Updating a consumer repo to a newer module version

```bash
cd justfile-modules
git pull origin main
cd ..
git add justfile-modules
git commit -m "chore: bump justfile-modules :arrow_up:"
```
