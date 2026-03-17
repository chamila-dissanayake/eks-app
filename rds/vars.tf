variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(any)
}

variable "rds" {
  description = "RDS configuration"
  type = object({
    cluster_identifier           = optional(string, "")
    backup_retention             = optional(number, 7)
    backup_window                = optional(string, "07:00-09:00")
    engine                       = optional(string, "aurora-postgresql")
    engine_version               = optional(string, "15.13")
    instance_class               = optional(string, "db.t4g.medium")
    maintenance_window           = optional(string, "sun:04:00-sun:05:00")
    multi_az                     = optional(bool, false)
    snapshot_identifier          = optional(string, "golden-snapshot")
    sns_topic                    = optional(string, "")
    cluster_param_grp            = optional(string, "default.aurora-postgresql15")
    db_param_grp                 = optional(string, "default.aurora-postgresql15")
    master_username              = optional(string, "dba_admin")
    auto_minor_version_upgrade   = optional(bool, false)
    instance_count               = optional(number, 1)
    route53_record_ttl           = optional(number, 60)
    freeable_memory_period       = optional(number, 60)
    freeable_memory_eval_periods = optional(number, 5)
    freeable_memory_threshold    = optional(number, 512000)
    high_cpu_period              = optional(number, 60)
    high_cpu_eval_periods        = optional(number, 3)
    high_cpu_threshold           = optional(number, 70)
  })
}
