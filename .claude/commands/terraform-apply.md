Apply the Terraform configuration for the dev cluster.

```bash
cd terraform/dev
terraform init -backend-config="remote.tfbackend" -upgrade
terraform plan
```

Show the plan output and ask for confirmation before proceeding with apply. If the user confirms:

```bash
cd terraform/dev
terraform apply --auto-approve
```
