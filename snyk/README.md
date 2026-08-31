# snyk.just

Dependency and code vulnerability scanning recipes using [Snyk](https://snyk.io/). Generates
separate reports for dependency and code scans, plus a combined report for easy triage.

```just
mod snyk 'justfile-modules/snyk/snyk.just'
```

Recipes run namespaced: `just snyk::full`, `just snyk::deps`, `just snyk::code`.

## Prerequisites

Install the Snyk CLI:

```bash
npm install -g snyk
# or
brew install snyk
```

Authenticate with Snyk:

```bash
snyk auth
```

This creates a `.snyk` config file in your home directory with your auth token.

## Configuration

Read from real process env vars - module variables are resolved via
`env_var_or_default`, which only sees actual OS environment, **not**
`export X := "..."` assignments in the consumer's own justfile (modules don't inherit
those). Set these either in your shell, or in a `.env` file next to the consuming
justfile with `set dotenv-load` at its top. See
[`.env.example.snyk`](.env.example.snyk).

| Var                 | Required | Default                    | Meaning |
|---------------------|----------|----------------------------|---------|
| `SNYK_TOKEN`        | no*      | *(from `snyk auth`)*       | Snyk API token; only needed if not authenticated via `snyk auth` |
| `SNYK_REPORT_DIR`   | no       | `.snyk-reports`            | directory to write report files to |
| `SNYK_ADDITIONAL_ARGS` | no    | *(empty)*                  | additional command-line arguments passed to `snyk test` and `snyk code test` |

\* Required only if you haven't run `snyk auth` to set up persistent authentication.

## Recipes

### `full`

Runs both dependency and code vulnerability scans. Creates three report files in
`SNYK_REPORT_DIR`:
- `dependency.txt` - output from `snyk test --all-projects`
- `code.txt` - output from `snyk code test`
- `combined.txt` - merged report with headers, timestamps, and exit codes

Exit codes from both scans are captured and included in the combined report, but
the recipe always exits 0 (to allow CI to continue and collect the reports). Check
the combined report or individual files for actual scan results.

```bash
just snyk::full
cat .snyk-reports/combined.txt
```

### `deps`

Runs only the Snyk dependency vulnerability scan (`snyk test --all-projects`).
Writes output to `SNYK_REPORT_DIR/dependency.txt` and exits with the scan's actual
exit code (0 = no vulnerabilities found, >0 = vulnerabilities found).

```bash
just snyk::deps
```

### `code`

Runs only the Snyk code vulnerability scan (`snyk code test`). Writes output to
`SNYK_REPORT_DIR/code.txt` and exits with the scan's actual exit code (0 = no issues
found, >0 = issues found).

```bash
just snyk::code
```

## CI Integration

Typical CI workflow - run full scan, capture reports, and always collect artifacts
even if vulnerabilities are found:

```bash
just snyk::full || true
# artifacts collection step would grab .snyk-reports/
```

Or use individual scans with stricter failure handling:

```bash
just snyk::deps     # fails if vulns found
just snyk::code     # fails if issues found
```

## Report Format

The combined report (from `full`) looks like:

```
# Snyk report

Generated: 2024-01-15T10:30:45+00:00
Dependency scan exit code: 0
Code scan exit code: 1

## Dependency scan
[snyk test output here]

## Code scan
[snyk code test output here]
```
