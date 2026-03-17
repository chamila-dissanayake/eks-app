terraform {
  required_version = ">= 1.14.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.1"
    }
  }
}

data "aws_secretsmanager_secret_version" "env_vars" {
  count     = var.deployment.env_var_secret != "" ? 1 : 0
  secret_id = var.deployment.env_var_secret
}

data "aws_secretsmanager_secret_version" "newrelic" {
  count     = var.apm.enabled ? 1 : 0
  secret_id = var.apm.newrelic_secret_name == "" || var.apm.newrelic_secret_name == null ? "${lower(var.tags.t_environment)}/newrelic" : var.apm.newrelic_secret_name
}

locals {
  eks_cluster_name = "${var.tags.environment}-eks-cluster"
  account_name = var.env.account_name
  secret_provider_objects = file("${var.secret.file}")
  newrelic_secrets = var.apm.enabled ? jsondecode(data.aws_secretsmanager_secret_version.newrelic[0].secret_string) : {}
  env_vars = var.deployment.env_var_secret != "" ? jsondecode(data.aws_secretsmanager_secret_version.env_vars[0].secret_string) : {}
}

provider "aws" {
  region = var.env.region
}

data "aws_eks_cluster" "cluster" {
  name = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.cluster.name]
    command     = "aws"
  }
}

data "kubernetes_namespace" "namespace" {
  metadata {
    name = var.namespace
  }
}

data "aws_caller_identity" "current" {}

data "aws_acm_certificate" "cert" {
  domain = var.env.domain
}

resource "kubernetes_manifest" "secrets_provider_class" {
  count = length(var.secret.service_account_name) == 0 ? 0 : 1

  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "${var.deployment.name}-secrets-provider"
      namespace = data.kubernetes_namespace.namespace.metadata[0].name
    }
    spec = {
      provider = "aws"
      parameters = {
        region  = var.env.region
        objects = local.secret_provider_objects
      }
      secretObjects = [{
        secretName = "${var.deployment.name}-configs"
        type       = "Opaque"
        data = [
          for key in var.secret.keys : {
            objectName = key
            key        = key
          }
        ]
      }]
    }
  }
}

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = var.deployment.name
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
    labels = {
      app         = var.deployment.name
      environment = "${lower(var.tags.t_environment)}"
    }
  }

  spec {
    replicas = var.deployment.replicas

    selector {
      match_labels = {
        app = var.deployment.name
      }
    }

    template {
      metadata {
        labels = {
          app = var.deployment.name
        }
      }

      spec {
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64"]
                }
              }
            }
          }
        }
        service_account_name = var.secret.service_account_name
        container {
          name              = var.deployment.name
          image             = "${var.deployment.ecr}:${var.deployment.image_version}"
          image_pull_policy = "Always"
          port {
            name           = var.deployment.port_name
            container_port = var.deployment.port
          }
          resources {
            requests = {
              cpu    = var.deployment.requests_cpu
              memory = var.deployment.requests_memory
            }
            limits = {
              cpu    = var.deployment.limits_cpu
              memory = var.deployment.limits_memory
            }
          }
          liveness_probe {
            http_get {
              path = var.deployment.health_check_path
              port = var.deployment.port
            }
            initial_delay_seconds = var.deployment.health_check_delay
            period_seconds        = var.deployment.health_check_interval
            timeout_seconds       = var.deployment.health_check_timeout
            failure_threshold     = var.deployment.health_check_failure_threshold
          }
          env {
            name  = "ENV"
            value = lower(var.tags.t_environment)
          }
          # New Relic APM environment variables
          dynamic "env" {
            for_each = var.apm.enabled ? [1] : []
            content {
              name  = "NEW_RELIC_APP_NAME"
              value = "${var.tags.environment}-${var.deployment.name}"
            }
          }
          dynamic "env" {
            for_each = var.apm.enabled ? [1] : []
            content {
              name  = "NEW_RELIC_LICENSE_KEY"
              value = local.newrelic_secrets.license_key
            }
          }
          dynamic "env" {
            for_each = var.deployment.env_var_secret != "" ? [1] : []
            content {
              name  = env.value
              value = local.env_vars[env.value]
            }
          }
        }
        node_selector = {
          "kubernetes.io/os" = "linux"
        }
      }
    }
  }
}

# Kubernetes Service
resource "kubernetes_service_v1" "app" {
  metadata {
    name      = "${var.deployment.name}-service"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
    labels = {
      app         = var.deployment.name
      environment = "${lower(var.tags.t_environment)}"
    }
  }

  spec {
    selector = {
      app = var.deployment.name
    }
    port {
      protocol    = "TCP"
      port        = var.deployment.port
      target_port = var.deployment.port
    }
    type = "NodePort"
  }
}

# Kubernetes Ingress
resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = "${var.deployment.name}-ingress"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name

    labels = {
      app         = var.deployment.name
      environment = "${lower(var.tags.t_environment)}"
    }
    annotations = {
      "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
      "alb.ingress.kubernetes.io/ingress.class" = "alb"

      # Target Group settings
      "alb.ingress.kubernetes.io/target-type"                           = "ip"
      "alb.ingress.kubernetes.io/target-group-attributes"               = "stickiness.enabled=${var.ingress.stickiness_enabled},stickiness.lb_cookie.duration_seconds=${var.ingress.lb_cookie_duration}"
      "alb.ingress.kubernetes.io/healthcheck-path"                      = var.ingress.tg_health_check_path
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds"          = var.ingress.health_check_interval
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"           = var.ingress.health_check_timeout
      "alb.ingress.kubernetes.io/healthcheck-healthy-threshold-count"   = var.ingress.health_check_failure_threshold
      "alb.ingress.kubernetes.io/healthcheck-unhealthy-threshold-count" = var.ingress.unhealthy_threshold

      # ALB Listener settings
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.ingress.idle_timeout}"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"             = var.ingress.ssl_redirect_port
      "alb.ingress.kubernetes.io/certificate-arn"          = data.aws_acm_certificate.cert.arn
      "alb.ingress.kubernetes.io/healthcheck-port"         = var.ingress.health_check_port
      "alb.ingress.kubernetes.io/ssl-policy"               = "ELBSecurityPolicy-TLS-1-2-2017-01"
      "alb.ingress.kubernetes.io/backend-protocol"         = var.ingress.backend_protocol
      "alb.ingress.kubernetes.io/preserve-client-ip"       = var.ingress.preserve_client_ip
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        # Exact health check path
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.app.metadata[0].name
              port {
                number = var.ingress.health_check_port
              }
            }
          }
        }
      }
    }
  }
}

# ConfigMap for NewRelic Node.js configuration
resource "kubernetes_config_map_v1" "newrelic_nodejs_config" {
  count = var.apm.enabled ? 1 : 0
  metadata {
    name      = "newrelic-nodejs-config"
    namespace = var.apm.newrelic_namespace
    labels = {
      "app.kubernetes.io/name"       = "newrelic-nodejs-config"
      "app.kubernetes.io/component"  = "apm-config"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "newrelic.js" = templatefile("${var.apm.template_file_path}", {
      app_name            = "${var.tags.environment}-${var.deployment.name}"
      distributed_tracing = var.apm.distributed_tracing_enabled
      transaction_tracer  = var.apm.transaction_tracer_enabled
      error_collector     = var.apm.error_collector_enabled
      browser_monitoring  = var.apm.browser_monitoring_enabled
      application_logging = var.apm.application_logging_enabled
      log_level           = var.apm.log_level
    })
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  count = var.hpa.enabled ? 1 : 0

  metadata {
    name      = "${var.deployment.name}-hpa"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
    labels = {
      app         = var.deployment.name
      environment = lower(var.tags.t_environment)
    }
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app.metadata[0].name
    }

    min_replicas = var.deployment.replicas
    max_replicas = var.hpa.max_replicas

    # CPU-based scaling
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.hpa.target_cpu_utilization
        }
      }
    }

    # Memory-based scaling
    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = var.hpa.target_memory_utilization
        }
      }
    }

    # Custom metrics (optional)
    dynamic "metric" {
      for_each = var.hpa.custom_metrics
      content {
        type = "Pods"
        pods {
          metric {
            name = metric.value.name
          }
          target {
            type          = "AverageValue"
            average_value = metric.value.target_value
          }
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = var.hpa.scale_up_stabilization_window
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = var.hpa.scale_up_percent
          period_seconds = var.hpa.scale_up_period
        }
        policy {
          type           = "Pods"
          value          = var.hpa.scale_up_pods
          period_seconds = var.hpa.scale_up_period
        }
      }
      scale_down {
        stabilization_window_seconds = var.hpa.scale_down_stabilization_window
        select_policy                = "Min"
        policy {
          type           = "Percent"
          value          = var.hpa.scale_down_percent
          period_seconds = var.hpa.scale_down_period
        }
      }
    }
  }
}

# Kubernetes CronJob for deployment restart
resource "kubernetes_cron_job_v1" "deployment_restart" {
  count = var.restart_schedule.enabled ? 1 : 0

  metadata {
    name      = "${var.deployment.name}-restart-cronjob"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
  }

  spec {
    schedule                      = var.restart_schedule.cron_expression
    successful_jobs_history_limit = var.restart_schedule.successful_jobs_history_limit
    failed_jobs_history_limit     = var.restart_schedule.failed_jobs_history_limit
    concurrency_policy            = var.restart_schedule.concurrency_policy == "" ? "Forbid" : var.restart_schedule.concurrency_policy

    job_template {
      metadata {
        labels = {
          app = "${var.deployment.name}-restart"
        }
      }

      spec {
        backoff_limit           = var.restart_schedule.backoff_limit == 0 ? 2 : var.restart_schedule.backoff_limit
        active_deadline_seconds = var.restart_schedule.active_deadline_seconds == 0 ? 300 : var.restart_schedule.active_deadline_seconds

        template {
          metadata {
            labels = {
              app = "${var.deployment.name}-restart"
            }
          }

          spec {
            service_account_name = kubernetes_service_account.restart_cronjob[0].metadata[0].name
            restart_policy       = var.restart_schedule.restart_policy == "" ? "Never" : var.restart_schedule.restart_policy

            container {
              name              = "kubectl-restart"
              image             = var.restart_schedule.image == "" ? "alpine/kubectl:latest" : var.restart_schedule.image
              image_pull_policy = "Always"

              command = ["/bin/bash"]
              args = [
                "-c",
                <<-EOT
                echo "Starting deployment restart at $(date)"
                echo "Cluster info:"
                kubectl cluster-info
                echo "Current deployment status:"
                kubectl get deployment ${var.deployment.name} -n ${var.namespace} -o wide
                echo "Restarting deployment..."
                kubectl rollout restart deployment/${var.deployment.name} -n ${var.namespace}
                echo "Waiting for rollout to complete..."
                kubectl rollout status deployment/${var.deployment.name} -n ${var.namespace} --timeout=300s
                echo "Deployment restart completed successfully at $(date)"
                kubectl get deployment ${var.deployment.name} -n ${var.namespace} -o wide
                EOT
              ]

              resources {
                requests = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
                limits = {
                  cpu    = "200m"
                  memory = "256Mi"
                }
              }

              # Environment variables for debugging
              env {
                name  = "DEPLOYMENT_NAME"
                value = var.deployment.name
              }

              env {
                name  = "NAMESPACE"
                value = var.namespace
              }
            }
          }
        }
      }
    }
  }
}

# Service account for CronJob
resource "kubernetes_service_account" "restart_cronjob" {
  count = var.restart_schedule.enabled ? 1 : 0

  metadata {
    name      = "${var.deployment.name}-restart-sa"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name

    labels = {
      app = "${var.deployment.name}-restart"
    }
  }
}

# Role for restart permissions
resource "kubernetes_role" "restart_cronjob" {
  count = var.restart_schedule.enabled ? 1 : 0

  metadata {
    name      = "${var.deployment.name}-restart-role"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
  }

  rule {
    api_groups     = ["apps", "extensions"]
    resources      = ["deployments"]
    resource_names = ["${var.deployment.name}"]
    verbs          = ["get", "patch", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments/status"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list"]
  }
}

# Role binding
resource "kubernetes_role_binding" "restart_cronjob" {
  count = var.restart_schedule.enabled ? 1 : 0

  metadata {
    name      = "${var.deployment.name}-restart-rb"
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.restart_cronjob[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.restart_cronjob[0].metadata[0].name
    namespace = data.kubernetes_namespace.namespace.metadata[0].name
  }
}
