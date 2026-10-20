terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "code-keeper-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = true

  tags = {
    Name        = "code-keeper-${var.environment}-alb"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "gateway" {
  name        = "code-keeper-${var.environment}-gw-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name        = "code-keeper-${var.environment}-gw-tg"
    Environment = var.environment
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "code-keeper-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "code-keeper-${var.environment}-cluster"
    Environment = var.environment
  }
}

# Service Discovery Namespace for internal microservices
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "${var.environment}.local"
  description = "Service discovery DNS namespace for code-keeper ${var.environment}"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "inventory" {
  name = "inventory-app"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# IAM Role for ECS Execution
resource "aws_iam_role" "ecs_execution" {
  name = "code-keeper-${var.environment}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Database and broker passwords reach the containers as ECS `secrets`, which the
# ECS agent resolves when a task starts. They no longer appear in the task
# definitions (Trivy AWS-0036) or in `aws ecs describe-task-definition` output.
# name_prefix keeps a destroy and re-create from colliding with a secret that is
# still inside its recovery window.
locals {
  task_secret_values = {
    "inventory-db-password" = var.inventory_db_password
    "billing-db-password"   = var.billing_db_password
    "rabbitmq-password"     = var.rabbitmq_password
  }
}

resource "aws_secretsmanager_secret" "task" {
  for_each    = toset(["inventory-db-password", "billing-db-password", "rabbitmq-password"])
  name_prefix = "code-keeper-${var.environment}-${each.key}-"
  description = "code-keeper ${var.environment} ${each.key}, read by the ECS tasks at start-up"
}

resource "aws_secretsmanager_secret_version" "task" {
  for_each      = aws_secretsmanager_secret.task
  secret_id     = each.value.id
  secret_string = local.task_secret_values[each.key]
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "code-keeper-${var.environment}-read-task-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [for secret in aws_secretsmanager_secret.task : secret.arn]
      }
    ]
  })
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/code-keeper-${var.environment}/api-gateway"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "inventory" {
  name              = "/ecs/code-keeper-${var.environment}/inventory-app"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "billing" {
  name              = "/ecs/code-keeper-${var.environment}/billing-app"
  retention_in_days = 30
}

# 1. API Gateway Task Definition & Service
resource "aws_ecs_task_definition" "api_gateway" {
  family                   = "code-keeper-${var.environment}-api-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "api-gateway"
      image     = var.api_gateway_image
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ]
      environment = [
        { name = "APP_PORT", value = "3000" },
        { name = "INVENTORY_APP_HOST", value = "inventory-app.${var.environment}.local" },
        { name = "INVENTORY_APP_PORT", value = "8080" },
        { name = "RABBITMQ_HOST", value = var.rabbitmq_host },
        { name = "RABBITMQ_PORT", value = tostring(var.rabbitmq_port) },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" },
        # Without these the clients authenticated as the app's hardcoded dev
        # user, which does not exist on the broker.
        { name = "RABBITMQ_USER", value = var.rabbitmq_username }
      ]
      secrets = [
        { name = "RABBITMQ_PASSWORD", valueFrom = aws_secretsmanager_secret.task["rabbitmq-password"].arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.task,
    aws_iam_role_policy.ecs_execution_secrets,
  ]
}

resource "aws_ecs_service" "api_gateway" {
  name            = "code-keeper-${var.environment}-api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  desired_count   = var.gateway_replicas
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.api_gateway_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "api-gateway"
    container_port   = 3000
  }
  # The CD pipeline owns task definition revisions, so Terraform must not
  # revert a promoted image on the next apply.
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# 2. Inventory App Task Definition & Service
resource "aws_ecs_task_definition" "inventory_app" {
  family                   = "code-keeper-${var.environment}-inventory-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "inventory-app"
      image     = var.inventory_app_image
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      # ECS ignores the Dockerfile HEALTHCHECK, so the same probe is repeated here.
      # Without it the deploy jobs' services-stable wait only proves the task started.
      healthCheck = {
        command     = ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')\" || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 6
        startPeriod = 30
      }
      environment = [
        { name = "APP_PORT", value = "8080" },
        # The app reads INVENTORY_DB_*; POSTGRES_* was never read by anything,
        # so the container fell through to its dev defaults and could not reach
        # RDS. Names below must match srcs/inventory-app/app/__init__.py.
        { name = "INVENTORY_DB_HOST", value = var.inventory_db_host },
        { name = "INVENTORY_DB_PORT", value = "5432" },
        { name = "INVENTORY_DB_NAME", value = var.inventory_db_name },
        { name = "INVENTORY_DB_USER", value = var.inventory_db_username }
      ]
      secrets = [
        { name = "INVENTORY_DB_PASSWORD", valueFrom = aws_secretsmanager_secret.task["inventory-db-password"].arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.inventory.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.task,
    aws_iam_role_policy.ecs_execution_secrets,
  ]
}

resource "aws_ecs_service" "inventory_app" {
  name            = "code-keeper-${var.environment}-inventory-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.inventory_app.arn
  desired_count   = var.inventory_replicas
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.inventory_app_security_group_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.inventory.arn
  }
  # The CD pipeline owns task definition revisions, so Terraform must not
  # revert a promoted image on the next apply.
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# 3. Billing App Task Definition & Service (Worker)
resource "aws_ecs_task_definition" "billing_app" {
  family                   = "code-keeper-${var.environment}-billing-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "billing-app"
      image     = var.billing_app_image
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      # ECS ignores the Dockerfile HEALTHCHECK, so the same probe is repeated here.
      # Without it the deploy jobs' services-stable wait only proves the task started.
      healthCheck = {
        command     = ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')\" || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 6
        startPeriod = 30
      }
      environment = [
        { name = "APP_PORT", value = "8080" },
        # Matches srcs/billing-app/app/__init__.py, which reads BILLING_DB_*.
        { name = "BILLING_DB_HOST", value = var.billing_db_host },
        { name = "BILLING_DB_PORT", value = "5432" },
        { name = "BILLING_DB_NAME", value = var.billing_db_name },
        { name = "BILLING_DB_USER", value = var.billing_db_username },
        { name = "RABBITMQ_HOST", value = var.rabbitmq_host },
        { name = "RABBITMQ_PORT", value = tostring(var.rabbitmq_port) },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" },
        # Without these the clients authenticated as the app's hardcoded dev
        # user, which does not exist on the broker.
        { name = "RABBITMQ_USER", value = var.rabbitmq_username }
      ]
      secrets = [
        { name = "BILLING_DB_PASSWORD", valueFrom = aws_secretsmanager_secret.task["billing-db-password"].arn },
        { name = "RABBITMQ_PASSWORD", valueFrom = aws_secretsmanager_secret.task["rabbitmq-password"].arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.billing.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.task,
    aws_iam_role_policy.ecs_execution_secrets,
  ]
}

resource "aws_ecs_service" "billing_app" {
  name            = "code-keeper-${var.environment}-billing-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.billing_app.arn
  desired_count   = var.billing_replicas
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.billing_app_security_group_id]
    assign_public_ip = false
  }
  # The CD pipeline owns task definition revisions, so Terraform must not
  # revert a promoted image on the next apply.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
