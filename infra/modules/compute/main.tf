# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "code-keeper-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

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
        { name = "RABBITMQ_PORT", value = "5672" },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
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
      environment = [
        { name = "APP_PORT", value = "8080" },
        { name = "POSTGRES_HOST", value = var.inventory_db_host },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_DB", value = "movies" }
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
      environment = [
        { name = "APP_PORT", value = "8080" },
        { name = "POSTGRES_HOST", value = var.billing_db_host },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_DB", value = "orders" },
        { name = "RABBITMQ_HOST", value = var.rabbitmq_host },
        { name = "RABBITMQ_PORT", value = "5672" },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
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
}
