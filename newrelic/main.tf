terraform {
  required_version = ">= 1.14.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0.0"
    }
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.63.0"
    }
  }
}

provider "aws" {
  region = var.env.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.cluster.name]
    command     = "aws"
  }
}

data "aws_secretsmanager_secret_version" "newrelic" {
  secret_id = var.newrelic.secret_name == null || var.newrelic.secret_name == "" ? format("%s/newrelic", lower(var.tags.t_environment)) : var.newrelic.secret_name
}

locals {
  role                 = "newrelic"
  short_identifier     = "${var.tags.environment}-${local.role}"
  eks_cluster_name     = "${var.tags.environment}-eks-cluster"
  service_account_name = "newrelic"
  secret_values        = jsondecode(data.aws_secretsmanager_secret_version.newrelic.secret_string)
}

provider "newrelic" {
  account_id = local.secret_values.account_id
  api_key    = local.secret_values.api_key
  region     = "US"
}

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "cluster" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = local.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "oidc_provider" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "kubernetes_namespace_v1" "newrelic" {
  metadata {
    name = "newrelic"
  }
}

resource "aws_iam_role" "newrelic_role" {
  name = "${local.short_identifier}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "${data.aws_iam_openid_connect_provider.oidc_provider.arn}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace("${data.aws_iam_openid_connect_provider.oidc_provider.url}", "https://", "")}:sub" = "system:serviceaccount:${kubernetes_namespace_v1.newrelic.metadata[0].name}:${local.service_account_name}"
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = format("${local.short_identifier}-newrelic-service-account-role")
    }
  )
}

resource "aws_iam_role_policy_attachment" "newrelic_role_policy_attachment" {
  role       = aws_iam_role.newrelic_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

resource "kubernetes_service_account" "new_relic_sa" {
  metadata {
    name      = local.service_account_name
    namespace = local.role
    labels = {
      "app.kubernetes.io/name"       = local.service_account_name
      "app.kubernetes.io/component"  = "newrelic"
      "app.kubernetes.io/managed-by" = "Helm"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = aws_iam_role.newrelic_role.arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
      "meta.helm.sh/release-name"                = "newrelic-infrastructure"
      "meta.helm.sh/release-namespace"           = local.role

    }
  }
}


provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.cluster.name]
      command     = "aws"
    }
  }
}

resource "helm_release" "newrelic" {
  name       = var.newrelic.helm_chart_name
  repository = var.newrelic.helm_chart_repo
  chart      = var.newrelic.helm_chart
  version    = var.newrelic.helm_chart_version
  namespace  = kubernetes_namespace_v1.newrelic.metadata[0].name
  depends_on = [ kubernetes_service_account.new_relic_sa ]

  set {
    name  = "newrelic-infrastructure.enabled"
    value = var.newrelic.infrastructure_enabled
  }
  set {
    name = "nri-prometheus.enabled"
    value = var.newrelic.nri_prometheus_enabled
  }
  set {
    name  = "nri-metadata-injection.enabled"
    value = "${var.newrelic.nri_metadata_injection_enabled}"
  }
  set {
    name  = "kube-state-metrics.enabled"
    value = "${var.newrelic.kube_state_metrics_enabled}"
  }
  set {
    name  = "nri-kube-events.enabled"
    value = "${var.newrelic.nri_kube_events_enabled}"
  }
  set {
    name  = "newrelic-logging.enabled"
    value = "${var.newrelic.logging_enabled}"
  }
  set {
    name = "newrelic-pixie.enabled"
    value = "${var.newrelic.pixie_enabled}"
  }
  set {
    name  = "pixie-chart.enabled"
    value = "${var.newrelic.pixie_chart_enabled}"
  }
  set {
    name  = "newrelic-infra-operator.enabled"
    value = "${var.newrelic.infra_operator_enabled}"
  }
  set {
    name = "newrelic-prometheus-agent.enabled"
    value = "${var.newrelic.prometheus_agent_enabled}"
  }
  set {
    name = "newrelic-eapm-agent.enabled"
    value = "${var.newrelic.eapm_agent_enabled}"
  }
  set {
    name = "k8s-agents-operator.enabled"
    value = "${var.newrelic.k8s_agents_operator_enabled}"
  }
  set {
    name = "newrelic-k8s-metrics-adapter.enabled"
    value = "${var.newrelic.k8s_metrics_adapter_enabled}"
  }
  set {
    name  = "global.serviceAccount.name"
    value = local.service_account_name
  }
  set {
    name  = "global.licenseKey"
    value = local.secret_values.license_key
  }
  set {
    name  = "global.cluster"
    value = local.eks_cluster_name
  }
  set {
    name = "global.verboseLog.enabled"
    value = "${var.newrelic.verbose_log_enabled}"
  }
  set {
    name  = "privileged.enabled"
    value = "${var.newrelic.privileged_enabled}"
  }
}