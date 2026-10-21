variable "aws_region" {
  description = "AWS region for the GitLab hosts"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone; both hosts use the default VPC's default subnet there"
  type        = string
  default     = "us-east-1a"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH to both hosts (Ansible and administration), for example [\"203.0.113.7/32\"]"
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Set admin_cidrs to your own address(es); SSH must not be open to the internet."
  }
}

variable "team_cidrs" {
  description = "CIDRs allowed to use GitLab over HTTP and Git over SSH. Sign-up is disabled, so only accounts the admin creates can log in."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_public_key_path" {
  description = "Public half of the SSH key pair Ansible uses"
  type        = string
  default     = "~/.ssh/code-keeper.pub"
}

variable "ssh_private_key_path" {
  description = "Private half of the same key pair; only written into the generated Ansible inventory"
  type        = string
  default     = "~/.ssh/code-keeper"
}

variable "gitlab_instance_type" {
  description = "GitLab needs at least 8 GB of memory"
  type        = string
  default     = "t3.large"
}

variable "runner_instance_type" {
  description = "Runner host; the Docker executor runs one job container per concurrent job"
  type        = string
  default     = "t3.medium"
}

variable "gitlab_volume_size" {
  description = "Root volume of the GitLab host, in GB"
  type        = number
  default     = 40
}

variable "runner_volume_size" {
  description = "Root volume of the runner host, in GB (job images are cached here)"
  type        = number
  default     = 40
}
