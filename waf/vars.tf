variable "env" {
  description = "A map of environment variables"
  type        = map(any)
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(any)
}

variable "waf" {
  description = "A map of WAF variables"
  type        = map(any)
  default = {
    cloudfront  = true
    alb         = false
    api_gateway = false
  }
}

variable "logs" {
  description = "Enable logging for WAF"
  type        = map(string)
  default     = {
    enabled           = false
    retention_period  = 7
  }
}

variable "managed_rules" {
  type = list(object({
    name            = string
    priority        = number
    override_action = string
    excluded_rules  = list(string)
    exceptions      = list(string)
  }))
  description = "List of Managed WAF rules."
  default = [
    {
      name            = "AWSManagedRulesKnownBadInputsRuleSet",
      priority        = 10
      override_action = "none"
      excluded_rules = [
        "Host_localhost_HEADER",
        "PROPFIND_METHOD",
        "ExploitablePaths_URIPATH"
      ]
      exceptions = []
    },
    {
      name            = "AWSManagedRulesSQLiRuleSet",
      priority        = 11
      override_action = "count"
      excluded_rules  = []
      exceptions      = []
    },
    {
      name            = "AWSManagedRulesBotControlRuleSet",
      priority        = 12
      override_action = "count"
      excluded_rules  = []
      exceptions      = []
    },
    {
      name            = "AWSManagedRulesCommonRuleSet",
      priority        = 13
      override_action = "count"
      excluded_rules  = []
      exceptions      = []
    },
    {
      name            = "AWSManagedRulesAmazonIpReputationList",
      priority        = 14
      override_action = "count"
      excluded_rules  = []
      exceptions      = []
    }
  ]
}

variable "group_rules" {
  type = list(object({
    name = string
    #arn_cf          = string
    arn_regional    = string
    priority        = number
    override_action = string
    excluded_rules  = list(string)
  }))
  description = "List of WAFv2 Rule Groups."
  default     = []
}

variable "default_action" {
  type        = string
  description = "The action to perform if none of the rules contained in the WebACL match."
  default     = "allow"
}

variable "ip-limit" {
  type        = number
  description = "The rate limit for the DDoS rule"
  default     = 1000
}
