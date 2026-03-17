# This Terraform module is designed to provision and manage following components on top of a specific EKS cluster
# - Load Balancer Controller
# - Secrets Store CSI Driver
# - Secrets Store CSI Driver AWS Provider
# - IAM roles and policies for the above components
# - Kubernetes namespace
#
# It provides a reusable and configurable way to deploy [specific resources or services] with best practices and flexibility.
#
# ## Features
# - [List key features or functionalities of the module, e.g., automated resource creation, scalability, security configurations, etc.]
# - [Another feature]
#
# ## Usage
# To use this module, include it in your Terraform configuration and provide the required input variables.
# Customize the optional variables as needed to suit your environment.
#
# ## Inputs
# - [List key input variables and their purpose, e.g., `variable_name` - Description of the variable.]
#
# ## Outputs
# - [List key outputs and their purpose, e.g., `output_name` - Description of the output.]
#
# ## Prerequisites
# - Ensure that [list any prerequisites, e.g., specific Terraform version, provider configuration, or external dependencies].
#
# ## Notes
# - [Add any additional notes or considerations for using the module.]


terraform {
  required_version = ">= 1.11.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

locals {
  role              = "eks-namespace-${var.namespace}"
  short_identifier  = "${var.tags.environment}-${local.role}"
  eks_cluster_name  = "${var.tags.environment}-eks-cluster"
  aws_lb_controller = "${var.tags.environment}-aws-lb-controller"
  namespace         = var.namespace == "" ? var.tags.environment : var.namespace

  account_name = var.env.account_name
}

provider "aws" {
  region = var.env.region
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

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.cluster.name]
      command     = "aws"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = [local.account_name]
  }
}

data "aws_eks_cluster" "cluster" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = local.eks_cluster_name
}

data "tls_certificate" "oidc" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc_provider" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

resource "kubernetes_namespace" "namespace" {
  metadata {
    name = local.namespace
    labels = {
      environment = lower(var.tags.t_environment)
      team        = "SRE4"
    }
  }
}

# --- Load Balancer Controller components ---

resource "aws_iam_policy" "alb_controller_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  path        = "/"
  description = "Policy for the ALB Controller"

  policy = file("lb-ctrl-iam-policy.json") # From AWS official example
}

resource "aws_iam_role" "eks_lb_sa" {
  name = "${local.short_identifier}-load-balancer-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "${aws_iam_openid_connect_provider.oidc_provider.arn}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace("${aws_iam_openid_connect_provider.oidc_provider.url}", "https://", "")}:sub" = "system:serviceaccount:${kubernetes_namespace.namespace.metadata[0].name}:${var.alb.service_account_name}"
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = format("${local.short_identifier}-load-balancer-sa-role")
    }
  )
}

resource "aws_iam_role_policy_attachment" "lb_policy_attach" {
  role       = aws_iam_role.eks_lb_sa.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}

resource "kubernetes_service_account_v1" "lb_service_account" {
  metadata {
    name      = var.alb.service_account_name
    namespace = kubernetes_namespace.namespace.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = var.alb.service_account_name
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = aws_iam_role.eks_lb_sa.arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "lb" {
  name       = "aws-load-balancer-controller"
  chart      = "aws-load-balancer-controller"
  repository = var.alb.lb_controller_repo
  namespace  = kubernetes_namespace.namespace.metadata[0].name
  timeout    = var.alb.timeout

  depends_on = [
    kubernetes_service_account_v1.lb_service_account
  ]

  set {
    name  = "region"
    value = var.env.region
  }

  set {
    name  = "vpcId"
    value = data.aws_vpc.vpc.id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.lb_service_account.metadata[0].name
  }

  set {
    name  = "clusterName"
    value = data.aws_eks_cluster.cluster.name
  }
}

# --- Secrets Provider components ---

resource "kubernetes_service_account_v1" "secrets_provider" {
  metadata {
    name      = var.secrets.service_account_name
    namespace = kubernetes_namespace.namespace.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = var.secrets.service_account_name
      "app.kubernetes.io/component" = "secrets"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.sa_access_secrets.arn
    }
  }
}

resource "helm_release" "secrets_csi_driver" {
  name = "secrets-store-csi-driver"

  repository = var.secrets.csi_driver_repo
  chart      = "secrets-store-csi-driver"
  version    = var.secrets.csi_driver_version
  namespace  = kubernetes_namespace.namespace.metadata[0].name

  set {
    name  = "syncSecret.enabled"
    value = var.secrets.csi_driver_sync_secret_enabled ? "true" : "false"
  }

  set {
    name  = "enableSecretRotation"
    value = var.secrets.csi_driver_secret_rotation_enabled ? "true" : "false"
  }

  set {
    name  = "rotationPollInterval"
    value = var.secrets.csi_driver_rotation_poll_interval
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.secrets_provider.metadata[0].name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }
}

resource "helm_release" "secrets_csi_driver_aws_provider" {
  name = "secrets-store-csi-driver-provider-aws"

  repository = var.secrets.csi_driver_provider_aws_repo
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.secrets.csi_driver_provider_aws_version
  namespace  = kubernetes_namespace.namespace.metadata[0].name

  set {
    name  = "secrets-store-csi-driver.install"
    value = "false"
  }

  depends_on = [helm_release.secrets_csi_driver]
}

resource "aws_iam_role" "sa_access_secrets" {
  name = "${local.short_identifier}-secrets-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "${aws_iam_openid_connect_provider.oidc_provider.arn}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            #"${replace("${aws_iam_openid_connect_provider.oidc_provider.url}", "https://", "")}:sub" = "system:serviceaccount:${var.namespace}:${kubernetes_service_account.sa.metadata[0].name}"
            "${replace("${aws_iam_openid_connect_provider.oidc_provider.url}", "https://", "")}:sub" = "system:serviceaccount:${kubernetes_namespace.namespace.metadata[0].name}:${var.secrets.service_account_name}"
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = format("${local.short_identifier}-secrets-sa-role")
    }
  )
}

resource "aws_iam_policy" "secrets_access" {
  name        = "${local.short_identifier}-secrets-access-policy"
  description = "Policy for accessing secrets in AWS Secrets Manager"

  policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect":"Allow",
        "Action" : [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ],
        "Resource": [
          "arn:aws:secretsmanager:${var.env.region}:${data.aws_caller_identity.current.account_id}:secret:*"
        ]
      },
      {
        "Effect":"Allow",
        "Action" : [
          "lambda:InvokeFunction"
        ],
        "Resource": [
          "arn:aws:lambda:${var.env.region}:${data.aws_caller_identity.current.account_id}:function:${var.tags.environment}-*"
        ]
      }
    ]
  }
  EOF
}

resource "aws_iam_role_policy_attachment" "secrets_policy_attach" {
  role       = aws_iam_role.sa_access_secrets.name
  policy_arn = aws_iam_policy.secrets_access.arn
}