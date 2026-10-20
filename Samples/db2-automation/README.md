# IBM Db2 protection with Rubrik Security Cloud (Ansible)

Ansible roles and a playbook that bring IBM Db2 instances under Rubrik protection through the
Rubrik Security Cloud (RSC) GraphQL API:

1. **Register the host** with a Rubrik cluster
2. **Add the Db2 instances** (all instances on the host are discovered with `db2ilist`, so a host with
   several instances is handled in one run)
3. **Assign an SLA Domain**

Rubrik discovers the databases of an added instance automatically, so the SLA Domain is assigned to
the instance and applies to its databases.

Every step checks the current state first. Re-running the playbook changes nothing that is already in
place, and `--check` shows what would change without changing it.

> Community sample, provided "as is" without warranty or official support. Test it in a non-production
> environment first.

## Requirements

| Where | What |
|-------|------|
| Control node | `ansible-core` 2.15 or later. Only `ansible.builtin` modules are used, so no collections are needed. |
| RSC | A [service account](https://docs.rubrik.com/en-us/saas/saas/adding_a_service_account.html) with permission to manage hosts, Db2 and SLA assignment. Download its JSON credentials file. |
| Db2 host | Rubrik Backup Service (RBS) agent installed and running (it also deploys the Db2 vendor library). SSH access with privilege escalation for `db2ilist`. The host name must resolve from the Rubrik cluster. |
| Db2 instance | No user or password is needed. |

## Quick start

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp inventory/hosts.example.yml inventory/hosts.yml   # git-ignored; edit hosts and variables
export RSC_SERVICE_ACCOUNT_FILE=~/.rubrik/rsc-service-account.json

ansible-playbook protect_db2.yml --check   # dry run
ansible-playbook protect_db2.yml
```

Useful options:

```bash
ansible-playbook protect_db2.yml --limit db2-01.example.com   # one host
ansible-playbook protect_db2.yml --tags register               # host registration only
ansible-playbook protect_db2.yml -e target_hosts=prod_db2      # another inventory group
```

## Credentials

Credentials are never stored in this repository. The `rubrik_rsc` role looks for RSC credentials in this order:

1. `rubrik_rsc_service_account_file`: path to the JSON file downloaded from RSC. Defaults to the `RSC_SERVICE_ACCOUNT_FILE` environment variable.
2. `rubrik_rsc_client_id`, `rubrik_rsc_client_secret` and `rubrik_rsc_access_token_uri`. These default to the `RSC_CLIENT_ID`, `RSC_CLIENT_SECRET` and `RSC_ACCESS_TOKEN_URI` environment variables. You can also put them in an ansible-vault encrypted `inventory/group_vars/all/vault.yml` (git-ignored); then add `--ask-vault-pass` to the commands above.

Db2 instances are added without a user or password, like the RSC UI does, so no Db2 secret is handled at all.

Use SSH keys for host access, not `ansible_password` in the inventory.

## Variables

Set these in your inventory per host or per group. The roles' `meta/argument_specs.yml` files document every option.

| Variable | Default | Description |
|----------|---------|-------------|
| `rubrik_rsc_cluster_name` | **required** | Rubrik cluster that protects the host |
| `rubrik_db2_sla_name` | `""` | SLA Domain to assign to the instance and to its HADR databases. If empty, the instance is added without an SLA. |
| `rubrik_db2_hadr_expected` | detected | Normally not needed: HADR is detected on the host. Set `true` or `false` only to override the detection. |
| `rubrik_db2_instances` | all on the host | List of instance names to protect, e.g. `[db2inst1]`. Empty protects every instance `db2ilist` reports. |
| `rubrik_db2_ilist` | `/opt/ibm/db2/V11.5/instance/db2ilist` | Path to `db2ilist`. It depends on the installed Db2 version. |
| `rubrik_host_register_hostname` | host FQDN | Name the host is registered under in RSC |
| `rubrik_db2_sla_user_note` | `Assigned by Ansible` | Audit note stored with the SLA assignment |
| `rubrik_db2_job_retries` / `_delay` | `40` / `15` | How long to wait for the instance to appear in RSC after adding it (about 10 minutes by default) |
| `rubrik_rsc_validate_certs` | `true` | TLS verification for the RSC API |
| `rubrik_rsc_no_log` | `true` | Hides API traffic. Set to `false` temporarily when debugging. |

## Credential-less add

Instances are always added without a user or password, as in the RSC UI. The GraphQL schema declares
both fields as required strings and the API rejects empty ones (`username not provided for the Db2
instance`), so the role sends a single space for each, exactly as the RSC UI does. The only per-instance input is the
instance name, which is discovered on the host with `db2ilist` when not set.

## HADR

RSC treats an HADR primary and its standbys as one HADR entity. It discovers the entity
automatically once the primary instance is added, and HADR databases do not inherit the SLA Domain of
their instance. The role therefore assigns `rubrik_db2_sla_name` to the HADR databases of the instance
as well.

The role finds out on the host itself whether HADR is in use, so nothing needs to be configured:

1. After the instance is added, `files/hadr_status.sh` runs on the host as the instance owner. For
   each local database with `HADR_LOCAL_HOST` set it reads the role with `db2pd -db <db> -hadr`.
2. If the host runs an HADR **primary** (or the role cannot be read), the role waits for RSC to
   discover the HADR entity (up to `rubrik_db2_job_retries` x `rubrik_db2_job_delay` seconds) and
   fails if it does not appear.
3. On a **standby**, or when no database uses HADR, it does not wait. Any HADR databases that already
   exist for the instance still get the SLA Domain.

Notes:

- The detection runs `db2` and `db2pd` through privilege escalation as the instance owner, assumed
  to be the user named like the instance (e.g. `db2inst1`), so `ansible_user` needs `become` rights
  for that user. If detection fails, the role prints why and does
  not wait; set `rubrik_db2_hadr_expected: true` to force the wait.
- Whether a standby host must also be registered in RSC is not stated in the docs I found.
- HADR must already be configured in Db2. After a takeover or configuration change, refresh the HADR
  entity in RSC.
- **Not tested on a real Db2 host.** The development tenant has no HADR database, so the script's
  `db2 list db directory`, `db2 get db cfg` and `db2pd` parsing follows the documented output format
  but is unverified. The RSC queries were checked against the live schema only.

## Layout

```
protect_db2.yml               # playbook: auth once -> per host register/add/SLA -> logout
inventory/
  hosts.example.yml           # copy to hosts.yml
  group_vars/all/rubrik.yml   # shared non-secret settings
roles/
  rubrik_rsc/                 # authentication, cluster lookup (resolve_cluster), GraphQL helper, logout
  rubrik_host_register/       # register a Linux host (idempotent)
  rubrik_db2/                 # discover, add Db2 instance, assign SLA (idempotent)
```

`rubrik_rsc` and `rubrik_host_register` are the same roles as in the SAP HANA sample
(`../hana-automation`). Each sample is self-contained, so they are copied and not shared.

### API calls used

| Step | Operation |
|------|-----------|
| Look up instance | `db2Instances` query |
| Add instance | `addDb2Instance` mutation (`hostIds`, `instanceName`, `username` and `password` as a single space each) |
| Assign SLA | `assignSla` mutation |
| Find HADR databases | `db2Databases` query (`DB2_DB_TYPE` HADR / HADR_PURESCALE, `DB2_INSTANCE_ID` = RSC instance id) |

`addDb2Instance` is asynchronous. I found no documented status query for that request, so the role
waits until the instance shows up in the `db2Instances` query instead of polling a job. If the instance
does not appear in time the run fails; check the request in RSC.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `db2ilist` not found | The path contains the Db2 version. Set `rubrik_db2_ilist`, or set `rubrik_db2_instances` to skip discovery. |
| Instance does not appear in RSC | Check that the RBS agent is running on the host, and the request in RSC. |
| `CERTIFICATE_VERIFY_FAILED ... unable to get local issuer certificate` on macOS | Python from python.org has no CA bundle. Run `/Applications/Python 3.x/Install Certificates.command` or `export SSL_CERT_FILE=/etc/ssl/cert.pem`. Do not disable `rubrik_rsc_validate_certs`. |
| Host only accepts password login | Install `sshpass` and run with `-k` (`--ask-pass`) |
| Need to see API requests and responses | Add `-e rubrik_rsc_no_log=false` (this prints the bearer token, so don't share the output) |

## Development

```bash
ansible-lint            # production profile
yamllint .
ansible-playbook protect_db2.yml -i inventory/hosts.example.yml --syntax-check
```
