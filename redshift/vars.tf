variable "env" {
  description = "Environment variables"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}

variable "create_schd" {
  description = "Determines whether to create Redshift cluster schedules (affects schedule resources)"
  type        = bool
  default     = false
}

################################################################################
# Cluster
################################################################################
variable "redshift" {
  description = "Redshift cluster configuration"
  type        = map(any)
  default = {
    allow_version_upgrade                = false
    apply_immediately                    = false
    automated_snapshot_retention_period  = 7
    availability_zone                    = "us-east-1a"
    availability_zone_relocation_enabled = false
    cluster_version                      = "1.0"
    database_name                        = "dev"
    elastic_ip                           = null
    encrypted                            = true
    enhanced_vpc_routing                 = false
    final_snapshot_identifier            = ""
    maintenance_track_name               = "current"
    manual_snapshot_retention_period     = -1
    node_type                            = "dc2.large"
    number_of_nodes                      = 1
    owner_account                        = ""
    parameter_group_name                 = ""
    port                                 = 5439
    preferred_maintenance_window         = "sun:05:00-sun:09:00"
    publicly_accessible                  = false
    skip_final_snapshot                  = true
    snapshot_cluster_identifier          = null
    snapshot_identifier                  = ""
    create_snapshot_schedule             = true
    create_scheduled_action_iam_role     = false
  }
}

variable "cloudwatch" {
  description = "Cloudwatch alarm configs for the Redshift cluster"
  type = object({
    high_cpu_period              = optional(number, 60)
    high_cpu_eval_periods        = optional(number, 3)
    high_cpu_threshold           = optional(number, 75)
    freeable_memory_period       = optional(number, 60)
    freeable_memory_eval_periods = optional(number, 3)
    freeable_memory_threshold    = optional(number, 90)
    low_storage_period           = optional(number, 60)
    low_storage_eval_periods     = optional(number, 10)
    low_storage_threshold        = optional(number, 80)
  })
}

# cluster_parameter_group_name -> see parameter group section
# cluster_subnet_group_name -> see subnet group section
# default_iam_role_arn -> see iam roles section


# iam_roles -> see iam roles section

variable "logging" {
  description = "Logging configuration for the cluster"
  type        = map(any)
}

variable "master_password" {
  description = "Password for the master DB user. (Required unless a `snapshot_identifier` is provided). Must contain at least 8 chars, one uppercase letter, one lowercase letter, and one number"
  type        = string
  default     = null
  sensitive   = true
}

variable "manage_master_password" {
  description = "If true, Amazon Redshift uses AWS Secrets Manager to manage this cluster's admin credentials. You can't use MasterUserPassword if ManageMasterPassword is true. If ManageMasterPassword is false or not set, Amazon Redshift uses MasterUserPassword for the admin user account's password."
  type        = string
  default     = false
}

variable "create_random_password" {
  description = "Determines whether to create random password for cluster `master_password`"
  type        = bool
  default     = true
}

variable "random_password_length" {
  description = "Length of random password to create. Defaults to `16`"
  type        = number
  default     = 16
}

variable "master_username" {
  description = "Username for the master DB user (Required unless a `snapshot_identifier` is provided). Defaults to `awsuser`"
  type        = string
  default     = "awsuser"
}

variable "snapshot_copy" {
  description = "Configuration of automatic copy of snapshots from one region to another"
  type        = any
  default     = {}
}

# variable "vpc_security_group_ids" {
#   description = "A list of Virtual Private Cloud (VPC) security groups to be associated with the cluster"
#   type        = list
#   default     = []
# }

variable "cluster_timeouts" {
  description = "Create, update, and delete timeout configurations for the cluster"
  type        = map(string)
  default     = {}
}

################################################################################
# IAM Roles
################################################################################

variable "iam_role_arns" {
  description = "A list of IAM Role ARNs to associate with the cluster. A Maximum of 10 can be associated to the cluster at any time"
  type        = list(string)
  default     = []
}

variable "default_iam_role_arn" {
  description = "The Amazon Resource Name (ARN) for the IAM role that was set as default for the cluster when the cluster was created"
  type        = string
  default     = null
}

################################################################################
# Parameter Group
################################################################################




variable "parameter_group_family" {
  description = "The family of the Redshift parameter group"
  type        = string
  default     = "redshift-1.0"
}

variable "parameter_group_parameters" {
  description = "value"
  type        = map(any)
  default     = {}
}


################################################################################
# Subnet Group
################################################################################

/*
variable "create_subnet_group" {
  description = "Determines whether to create a subnet group or use existing"
  type        = bool
  default     = true
}

variable "subnet_group_name" {
  description = "The name of the Redshift subnet group, existing or to be created"
  type        = string
  default     = null
}

variable "subnet_group_description" {
  description = "The description of the Redshift Subnet group. Defaults to `Managed by Terraform`"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "An array of VPC subnet IDs to use in the subnet group"
  type        = list(string)
  default     = []
}

variable "subnet_group_tags" {
  description = "Additional tags to add to the subnet group"
  type        = map(string)
  default     = {}
}*/

################################################################################
# Snapshot Schedule
################################################################################


variable "create_snapshot_schedule" {
  description = "Determines whether to create a snapshot schedule"
  type        = bool
  default     = false
}

variable "snapshot_schedule_identifier" {
  description = "The snapshot schedule identifier"
  type        = string
  default     = null
}

variable "use_snapshot_identifier_prefix" {
  description = "Determines whether the identifier (`snapshot_schedule_identifier`) is used as a prefix"
  type        = bool
  default     = true
}

variable "snapshot_schedule_description" {
  description = "The description of the snapshot schedule"
  type        = string
  default     = null
}

variable "snapshot_schedule_definitions" {
  description = "The definition of the snapshot schedule. The definition is made up of schedule expressions, for example `cron(30 12 *)` or `rate(12 hours)`"
  type        = list(string)
  default     = []
}

variable "snapshot_schedule_force_destroy" {
  description = "Whether to destroy all associated clusters with this snapshot schedule on deletion. Must be enabled and applied before attempting deletion"
  type        = bool
  default     = null
}

################################################################################
# Scheduled Action
################################################################################

variable "scheduled_actions" {
  description = "Map of maps containing scheduled action definitions"
  type        = any
  default     = {}
}

variable "create_scheduled_action_iam_role" {
  description = "Determines whether a scheduled action IAM role is created"
  type        = bool
  default     = false
}

variable "iam_role_name" {
  description = "Name to use on scheduled action IAM role created"
  type        = string
  default     = null
}

variable "iam_role_use_name_prefix" {
  description = "Determines whether scheduled action the IAM role name (`iam_role_name`) is used as a prefix"
  type        = string
  default     = true
}

variable "iam_role_path" {
  description = "Scheduled action IAM role path"
  type        = string
  default     = null
}

variable "iam_role_description" {
  description = "Description of the scheduled action IAM role"
  type        = string
  default     = null
}

variable "iam_role_permissions_boundary" {
  description = "ARN of the policy that is used to set the permissions boundary for the scheduled action IAM role"
  type        = string
  default     = null
}

variable "iam_role_tags" {
  description = "A map of additional tags to add to the scheduled action IAM role created"
  type        = map(string)
  default     = {}
}

################################################################################
# Endpoint Access
################################################################################

variable "create_endpoint_access" {
  description = "Determines whether to create an endpoint access (managed VPC endpoint)"
  type        = bool
  default     = false
}

/*
variable "endpoint_name" {
  description = "The Redshift-managed VPC endpoint name"
  type        = string
  default     = ""
}

variable "endpoint_resource_owner" {
  description = "The Amazon Web Services account ID of the owner of the cluster. This is only required if the cluster is in another Amazon Web Services account"
  type        = string
  default     = null
}

variable "endpoint_subnet_group_name" {
  description = "The subnet group from which Amazon Redshift chooses the subnet to deploy the endpoint"
  type        = string
  default     = ""
}

variable "endpoint_vpc_security_group_ids" {
  description = "The security group IDs to use for the endpoint access (managed VPC endpoint)"
  type        = list(string)
  default     = []
}*/

################################################################################
# Usage Limit
################################################################################

variable "usage_limits" {
  description = "Map of usage limit definitions to create"
  type        = any
  default     = {}
}

################################################################################
# Authentication Profile
################################################################################

variable "authentication_profiles" {
  description = "Map of authentication profiles to create"
  type        = any
  default     = {}
}

/*
variable "role" {
  default = "redshift"
}


variable "route53_zone_id" {
  default = ""
}*/
