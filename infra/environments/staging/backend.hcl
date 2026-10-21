# Partial backend configuration for the staging state. Passed to Terraform with
# `terraform init -backend-config=backend.hcl`; credentials are never stored here,
# they are inherited from the AWS_* environment variables of the caller.
# dynamodb_table provides state locking: the S3 native lock (use_lockfile) needs
# Terraform >= 1.10 and the CI jobs run hashicorp/terraform:1.6.
key            = "code-keeper/staging/terraform.tfstate"
encrypt        = true

# bucket, region and dynamodb_table are deliberately absent. They are supplied by the
# init job as additional -backend-config arguments from the protected CI/CD variables
# TF_STATE_BUCKET, TF_STATE_REGION and TF_STATE_LOCK_TABLE. Declaring them in both
# places makes Terraform abort with `Backend configuration got multiple values for
# parameter "bucket"`, and keeping them here would pin one account's state layout
# into version control.
