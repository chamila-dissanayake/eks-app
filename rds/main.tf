terraform {
  required_version = ">= 1.14.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.env.region
}

locals {
  role = "rds"

  account_name     = var.env.account_name
  bastion_name     = "${local.account_name}-bastion"
  short_identifier = format("%s-%s", var.tags.environment, local.role)
  date             = formatdate("YYYYMMDD", timestamp())
  dns_prefix       = lower(var.tags.t_environment)
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = [local.account_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }

  tags = {
    Tier = "private"
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_security_group" "bastion_sg" {
  filter {
    name   = "tag:Name"
    values = [local.bastion_name]
  }
}

data "aws_security_group" "data_gateway" {
  count = var.tags.t_environment == "PRD" ? 1 : 0

  filter {
    name   = "tag:Name"
    values = ["${local.account_name}-data-gateway-sg"]
  }
}

data "aws_kms_key" "rds_key" {
  key_id = "alias/${local.short_identifier}"
}

data "aws_route53_zone" "this" {
  name = var.env.domain
}

resource "aws_security_group" "sg_db" {
  name        = local.short_identifier
  vpc_id      = data.aws_vpc.vpc.id
  description = "Security group for ${local.short_identifier}"

  dynamic "ingress" {
    for_each = data.aws_subnet.private
    content {
      protocol    = "tcp"
      from_port   = 5432
      to_port     = 5432
      description = "Allow access to port 5432 from private subnet ${ingress.value.cidr_block}"
      cidr_blocks = [ingress.value.cidr_block]
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [tags]
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-sg", "${local.short_identifier}") }),
  )
}

/*
resource "aws_security_group_rule" "allow_private_5432" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 5432
  to_port           = 5432
  description       = "Allow access on port 5432 from private subnets"
  #cidr_blocks       = data.terraform_remote_state.network.outputs.private_subnets.ipv4_cidr_block
  cidr_blocks = data.aws_subnet.private[*].cidr_block
  security_group_id = aws_security_group.sg_db.id
}*/

resource "aws_security_group_rule" "allow_bastion_5432" {
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  description              = "Allow access to port 5432 from bastion host"
  source_security_group_id = data.aws_security_group.bastion_sg.id
  security_group_id        = aws_security_group.sg_db.id
}

resource "aws_security_group_rule" "allow_all_out" {
  type              = "egress"
  protocol          = -1
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg_db.id
}

resource "aws_security_group_rule" "allow_data_gateway_5432" {
  count = var.tags.t_environment == "PRD" ? 1 : 0

  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  description              = "Allow access to PostgreSQL port 5432 from ${local.account_name}-data-gateway"
  source_security_group_id = data.aws_security_group.data_gateway[0].id
  security_group_id        = aws_security_group.sg_db.id
}

resource "aws_security_group_rule" "data_gateway_443" {
  count = var.tags.t_environment == "PRD" ? 1 : 0

  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 443
  to_port                  = 443
  description              = "Allow access to PostgreSQL port 443 from ${local.account_name}-data-gateway"
  source_security_group_id = data.aws_security_group.data_gateway[0].id
  security_group_id        = aws_security_group.sg_db.id
}

resource "aws_db_subnet_group" "db_subnet" {
  name        = "${local.short_identifier}-sub-grp"
  description = "Subnet group for ${local.short_identifier}"
  subnet_ids  = data.aws_subnets.private.ids

  lifecycle {
    #create_before_destroy = true
    ignore_changes = [tags]
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-sub-grp", "${local.short_identifier}") }),
  )
}

resource "aws_rds_cluster" "postgres" {
  apply_immediately               = true
  backup_retention_period         = var.rds.backup_retention
  cluster_identifier              = var.rds.cluster_identifier == "" ? "${var.tags.environment}-${local.date}" : var.rds.cluster_identifier
  copy_tags_to_snapshot           = true
  db_cluster_parameter_group_name = var.rds.cluster_param_grp
  db_subnet_group_name            = "${local.short_identifier}-sub-grp"
  deletion_protection             = var.tags.t_environment == "PRD" ? true : false
  depends_on                      = [aws_db_subnet_group.db_subnet]
  engine                          = var.rds.engine
  engine_version                  = var.rds.engine_version
  kms_key_id                      = data.aws_kms_key.rds_key.arn
  master_username                 = var.rds.master_username
  preferred_backup_window         = var.rds.backup_window
  preferred_maintenance_window    = var.rds.maintenance_window
  skip_final_snapshot             = true
  snapshot_identifier             = var.rds.snapshot_identifier
  vpc_security_group_ids          = [aws_security_group.sg_db.id]

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-cluster", "${var.rds.cluster_identifier == "" ? "${var.tags.environment}-${local.date}" : var.rds.cluster_identifier}") }),
  )
}

resource "aws_rds_cluster_instance" "postgres" {
  count = var.rds.instance_count

  apply_immediately            = true
  auto_minor_version_upgrade   = var.rds.auto_minor_version_upgrade
  ca_cert_identifier           = "rds-ca-rsa2048-g1"
  cluster_identifier           = aws_rds_cluster.postgres.id
  copy_tags_to_snapshot        = true
  db_parameter_group_name      = var.rds.db_param_grp
  db_subnet_group_name         = "${local.short_identifier}-sub-grp"
  engine                       = var.rds.engine
  engine_version               = var.rds.engine_version
  identifier                   = "${var.tags.environment}-${count.index}"
  instance_class               = var.rds.instance_class
  performance_insights_enabled = var.env.type == "prd" ? true : false
  publicly_accessible          = false

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-%s", "${var.tags.environment}", "${count.index}") }),
  )
}

resource "aws_route53_record" "reader" {
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = "postgres.ro.${local.dns_prefix}"
  type            = "CNAME"
  ttl             = var.rds.route53_record_ttl
  allow_overwrite = "true"
  records         = [aws_rds_cluster.postgres.reader_endpoint]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "writer" {
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = "postgres.rw.${local.dns_prefix}"
  type            = "CNAME"
  ttl             = var.rds.route53_record_ttl
  allow_overwrite = "true"
  records         = [aws_rds_cluster.postgres.endpoint]

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_sns_topic" "sns_topic" {
  name = var.rds.sns_topic == "" ? "${var.tags.environment}-notifications" : var.rds.sns_topic
}

resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  count               = var.rds.instance_count
  alarm_name          = "${var.tags.environment}-${count.index}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.rds.high_cpu_eval_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = var.rds.high_cpu_period
  statistic           = "Average"
  threshold           = var.rds.high_cpu_threshold
  treat_missing_data  = "missing"
  alarm_description   = "Average CPU utilization of the RDS instance ${var.tags.environment}-${count.index} is more than ${var.rds.high_cpu_threshold}% during last ${(var.rds.high_cpu_period * var.rds.high_cpu_eval_periods) / 60} minutes. Performance may suffer!!!"
  alarm_actions       = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  ok_actions          = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  dimensions = {
    DBInstanceIdentifier = "${var.tags.environment}-${count.index}"
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-${count.index}-high-cpu", aws_rds_cluster.postgres.cluster_identifier) })
  )
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory_too_low" {
  count               = var.rds.instance_count
  alarm_name          = "${var.tags.environment}-${count.index}-low-freeable-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.rds.freeable_memory_eval_periods
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = var.rds.freeable_memory_period
  statistic           = "Average"
  threshold           = var.rds.freeable_memory_threshold
  treat_missing_data  = "missing"
  alarm_description   = "Average database freeable memory of RDS instance ${var.tags.environment}-${count.index} is less than ${var.rds.freeable_memory_threshold / 1024} MB in last ${(var.rds.freeable_memory_period * var.rds.freeable_memory_eval_periods) / 60} minutes. Performance may suffer!!!"
  alarm_actions       = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  ok_actions          = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []

  dimensions = {
    DBInstanceIdentifier = "${var.tags.environment}-${count.index}"
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-${count.index}-low-freeable-memory", aws_rds_cluster.postgres.cluster_identifier) })
  )
}

# EventBridge rule to monitor RDS snapshot creation failures in PRD environment
resource "aws_cloudwatch_event_rule" "rds_snapshot_failure" {
  count       = var.tags.t_environment == "PRD" ? 1 : 0
  name        = "${local.short_identifier}-snapshot-failure"
  description = "Trigger notification when RDS cluster ${aws_rds_cluster.postgres.cluster_identifier} snapshot creation fails"

  event_pattern = jsonencode({
    source      = ["aws.rds"]
    detail-type = ["RDS DB Cluster Snapshot Event"]
    detail = {
      SourceArn       = [aws_rds_cluster.postgres.arn]
      EventCategories = ["failure"]
      Message = [
        "Database cluster snapshot failed",
        "Snapshot creation failed",
        "Snapshot failed"
      ]
    }
  })

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-snapshot-failure", local.short_identifier) })
  )
}

# EventBridge target to send snapshot failure events to SNS
resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.rds_snapshot_failure[0].name
  target_id = "SendToSNS"
  arn       = data.aws_sns_topic.sns_topic.arn

  input_transformer {
    input_paths = {
      time           = "$.time"
      cluster        = "$.detail.SourceArn"
      event_message  = "$.detail.Message"
      event_category = "$.detail.EventCategories"
    }

    input_template = <<EOF
"RDS Snapshot Failure Alert"
"Time: <time>"
"Cluster: <cluster>"
"Event Category: <event_category>"
"Message: <event_message>"
"Environment: ${var.tags.environment}"
"Account: ${data.aws_caller_identity.current.account_id}"
"Action Required: Please investigate the RDS cluster snapshot failure immediately."
EOF
  }
}
