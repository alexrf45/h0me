Run a Terraform plan for the dev cluster. Initializes with the remote backend first.

```bash
cd terraform/dev
terraform init -backend-config="remote.tfbackend" -upgrade
terraform plan
```

Summarize any planned changes, highlighting additions, modifications, and destructions.
