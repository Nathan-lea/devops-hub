# Repository Guidelines

Contributor guide for the server operations & maintenance system (`devops-hub`). This repository ships documentation, declarative configs, Ansible playbooks, and shell scripts for managing ~100 Linux hosts across public/private clouds.

## Project Structure & Module Organization

```
devops-hub/
├── docs/        # 14 numbered Markdown runbooks (00 overview → 12 methodology) + README
├── configs/     # Declarative configs: rules/, targets/, grafana/, k8s/, wazuh/
├── playbooks/   # Ansible: ansible.cfg, inventory, numbered *.yml, templates/
└── scripts/     # Executable bash scripts (backup, health checks, intrusion detection)
```

Docs are numbered by domain (`00-` overview, `01-` monitoring … `10-` roadmap, `11-` IDS, `12-` methodology). New docs follow the next sequential number and must be registered in `docs/README.md` and the `00-` navigation table.

## Build, Test, and Development Commands

There is no compile step. Validate before committing:

```bash
bash -n scripts/*.sh                    # shell syntax check
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('configs/**/*.y*ml',recursive=True)+glob.glob('playbooks/*.yml')]"
chmod +x scripts/*.sh                   # ensure scripts stay executable
ansible-playbook playbooks/00-init-host.yml --syntax-check   # playbook lint
```

## Coding Style & Naming Conventions

- **YAML**: 2-space indent; one rule-file per domain in `configs/rules/` (`host.yml`, `mysql.yml`, `security.yml`).
- **Shell**: start with `#!/bin/bash`, enable `set -euo pipefail`, header comment block with purpose/inputs/outputs. Use `snake_case`.
- **Playbooks**: numbered prefix matching roadmap phase (`00-` … `04-`); idempotent modules only.
- **Secrets**: never hardcode. Use Ansible Vault; replace placeholder IPs/domains/keys before deploy.

## Testing Guidelines

No unit-test framework. Minimum bar: `bash -n` passes for every script, `yaml.safe_load` passes for every YAML, `--syntax-check` passes for every playbook. Verify cross-references between docs after edits.

## Commit & Pull Request Guidelines

- Conventional commits: `docs: add X`, `config: tune alert rules`, `scripts: fix backup retry`.
- One concern per PR; keep playbook/config/script changes in separate commits.
- PR description must list affected files, validation commands run, and any placeholder values to replace.
- Link the related runbook number when a change touches monitoring/security/backup logic.

## Security & Configuration Tips

All IPs (`10.0.x.x`), domains (`example.com`), and keys (`ChangeMe!`, `ABUSEIPDB_KEY`) are placeholders. Never commit real credentials—use Vault and `.vault_pass`. Security-sensitive scripts (`intrusion_detection.sh`, `network_anomaly_check.sh`) run via cron; review rule thresholds before enabling blocking mode.

## Architecture Overview

See `docs/00-总体架构与方案概览.md` for the layered architecture and `docs/12-方法论与设计原则.md` for the design principles (SRE, defense-in-depth, IaC, progressive delivery) that govern all decisions here.
