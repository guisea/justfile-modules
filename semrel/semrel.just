# go-semantic-release (https://github.com/go-semantic-release) config scaffolding.
# Distinct from version.just - that one *resolves* a version locally; this one
# generates the `.release.yml` that the CI-run go-semantic-release binary reads to
# decide branches/channels and where to publish the release itself.
# Import with: mod semrel 'justfile-modules/semrel.just'
#
# Provider support mirrors the binary's own releaser plugins: gitea, github, gitlab,
# and a host-agnostic `git` mode that only tags (no hosted release object) - the
# fallback for anything without a plugin, e.g. Bitbucket.
#
# owner/repo/host default to whatever `git remote get-url origin` resolves to, so
# most of the time you can just run e.g. `just semrel::scaffold-gitea` with no args.

_remote_host := `git remote get-url origin 2>/dev/null | sed -E -e 's#^[a-z]+://([^@]+@)?##' -e 's#^git@##' -e 's#:#/#' -e 's#\.git$##' | cut -d/ -f1`
_remote_owner := `git remote get-url origin 2>/dev/null | sed -E -e 's#^[a-z]+://([^@]+@)?##' -e 's#^git@##' -e 's#:#/#' -e 's#\.git$##' | cut -d/ -f2`
_remote_repo := `git remote get-url origin 2>/dev/null | sed -E -e 's#^[a-z]+://([^@]+@)?##' -e 's#^git@##' -e 's#:#/#' -e 's#\.git$##' | cut -d/ -f3`

# 🔎 Print what would be auto-detected from `origin` for the other recipes' defaults
detect:
    @echo "host:  {{ _remote_host }}"
    @echo "owner: {{ _remote_owner }}"
    @echo "repo:  {{ _remote_repo }}"

# 🧾 Scaffold .release.yml for a Gitea-hosted repo
scaffold-gitea owner=_remote_owner repo=_remote_repo host=("https://" + _remote_host) main_branch="main" beta_branch="develop":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f .release.yml ]]; then
        echo "⚠️  .release.yml already exists - not overwriting" >&2
        exit 1
    fi
    cat > .release.yml <<EOF
    release: gitea
    commitFormat: angular
    branch:
      {{main_branch}}: release
      {{beta_branch}}: beta
    gitea:
      repo: "{{repo}}"
      user: "{{owner}}"
      url: "{{host}}"
    changelog:
      showAuthors: true
    hooks:
      preRelease: []
      postRelease: []
    EOF
    echo "🧾 wrote  .release.yml  (gitea: {{owner}}/{{repo}} @ {{host}})"

# 🧾 Scaffold .release.yml for a GitHub-hosted repo (custom_url for GitHub Enterprise)
scaffold-github owner=_remote_owner repo=_remote_repo custom_url="" main_branch="main" beta_branch="develop":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f .release.yml ]]; then
        echo "⚠️  .release.yml already exists - not overwriting" >&2
        exit 1
    fi
    cat > .release.yml <<EOF
    release: github
    commitFormat: angular
    branch:
      {{main_branch}}: release
      {{beta_branch}}: beta
    github:
      repo: "{{repo}}"
      user: "{{owner}}"
    {{ if custom_url != '' { '  customUrl: "' + custom_url + '"' } else { '' } }}
    changelog:
      showAuthors: true
    hooks:
      preRelease: []
      postRelease: []
    EOF
    echo "🧾 wrote  .release.yml  (github: {{owner}}/{{repo}})"

# 🧾 Scaffold .release.yml for a GitLab-hosted repo (custom_url for self-hosted GitLab)
scaffold-gitlab owner=_remote_owner repo=_remote_repo custom_url="" main_branch="main" beta_branch="develop":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f .release.yml ]]; then
        echo "⚠️  .release.yml already exists - not overwriting" >&2
        exit 1
    fi
    cat > .release.yml <<EOF
    release: gitlab
    commitFormat: angular
    branch:
      {{main_branch}}: release
      {{beta_branch}}: beta
    gitlab:
      repo: "{{owner}}/{{repo}}"
    {{ if custom_url != '' { '  customUrl: "' + custom_url + '"' } else { '' } }}
    changelog:
      showAuthors: true
    hooks:
      preRelease: []
      postRelease: []
    EOF
    echo "🧾 wrote  .release.yml  (gitlab: {{owner}}/{{repo}})"

# 🧾 Scaffold .release.yml in plain-git mode - tags only, no hosted release object.
# The fallback for any host without a releaser plugin (Bitbucket, self-hosted, etc).
scaffold-git email user=_remote_owner ssh="true" main_branch="main" beta_branch="develop":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f .release.yml ]]; then
        echo "⚠️  .release.yml already exists - not overwriting" >&2
        exit 1
    fi
    cat > .release.yml <<EOF
    release: git
    commitFormat: angular
    branch:
      {{main_branch}}: release
      {{beta_branch}}: beta
    git:
      email: "{{email}}"
      user: "{{user}}"
      ssh: {{ssh}}
    changelog:
      showAuthors: true
    hooks:
      preRelease: []
      postRelease: []
    EOF
    AUTH_KIND="https"
    if [[ "{{ssh}}" == "true" ]]; then
        AUTH_KIND="ssh"
    fi
    echo "🧾 wrote  .release.yml  (git-only: tags via $AUTH_KIND)"

# 🔍 Show the next version go-semantic-release would compute, without publishing
# anything. Requires the go-semantic-release binary on PATH - install it separately,
# this module only scaffolds config, it doesn't vendor the tool.
dry-run:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v go-semantic-release >/dev/null 2>&1; then
        echo "❌ go-semantic-release is not on PATH - see https://github.com/go-semantic-release/semantic-release#installation" >&2
        exit 1
    fi
    go-semantic-release --dry --allow-initial-development-versions
