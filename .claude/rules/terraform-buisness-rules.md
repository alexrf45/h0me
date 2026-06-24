---
description: "Rules for evaluating, building and deploying terraform code in this repo"
---

## Terraform Business Rules

- Always fetch live, current docs for Terraform providers before generating config; do not rely on cached/training-data syntax
- Verify the major version pinned in the repo before writing resource blocks
- Terraform is invoked via the 1password CLI. The user will run `terraform plan` and `terraform apply` manually
- Do not utilize the remote-exec provisioner sesource
- Limit hard coding of variable values, utilize default values as much as possible unless it's a sensitive value used for the lab infra
- Utilize s3 remote state backend for infrastructure resources
- Utilize local terraform state backend for scenario resources and lab applications such as a Juice Shop or DVWA
- `terraform.tfvars` and `remote.tfbackend` will be encrypted via SOPs by the user before being commited to the repo
