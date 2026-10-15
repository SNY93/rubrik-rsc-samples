# Rubrik Security Cloud (RSC) Community Samples

Community-contributed samples for automating and extending **Rubrik Security Cloud (RSC)** workflows.


---

### Disclaimer

These samples are provided by the community and maintained on a voluntary basis.
**They are not official Rubrik products, and no official support or warranty is provided.** All content is offered "as is". Always review and test samples in a non-production environment before using them for critical work.


### Getting Started

What you need depends on the sample. The README in each sample folder lists the exact requirements.

- **All samples**
  - An RSC [service account] with a role scoped to the task, and its downloaded JSON credentials file.
  - HTTPS (443) access from where the sample runs to your RSC tenant.
- **PowerShell samples**
  - PowerShell 7.2+ (the SQL Server automation scripts also run on Windows PowerShell 5.1).
  - The official [Rubrik Security Cloud PowerShell SDK](https://www.powershellgallery.com/packages/RubrikSecurityCloud/), unless the sample says otherwise: `Install-Module RubrikSecurityCloud`
- **Ansible samples**
  - `ansible-core` 2.15 or later, installed in a Python virtual environment.
- **Python samples**
  - Python 3.11+ in a virtual environment, or the prebuilt Windows executables where the sample provides them.

Never commit service account files, secrets or inventories with real credentials to this repository.

---

### License

This repository is distributed under the **MIT License**.
See the [LICENSE](LICENSE) file for details.
