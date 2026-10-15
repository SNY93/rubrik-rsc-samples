# SAP HANA protection with Rubrik Security Cloud (Ansible)

Ansible roles and a playbook that bring SAP HANA systems under Rubrik protection through the
Rubrik Security Cloud (RSC) GraphQL API:

1. **Register the host** with a Rubrik cluster
2. **Add the SAP HANA system** (SID and instance number are discovered on the host with `saphostctrl`)
3. **Assign an SLA Domain**

Every step checks the current state first. Re-running the playbook changes nothing that is already in
place, and `--check` shows what would change without changing it.

> Community sample, provided "as is" without warranty or official support. Test it in a non-production
> environment first.

## Requirements

| Where | What |
|-------|------|
| Control node | `ansible-core` 2.15 or later. Only `ansible.builtin` modules are used, so no collections are needed. |
| RSC | A [service account](https://docs.rubrik.com/en-us/saas/saas/adding_a_service_account.html) with permission to manage hosts, SAP HANA and SLA assignment. Download its JSON credentials file. |
| HANA host | Rubrik Backup Service (RBS) agent installed and running. SSH access with privilege escalation for `saphostctrl`. The host name must resolve from the Rubrik cluster. |
| HANA DB | An `hdbuserstore` key that Rubrik uses to connect to SYSTEMDB, e.g. `hdbuserstore SET BACKUP <host>:3<nr>13@SYSTEMDB <user> <password>` |

## Quick start

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp inventory/hosts.example.yml inventory/hosts.yml   # git-ignored; edit hosts and variables
export RSC_SERVICE_ACCOUNT_FILE=~/.rubrik/rsc-service-account.json

ansible-playbook protect_sap_hana.yml --check   # dry run
ansible-playbook protect_sap_hana.yml
```

Useful options:

```bash
ansible-playbook protect_sap_hana.yml --limit hana01.example.com   # one host
ansible-playbook protect_sap_hana.yml --tags register               # host registration only
ansible-playbook protect_sap_hana.yml -e target_hosts=prod_hana     # another inventory group
```

## Credentials

Credentials are never stored in this repository. The `rubrik_rsc` role looks for them in this order:

1. `rubrik_rsc_service_account_file`: path to the JSON file downloaded from RSC. Defaults to the `RSC_SERVICE_ACCOUNT_FILE` environment variable.
2. `rubrik_rsc_client_id`, `rubrik_rsc_client_secret` and `rubrik_rsc_access_token_uri`. These default to the `RSC_CLIENT_ID`, `RSC_CLIENT_SECRET` and `RSC_ACCESS_TOKEN_URI` environment variables. You can also put them in an Ansible Vault file:

   ```bash
   ansible-vault create inventory/group_vars/all/vault.yml   # git-ignored
   ansible-playbook protect_sap_hana.yml --ask-vault-pass
   ```

Use SSH keys for host access, not `ansible_password` in the inventory.

## Variables

Set these in your inventory per host or per group. The roles' `meta/argument_specs.yml` files document every option.

| Variable | Default | Description |
|----------|---------|-------------|
| `rubrik_rsc_cluster_name` | **required** | Rubrik cluster that protects the host |
| `rubrik_sap_hana_hdbuserstore_key` | **required** | hdbuserstore key Rubrik uses to connect |
| `rubrik_sap_hana_sla_name` | `""` | SLA Domain to assign. If empty, the system is added without an SLA. |
| `rubrik_sap_hana_sid` / `rubrik_sap_hana_instance_number` | discovered | Set these when a host runs more than one HANA system |
| `rubrik_host_register_hostname` | host FQDN | Name the host is registered under in RSC |
| `rubrik_sap_hana_sla_user_note` | `Assigned by Ansible` | Audit note stored with the SLA assignment |
| `rubrik_sap_hana_job_retries` / `_delay` | `40` / `15` | How long to wait for the add-system job (about 10 minutes by default) |
| `rubrik_rsc_validate_certs` | `true` | TLS verification for the RSC API |
| `rubrik_rsc_no_log` | `true` | Hides API traffic. Set to `false` temporarily when debugging. |

## Layout

```
protect_sap_hana.yml          # playbook: auth once -> per host register/add/SLA -> logout
inventory/
  hosts.example.yml           # copy to hosts.yml
  group_vars/all/rubrik.yml   # shared non-secret settings
roles/
  rubrik_rsc/                 # authentication, cluster lookup (resolve_cluster), GraphQL helper, logout
  rubrik_host_register/       # register a Linux host (idempotent)
  rubrik_sap_hana/            # discover, add SAP HANA system, assign SLA (idempotent)
```

### Reusing the roles

The `rubrik_rsc` role can drive other RSC workflows. Authenticate once, then send any query or mutation:

```yaml
- hosts: localhost
  roles:
    - rubrik_rsc
  tasks:
    - name: List SLA Domains
      ansible.builtin.import_role:
        name: rubrik_rsc
        tasks_from: graphql
      vars:
        rubrik_rsc_gql_query: "query { slaDomains { nodes { id name } } }"

    - ansible.builtin.debug:
        var: rubrik_rsc_gql_data.slaDomains.nodes

    - ansible.builtin.import_role:
        name: rubrik_rsc
        tasks_from: logout
```

The helper fails on HTTP and GraphQL errors. Set `rubrik_rsc_gql_mutation: true` for changes so that
they report `changed` and are skipped in check mode.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `CERTIFICATE_VERIFY_FAILED ... unable to get local issuer certificate` on macOS | Python from python.org has no CA bundle. Run `/Applications/Python 3.x/Install Certificates.command` or `export SSL_CERT_FILE=/etc/ssl/cert.pem`. Do not disable `rubrik_rsc_validate_certs`. |
| Host only accepts password login | Install `sshpass` and run with `-k` (`--ask-pass`) |
| Need to see API requests and responses | Add `-e rubrik_rsc_no_log=false` (this prints the bearer token, so don't share the output) |

## Development

```bash
ansible-lint            # production profile
yamllint .
ansible-playbook protect_sap_hana.yml -i inventory/hosts.example.yml --syntax-check
```
