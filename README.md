# oracle_cdb_deployment

Silent-mode Oracle CDB deployment using a three-engine workflow architecture.
Fully idempotent. Plug-and-play extensible via config files only.

---

## Architecture

```
playbooks/deploy_database.yml
  └── orchestrator              Resolves workflow_id → step list; inits dashboard
        └── gate_engine         Iterates steps; enforces prereqs; dispatches
              ├── generic_gate          gate_* steps (read-only assertions)
              │     └── validation/*    Atomic checks; block/rescue; _val_status contract
              └── phase_engine          phase_* steps (system changes)
                    └── phases/*        Loops workers; collects failures
                          └── workers/* Atomic changes; idempotency guard; _worker_status contract
```

### Three engines, zero side-effects in gates

| Role | Changes system? | Notes |
|------|----------------|-------|
| orchestrator | No | Resolves workflow, inits dashboard |
| gate_engine | No | Iterates steps, enforces prereq chain |
| generic_gate | No | Resolves gate config from group_vars dict |
| phase_engine | No | Thin delegator to phases/* |
| validations/* | No | Assert only; always set _val_status |
| workers/* | **Yes** | Idempotency guard first; always set _worker_status |

---

## Workflows

Defined in `group_vars/all/workflow_map.yml`.

| ID | Name | Steps |
|----|------|-------|
| 1 | Oracle CDB Deployment | gate_input_validation → gate_environment_validation → gate_network_validation → phase_db_creation |

### phase_db_creation workers (in order)

1. `worker_configure_listener` — creates Grid or standalone listener (skipped if already running)
2. `worker_generate_dbca_rsp` — renders DBCA response file (mode 0600, oracle-owned)
3. `worker_execute_dbca` — runs DBCA silently (skipped if pmon already running); deletes response file in `always:`
4. `worker_post_db_validation` — checks pmon, V$INSTANCE STATUS=OPEN, oratab entry

---

## Idempotency

Every worker checks current state before acting:

| Worker | Guard |
|--------|-------|
| worker_configure_listener | Skipped if `listener_creation_required=false` (set by gate) |
| worker_execute_dbca | Skipped if `ora_pmon_<SID>` already running |
| worker_post_db_validation | Read-only — safe to re-run always |

Re-running the full playbook against a host where the DB already exists will skip all workers cleanly and validate the running state.

---

## Plug-and-play extension

### Add a new validation
1. Create `roles/validations/my_check/tasks/main.yml` (copy template)
2. Create `roles/validations/my_check/tasks/run.yml` (your logic + block/rescue)
3. Add entry to the relevant gate in `group_vars/all/gate_configs.yml`

No engine changes required.

### Add a new gate
1. Add entry to `gate_configs` dict in `group_vars/all/gate_configs.yml`
2. Add gate name to `steps:` in `group_vars/all/workflow_map.yml`

No engine changes required.

### Add a new worker
1. Create `roles/workers/my_worker/tasks/main.yml` (copy template)
2. Create `roles/workers/my_worker/tasks/run.yml` (idempotency guard + logic)
3. Add entry to phase vars in `roles/phases/phase_db_creation/vars/main.yml`

No engine changes required.

### Add a new workflow
Add a new entry to `workflow_map` in `group_vars/all/workflow_map.yml`:
```yaml
- id: 2
  name: "PDB Only"
  description: "Create a PDB in an existing CDB."
  steps:
    - gate_input_validation
    - gate_environment_validation
    - phase_pdb_creation
```
No playbook changes required.

---

## Quick start

```bash
# 1. Set credentials
ansible-vault edit group_vars/all/vault.yml

# 2. Run workflow 1
ansible-playbook playbooks/deploy_database.yml \
  -e "workflow_id=1" \
  --vault-password-file ~/.vault_pass

# 3. Re-run safely — idempotent
ansible-playbook playbooks/deploy_database.yml \
  -e "workflow_id=1" \
  --vault-password-file ~/.vault_pass
```

---

## Key variable reference

| Variable | Source | Description |
|----------|--------|-------------|
| `workflow_id` | `-e` at runtime | Workflow to execute |
| `oracle_sid` | inventory | Target SID (max 8 chars) |
| `oracle_home` | inventory | Absolute path to ORACLE_HOME |
| `db_name` | inventory | Database name (gdbName) |
| `data_mount` | inventory | Datafile mount point |
| `listener_port` | inventory / common | Listener TCP port (default 1521) |
| `grid_home_base` | common.yml | GI home path for auto-detection |
| `dbca_rsp_path` | common.yml | Derived from oracle_base + oracle_sid |
| `oracle_sys_password` | vault | SYS password |
| `oracle_system_password` | vault | SYSTEM password |
| `oracle_pdb_password` | vault | PDB admin password |
| `grid_configured_true` | runtime (validate_grid_home) | true when Grid detected |
| `listener_creation_required` | runtime (validate_*_listener) | true when listener must be created |
| `listener_source` | runtime (validate_*_listener) | GRID or DB_HOME |

---

## Security notes

- `group_vars/all/vault.yml` must be encrypted before committing
- DBCA response file is written to `{{ dbca_rsp_path }}` (mode 0600, oracle-owned)
- Response file is **always** deleted in `worker_execute_dbca`'s `always:` block, even on failure
- Templates live inside their owning roles, not at the project root
