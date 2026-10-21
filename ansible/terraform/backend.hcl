# Partial backend configuration for the GitLab hosts' state, in the same bucket as the
# application environments under its own key. Pass the bucket, region and lock table
# on the command line:
#   terraform init -backend-config=backend.hcl -backend-config="bucket=<state bucket>" \
#     -backend-config="region=us-east-1" -backend-config="dynamodb_table=code-keeper-tf-locks"
key     = "code-keeper/gitlab/terraform.tfstate"
encrypt = true
