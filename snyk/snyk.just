# Run Snyk dependency and code scans, writing reports for triage.

snyk_report_dir := env_var_or_default("SNYK_REPORT_DIR", ".snyk-reports")
snyk_args := env_var_or_default("SNYK_ADDITIONAL_ARGS", "")

full:
    @mkdir -p {{ snyk_report_dir }}
    @set +e; \
      snyk test --all-projects {{ snyk_args }} 2>&1 | tee {{ snyk_report_dir }}/dependency.txt; \
      dependency_status=${PIPESTATUS[0]}; \
      snyk code test {{ snyk_args }} 2>&1 | tee {{ snyk_report_dir }}/code.txt; \
      code_status=${PIPESTATUS[0]}; \
      { \
        echo "# Snyk report"; \
        echo; \
        echo "Generated: $(date -Iseconds)"; \
        echo "Dependency scan exit code: ${dependency_status}"; \
        echo "Code scan exit code: ${code_status}"; \
        echo; \
        echo "## Dependency scan"; \
        cat {{ snyk_report_dir }}/dependency.txt; \
        echo; \
        echo "## Code scan"; \
        cat {{ snyk_report_dir }}/code.txt; \
      } > {{ snyk_report_dir }}/combined.txt; \
      echo "Snyk reports written to {{ snyk_report_dir }}/"; \
      echo "Combined report: {{ snyk_report_dir }}/combined.txt"

# Run only the Snyk dependency scan.
deps:
    @mkdir -p {{ snyk_report_dir }}
    @set +e; \
      snyk test --all-projects {{ snyk_args }} 2>&1 | tee {{ snyk_report_dir }}/dependency.txt; \
      status=${PIPESTATUS[0]}; \
      echo "Snyk dependency report: {{ snyk_report_dir }}/dependency.txt"; \
      exit ${status}

# Run only the Snyk code scan.
code:
    @mkdir -p {{ snyk_report_dir }}
    @set +e; \
      snyk code test {{ snyk_args }} 2>&1 | tee {{ snyk_report_dir }}/code.txt; \
      status=${PIPESTATUS[0]}; \
      echo "Snyk code report: {{ snyk_report_dir }}/code.txt"; \
      exit ${status}