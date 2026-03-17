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
  role = "redshift"

  short_identifier     = format("%s-%s", var.tags.environment, local.role)
  #subnet_group_name    = var.redshift.create && var.redshift.create_subnet_group ? aws_redshift_subnet_group.reds[0].name : var.subnet_group_name
  #parameter_group_name = var.redshift.create && var.redshift.create_parameter_group ? aws_redshift_parameter_group.reds[0].id : var.redshift.parameter_group_name
  #master_password      = var.redshift.create && var.redshift.create_random_password ? random_password.master_password[0].result : var.master_password
  cluster_identifier   = "${var.tags.Name}-rs"
  database_name        = var.redshift.database_name == "" ? trim(var.tags.environment, "-") : var.redshift.database_name
  dns_prefix           = lower(var.tags.t_environment)
  r53_record_name      = "${local.role}.${local.dns_prefix}"
  bastion_name         = "${var.env.account_name}-bastion"
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "this" {
  name = var.env.domain
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = [var.env.account_name]
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

data "aws_kms_key" "key" {
  key_id = "alias/${local.short_identifier}"
}


resource "random_password" "master_password" {
  count = var.redshift.create && var.create_random_password ? 1 : 0

  length           = var.random_password_length
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

################################################################################
# RedShift Cluster
################################################################################
/*
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "prsn-terraform-state-${var.env.region}-${data.caller_identity.current.account_id}"
    key    = "${var.tags.g_Name}/vpc/terraform.tfstate"
    region = var.env.region
  }
}

data "terraform_remote_state" "bastion" {
  backend = "s3"
  config = {
    bucket = "prsn-terraform-state-${var.env.region}-${data.caller_identity.current.account_id}"
    key    = "${var.tags.g_Name}/bastion/terraform.tfstate"
    region = var.env.region
  }
}*/

resource "aws_security_group" "sg_db" {
  name        = "${local.short_identifier}-sg"
  vpc_id      = data.aws_vpc.vpc.id
  description = "Allow SSH access to redshift instances"

  dynamic "ingress" {
    for_each = data.aws_subnet.private
    content {
      protocol    = "tcp"
      from_port   = 5439
      to_port     = 5439
      description = "Allow access on port 5439 from private subnets"
      cidr_blocks = [ingress.value.cidr_block]
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [tags]
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-sg", local.short_identifier) })
  )
}

/*
resource "aws_security_group_rule" "allow_private_5439" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 5439
  to_port           = 5439
  description       = "Allow access on port 5439 from private subnets"
  cidr_blocks       = data.terraform_remote_state.network.outputs.private_subnets.ipv4_cidr_block
  security_group_id = aws_security_group.sg_db.id
}*/

resource "aws_security_group_rule" "allow_bastion_5439" {
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 5439
  to_port                  = 5439
  description              = "Allow Bastion access port 5439"
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

resource "aws_db_subnet_group" "rs_subnets" {
  name        = "${local.short_identifier}-sub-grp"
  description = "Redshift DB subnet group"
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

resource "aws_redshift_cluster" "reds" {
  count = var.redshift.create ? 1 : 0

  allow_version_upgrade = var.redshift.allow_version_upgrade
  apply_immediately     = var.redshift.apply_immediately
  #aqua_configuration_status            = var.aqua_configuration_status
  automated_snapshot_retention_period  = var.redshift.automated_snapshot_retention_period
  availability_zone                    = var.redshift.availability_zone
  availability_zone_relocation_enabled = var.redshift.availability_zone_relocation_enabled
  cluster_identifier                   = local.cluster_identifier
  cluster_parameter_group_name         = aws_redshift_parameter_group.reds[0].name
  #cluster_subnet_group_name            = local.subnet_group_name
  cluster_subnet_group_name            = aws_db_subnet_group.rs_subnets.name
  cluster_type                         = var.redshift.number_of_nodes > 1 ? "multi-node" : "single-node"
  cluster_version                      = var.redshift.cluster_version
  database_name                        = local.database_name
  elastic_ip                           = var.redshift.elastic_ip
  encrypted                            = var.redshift.encrypted
  enhanced_vpc_routing                 = var.redshift.enhanced_vpc_routing
  final_snapshot_identifier            = var.redshift.skip_final_snapshot ? null : var.redshift.final_snapshot_identifier
  kms_key_id                           = data.aws_kms_key.key.arn
  #default_iam_role_arn                 = aws_iam_role.redshift[0].arn
  #manage_master_password               = var.manage_master_password

  # iam_roles and default_iam_roles are managed in the aws_redshift_cluster_iam_roles resource below

  /*
  dynamic "logging" {
    for_each = can(var.logging.enable) ? [var.logging] : []

    content {
      bucket_name          = try(logging.value.bucket_name, null)
      enable               = logging.value.enable
      log_destination_type = try(logging.value.log_destination_type, null)
      log_exports          = try(logging.value.log_exports, null)
      s3_key_prefix        = try(logging.value.s3_key_prefix, null)
    }
  }*/

  maintenance_track_name           = var.redshift.maintenance_track_name
  manual_snapshot_retention_period = var.redshift.manual_snapshot_retention_period
  #master_password                  = var.snapshot_identifier != null ? null : local.master_password
  master_password              = var.master_password
  master_username              = var.master_username
  node_type                    = var.redshift.node_type
  number_of_nodes              = var.redshift.number_of_nodes
  #owner_account                = var.redshift.owner_account
  owner_account                = data.aws_caller_identity.current.account_id
  port                         = var.redshift.port
  preferred_maintenance_window = var.redshift.preferred_maintenance_window
  publicly_accessible          = var.redshift.publicly_accessible
  skip_final_snapshot          = var.redshift.skip_final_snapshot
  #  snapshot_cluster_identifier      = var.snapshot_cluster_identifier

  #   dynamic "snapshot_copy" {
  #     for_each = length(var.snapshot_copy) > 0 ? [var.snapshot_copy] : []

  #     content {
  #       destination_region = snapshot_copy.value.destination_region
  #       grant_name         = try(snapshot_copy.value.grant_name, null)
  #       retention_period   = try(snapshot_copy.value.retention_period, null)
  #     }
  #  }

  snapshot_identifier    = var.redshift.snapshot_identifier
  vpc_security_group_ids = [aws_security_group.sg_db.id]

  timeouts {
    create = try(var.cluster_timeouts.create, null)
    update = try(var.cluster_timeouts.update, null)
    delete = try(var.cluster_timeouts.delete, null)
  }

  lifecycle {
    ignore_changes = [master_password]
  }

  depends_on = [ aws_redshift_parameter_group.reds ]

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", local.short_identifier) })
  )
}

################################################################################
# Redshift bucket policy for logging
################################################################################

resource "aws_s3_bucket_policy" "redshift_logging" {
  bucket = var.logging.bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = [
            "s3:PutObject",
            "s3:PutObjectAcl",
            "s3:Get*"
          ]
        Resource = [
          "arn:aws:s3:::prsn-redshift-logs-${var.env.region}-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::prsn-redshift-logs-${var.env.region}-${data.aws_caller_identity.current.account_id}/*"
        ]
      }
    ]
  })
}

################################################################################
# Redshift Logging
################################################################################
resource "aws_redshift_logging" "rs_logging" {
  count = var.redshift.create && var.logging.enable ? 1 : 0

  cluster_identifier  = aws_redshift_cluster.reds[0].id
  log_destination_type = var.logging.log_destination_type
  bucket_name          = var.logging.bucket_name
  s3_key_prefix        = var.logging.s3_key_prefix
  log_exports          = var.logging.log_destination_type != "s3" ? ["userlog", "connectionlog", "useractivitylog"] : []

  depends_on = [ aws_s3_bucket_policy.redshift_logging ]
}

################################################################################
# Clinical IAM Roles
################################################################################
resource "aws_iam_role" "redshift" {
  count = var.redshift.create ? 1 : 0
  name  = "${local.short_identifier}-role"
  assume_role_policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = "sts:AssumeRole"
          Principal = {
            Service = "redshift.amazonaws.com"
          }
        }
      ]
    }
  )

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-role", local.short_identifier) })
  )
}

resource "aws_iam_policy" "redshift_custom_policy" {
  count = var.redshift.create ? 1 : 0
  name  = "${local.short_identifier}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetBucketAcl",
          "s3:GetBucketCors",
          "s3:GetEncryptionConfiguration",
          "s3:GetObjectTagging",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
          "s3:PutObjectTagging"
        ]
        Resource = [
          "arn:aws:s3:::${var.logging.bucket_name}",
          "arn:aws:s3:::${var.logging.bucket_name}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "redshift_custom_policy" {
  count = var.redshift.create ? 1 : 0

  role       = aws_iam_role.redshift[0].name
  policy_arn = aws_iam_policy.redshift_custom_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "AmazonDMSRedshiftS3Role" {
  count = var.redshift.create ? 1 : 0

  role       = aws_iam_role.redshift[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSRedshiftS3Role"
}

resource "aws_iam_role_policy_attachment" "AmazonRedshiftFullAcces" {
  count = var.redshift.create ? 1 : 0

  role       = aws_iam_role.redshift[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRedshiftFullAccess"
}

/*
resource "aws_iam_role_policy_attachment" "AmazonS3FullAccess" {
  count = var.redshift.create ? 1 : 0

  role       = aws_iam_role.redshift[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}*/

resource "aws_redshift_cluster_iam_roles" "reds" {
  count = var.redshift.create && length(var.iam_role_arns) > 0 ? 1 : 0

  cluster_identifier   = aws_redshift_cluster.reds[0].id
  iam_role_arns        = aws_iam_role.redshift[*].arn
  default_iam_role_arn = aws_iam_role.redshift[0].arn
  depends_on           = [aws_redshift_cluster.reds]
}

################################################################################
# Parameter Group
################################################################################

resource "aws_redshift_parameter_group" "reds" {
  count = var.redshift.create && var.redshift.parameter_group_name != "" ? 1 : 0

  name        = "${local.short_identifier}-param-grp"
  description = "Redshift parameter group"
  family      = var.parameter_group_family

  dynamic "parameter" {
    for_each = var.parameter_group_parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-param-grp", local.short_identifier) })
  )
}

################################################################################
# Subnet Group
################################################################################
/*
resource "aws_redshift_subnet_group" "reds" {
  count = var.redshift.create && var.redshift.create_subnet_group ? 1 : 0

  name        = coalesce(var.subnet_group_name, local.cluster_identifier)
  description = var.subnet_group_description
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, var.subnet_group_tags)
}
*/
resource "aws_redshift_subnet_group" "reds" {
  count = var.redshift.create ? 1 : 0

  name        = "${local.short_identifier}-sub-grp"
  description = "Redshift subnet group"
  subnet_ids  = data.aws_subnets.private.ids

  lifecycle {
    #create_before_destroy = true
    ignore_changes = [tags]
  }

  tags        = merge(
    var.tags,
    tomap({ Name = format("%s-subnet-grp", local.short_identifier) })
  )
}

################################################################################
# Snapshot Schedule
################################################################################

resource "aws_redshift_snapshot_schedule" "reds" {
  count = var.redshift.create && var.redshift.create_snapshot_schedule ? 1 : 0

  identifier        = var.use_snapshot_identifier_prefix ? null : var.snapshot_schedule_identifier
  identifier_prefix = var.use_snapshot_identifier_prefix ? "${var.snapshot_schedule_identifier}-" : null
  description       = var.snapshot_schedule_description
  definitions       = var.snapshot_schedule_definitions
  force_destroy     = var.snapshot_schedule_force_destroy

  tags = var.tags
}

resource "aws_redshift_snapshot_schedule_association" "reds" {
  count = var.redshift.create && var.redshift.create_snapshot_schedule ? 1 : 0

  cluster_identifier  = aws_redshift_cluster.reds[0].id
  schedule_identifier = aws_redshift_snapshot_schedule.reds[0].id
}

################################################################################
# Scheduled Action
################################################################################

locals {
  iam_role_name = coalesce(var.iam_role_name, "${local.cluster_identifier}-scheduled-action")
}

/*
resource "aws_redshift_scheduled_action" "reds" {
  count = var.redshift.create_scheduled_action_iam_role ? 1 : 0

  for_each = { for k, v in var.scheduled_actions : k => v if var.redshift.create_schd }

  name        = each.value.name
  description = try(each.value.description, null)
  enable      = try(each.value.enable, null)
  start_time  = try(each.value.start_time, null)
  end_time    = try(each.value.end_time, null)
  schedule    = each.value.schedule
  iam_role    = var.redshift.create_scheduled_action_iam_role ? aws_iam_role.scheduled_action[0].arn : each.value.iam_role

  target_action {
    dynamic "pause_cluster" {
      for_each = try([each.value.pause_cluster], [])

      content {
        cluster_identifier = aws_redshift_cluster.reds[0].id
      }
    }

    dynamic "resize_cluster" {
      for_each = try([each.value.resize_cluster], [])

      content {
        classic            = try(resize_cluster.value.classic, null)
        cluster_identifier = aws_redshift_cluster.reds[0].id
        cluster_type       = try(resize_cluster.value.cluster_type, null)
        node_type          = try(resize_cluster.value.node_type, null)
        number_of_nodes    = try(resize_cluster.value.number_of_nodes, null)
      }
    }

    dynamic "resume_cluster" {
      for_each = try([each.value.resume_cluster], [])

      content {
        cluster_identifier = aws_redshift_cluster.reds[0].id
      }
    }
  }
}*/

data "aws_iam_policy_document" "scheduled_action_assume" {
  count = var.redshift.create && var.redshift.create_scheduled_action_iam_role ? 1 : 0

  statement {
    sid     = "ScheduleActionAssume"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.redshift.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "scheduled_action" {
  count = var.redshift.create && var.redshift.create_scheduled_action_iam_role ? 1 : 0

  name        = var.iam_role_use_name_prefix ? null : local.iam_role_name
  name_prefix = var.iam_role_use_name_prefix ? "${local.iam_role_name}-" : null
  path        = var.iam_role_path
  description = var.iam_role_description

  permissions_boundary  = var.iam_role_permissions_boundary
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.scheduled_action_assume[0].json

  tags = merge(var.tags, var.iam_role_tags)
}

data "aws_iam_policy_document" "scheduled_action" {
  count = var.redshift.create && var.redshift.create_scheduled_action_iam_role ? 1 : 0

  statement {
    sid = "ModifyCluster"

    actions = [
      "redshift:PauseCluster",
      "redshift:ResumeCluster",
      "redshift:ResizeCluster",
    ]

    resources = [
      aws_redshift_cluster.reds[0].arn
    ]
  }
}

resource "aws_iam_role_policy" "scheduled_action" {
  count = var.redshift.create && var.redshift.create_scheduled_action_iam_role ? 1 : 0

  name   = var.iam_role_name
  role   = aws_iam_role.scheduled_action[0].name
  policy = data.aws_iam_policy_document.scheduled_action[0].json
}

################################################################################
# Clinical Endpoint Access
################################################################################

resource "aws_redshift_endpoint_access" "reds" {
  count = var.redshift.create && var.redshift.create_endpoint_access ? 1 : 0

  cluster_identifier = aws_redshift_cluster.reds[0].id

  endpoint_name  = "${local.cluster_identifier}-endpoint"
  #resource_owner = var.endpoint_resource_owner
  #subnet_group_name      = coalesce(var.endpoint_subnet_group_name, local.subnet_group_name)
  subnet_group_name      = aws_redshift_subnet_group.reds[0].name
  vpc_security_group_ids = [aws_security_group.sg_db.id]
}

################################################################################
# Clinical Usage Limit
################################################################################

resource "aws_redshift_usage_limit" "reds" {
  for_each = { for k, v in var.usage_limits : k => v if var.redshift.create }

  cluster_identifier = aws_redshift_cluster.reds[0].id

  amount        = each.value.amount
  breach_action = try(each.value.breach_action, null)
  feature_type  = each.value.feature_type
  limit_type    = each.value.limit_type
  period        = try(each.value.period, null)

  tags = merge(var.tags, try(each.value.tags, {}))
}

################################################################################
# Clinical Authentication Profile
################################################################################

resource "aws_redshift_authentication_profile" "reds" {
  for_each = { for k, v in var.authentication_profiles : k => v if var.redshift.create }

  authentication_profile_name    = try(each.value.name, each.key)
  authentication_profile_content = jsonencode(each.value.content)
}

resource "aws_route53_record" "redshift_r53" {
  name            = local.r53_record_name
  depends_on      = [aws_redshift_cluster.reds]
  zone_id         = data.aws_route53_zone.this.zone_id
  type            = "CNAME"
  ttl             = "300"
  records         = [trim(aws_redshift_cluster.reds[0].endpoint, ":${aws_redshift_cluster.reds[0].port}")]
  allow_overwrite = true

  lifecycle {
    create_before_destroy = true
  }
}

# CloudWatch monitoring

data "aws_sns_topic" "sns_topic" {
  name = "${var.tags.environment}-notifications"
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  count               = var.redshift.create ? 1 : 0
  alarm_name          = "${local.cluster_identifier}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.cloudwatch.high_cpu_eval_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/Redshift"
  period              = var.cloudwatch.high_cpu_period
  statistic           = "Average"
  threshold           = var.cloudwatch.high_cpu_threshold
  treat_missing_data  = "missing"
  alarm_description   = "Average CPU utilization of the RDS instance ${var.tags.environment} is more than ${var.cloudwatch.high_cpu_threshold}% during last ${(var.cloudwatch.high_cpu_period * var.cloudwatch.high_cpu_eval_periods) / 60} minutes. Performance may suffer!!!"
  alarm_actions       = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  ok_actions          = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  dimensions = {
    DBInstanceIdentifier = aws_redshift_cluster.reds[0].id
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-high-cpu", aws_redshift_cluster.reds[0].id) })
  )
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  count               = var.redshift.create ? 1 : 0
  alarm_name          = "${local.cluster_identifier}-low-freeable-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.cloudwatch.freeable_memory_eval_periods
  metric_name         = "FreeableMemory"
  namespace           = "AWS/Redshift"
  period              = var.cloudwatch.freeable_memory_period
  statistic           = "Average"
  threshold           = var.cloudwatch.freeable_memory_threshold
  treat_missing_data  = "missing"
  alarm_description   = "Average database freeable memory of RDS instance ${var.tags.environment}-${count.index} is less than ${var.cloudwatch.freeable_memory_threshold / 1024} MB in last ${(var.cloudwatch.freeable_memory_period * var.cloudwatch.freeable_memory_eval_periods) / 60} minutes. Performance may suffer!!!"
  alarm_actions       = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  ok_actions          = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []

  dimensions = {
    DBInstanceIdentifier = aws_redshift_cluster.reds[0].id
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-low-freeable-memory", aws_redshift_cluster.reds[0].id) })
  )
}

resource "aws_cloudwatch_metric_alarm" "storage" {
  count               = var.redshift.create ? 1 : 0
  alarm_name          = "${local.cluster_identifier}-low-disk-space"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.cloudwatch.low_storage_eval_periods
  metric_name         = "PercentageDiskSpaceUsed"
  namespace           = "AWS/Redshift"
  period              = var.cloudwatch.low_storage_period
  statistic           = "Average"
  threshold           = var.cloudwatch.low_storage_threshold
  treat_missing_data  = "missing"
  alarm_description   = "Average database freeable memory of RDS instance ${var.tags.environment}-${count.index} is more than ${var.cloudwatch.low_storage_threshold} MB in last ${(var.cloudwatch.low_storage_period * var.cloudwatch.low_storage_eval_periods) / 60} minutes. Add more storage immediately!!!"
  alarm_actions       = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []
  ok_actions          = var.tags.t_environment == "PRD" ? [data.aws_sns_topic.sns_topic.arn] : []

  dimensions = {
    DBInstanceIdentifier = aws_redshift_cluster.reds[0].id
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-low-freeable-memory", aws_redshift_cluster.reds[0].id) })
  )
}