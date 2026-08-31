# Maintenance recipes for this repo itself - not part of the shared modules consumers
# import (docker.just / semrel.just / version.just). Requires `tea login` to be set up
# for this Gitea instance.

# 🔁 Trigger an immediate sync of this repo's push mirror(s) via the Gitea API, instead
# of waiting for the periodic interval or relying on the UI's "Sync" button.
mirror-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_PATH="$(git remote get-url origin | sed -E 's#^[a-zA-Z]+://[^/]+/##; s#\.git$##')"
    echo "🔁 sync    push mirror(s) for ${REPO_PATH}"
    tea api --method POST "repos/${REPO_PATH}/push_mirrors-sync"
    tea api --method GET "repos/${REPO_PATH}/push_mirrors"
    echo "✅ sync triggered"
