# Two Ubuntu 24.04 hosts for the Ansible playbooks: one for GitLab, one for the
# GitLab Runner. They sit in the account's default VPC, so this needs no NAT gateway
# or extra networking. Each host has an Elastic IP, so the GitLab URL and the
# Ansible inventory survive a stop and start.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "selected" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

# Latest Canonical Ubuntu 24.04 image; GitLab's packages support 22.04 and 24.04.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "code-keeper-gitlab"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_security_group" "gitlab" {
  name        = "code-keeper-gitlab"
  description = "GitLab web UI, API and Git over SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Admin SSH (Ansible) and Git over SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = distinct(concat(var.admin_cidrs, var.team_cidrs))
  }

  ingress {
    description = "GitLab web UI and API for the team"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = distinct(concat(var.admin_cidrs, var.team_cidrs))
  }

  egress {
    description = "Package downloads and outbound HTTPS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "code-keeper-gitlab"
  }
}

# The runner reaches GitLab on its public address (the clone URL is the external
# URL), so it arrives from the runner's Elastic IP rather than from inside the VPC.
# A separate rule keeps this working when team_cidrs is narrowed.
resource "aws_security_group_rule" "gitlab_from_runner" {
  type              = "ingress"
  description       = "GitLab API and Git over HTTP for the runner"
  security_group_id = aws_security_group.gitlab.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["${aws_eip.runner.public_ip}/32"]
}

resource "aws_security_group" "runner" {
  name        = "code-keeper-gitlab-runner"
  description = "GitLab Runner: admin SSH only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Admin SSH (Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  egress {
    description = "GitLab, Docker Hub, AWS APIs and package downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "code-keeper-gitlab-runner"
  }
}

resource "aws_instance" "gitlab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.gitlab_instance_type
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.gitlab.id]
  key_name               = aws_key_pair.admin.key_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.gitlab_volume_size
    encrypted   = true
  }

  tags = {
    Name = "code-keeper-gitlab"
  }

  # A newer Ubuntu image must not replace a configured GitLab host.
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "runner" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.runner_instance_type
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.runner.id]
  key_name               = aws_key_pair.admin.key_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.runner_volume_size
    encrypted   = true
  }

  tags = {
    Name = "code-keeper-gitlab-runner"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "gitlab" {
  instance = aws_instance.gitlab.id
  domain   = "vpc"

  tags = {
    Name = "code-keeper-gitlab"
  }
}

resource "aws_eip" "runner" {
  instance = aws_instance.runner.id
  domain   = "vpc"

  tags = {
    Name = "code-keeper-gitlab-runner"
  }
}

# The Ansible inventory for these two hosts, so the playbooks run without editing
# anything by hand. It holds addresses only, no secrets.
resource "local_file" "inventory" {
  filename        = "${path.module}/../inventory/aws.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    gitlab_ip            = aws_eip.gitlab.public_ip
    runner_ip            = aws_eip.runner.public_ip
    ssh_private_key_path = var.ssh_private_key_path
  })
}
