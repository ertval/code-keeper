output "gitlab_url" {
  description = "GitLab external URL (the Ansible inventory uses the same value)"
  value       = "http://${aws_eip.gitlab.public_ip}"
}

output "gitlab_public_ip" {
  value = aws_eip.gitlab.public_ip
}

output "runner_public_ip" {
  value = aws_eip.runner.public_ip
}

output "ssh_gitlab" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.gitlab.public_ip}"
}

output "ssh_runner" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.runner.public_ip}"
}

output "ansible_inventory" {
  description = "Inventory file written for the playbooks"
  value       = abspath(local_file.inventory.filename)
}
