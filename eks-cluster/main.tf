terraform {
  required_version = "~> 1.14.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.env.region
}

locals {
  role = "eks"

  account_name  = var.env.account_name
  bastion_name     = "${local.account_name}-bastion"
  short_identifier = format("%s-%s", var.tags.environment, local.role)
  date             = formatdate("YYYYMMDD", timestamp())
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

data "aws_route_table" "private" {
  subnet_id = data.aws_subnets.private.ids[0]
}

data "aws_security_group" "bastion" {
  filter {
    name   = "tag:Name"
    values = ["${local.bastion_name}"]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
}

data "aws_iam_instance_profile" "bastion_arn" {
  name = local.bastion_name
}

data "aws_iam_role" "bastion_role" {
  name = data.aws_iam_instance_profile.bastion_arn.role_name
}

data "aws_ami" "eks_node_img" {
  most_recent = true
  owners      = ["${data.aws_caller_identity.current.account_id}"]

  filter {
    name   = "tag:Name"
    values = ["pcm-amzn*-eks-node-${var.eks.cluster_version}-prod*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = "${var.tags.Name}-eks-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks.cluster_version

  vpc_config {
    subnet_ids              = data.aws_subnets.private.ids
    endpoint_private_access = var.eks.endpoint_private_access
    endpoint_public_access  = var.eks.endpoint_public_access
    public_access_cidrs = var.public_access_cidrs
    security_group_ids  = [aws_security_group.eks_cluster_sg.id]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_key.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_kms_key.eks_key,
    aws_kms_alias.eks_key_alias,
  ]

  tags = merge(
    var.tags,
    {
      Name = "${local.short_identifier}-cluster"
    }
  )
}

resource "aws_eks_node_group" "eks_node" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.tags.Name}-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private.ids

  scaling_config {
    desired_size = var.eks.desired_size
    max_size     = var.eks.max_size
    min_size     = var.eks.min_size
  }

  launch_template {
    id      = aws_launch_template.eks_nodes_tpl.id
    version = aws_launch_template.eks_nodes_tpl.latest_version
  }

  labels = var.labels
  tags = merge(
    var.tags,
    {
      Name = "${local.short_identifier}-node-group"
    }
  )

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_kms_key.eks_key,
    aws_kms_alias.eks_key_alias,
  ]
}

resource "aws_kms_key" "eks_key" {
  description             = "EKS Encryption Key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  is_enabled              = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "EC2 service to use the key"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKS Service to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.cluster.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:EnableKey",
          "kms:ImportKeyMaterial",
          "kms:GenerateRandom",
          "kms:Verify",
          "kms:GenerateDataKeyPair",
          "kms:GetParametersForImport",
          "kms:SynchronizeMultiRegionKey",
          "kms:UpdatePrimaryRegion",
          "kms:ScheduleKeyDeletion",
          "kms:DescribeKey",
          "kms:Sign",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GenerateDataKey*",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "Attachment of persistent resources"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.cluster.arn
        }
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" : "true"
          }
        }
      },
      {
        Sid    = "Node Group Role to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.node.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:EnableKey",
          "kms:ImportKeyMaterial",
          "kms:GenerateRandom",
          "kms:Verify",
          "kms:GenerateDataKeyPair",
          "kms:GetParametersForImport",
          "kms:SynchronizeMultiRegionKey",
          "kms:UpdatePrimaryRegion",
          "kms:ScheduleKeyDeletion",
          "kms:DescribeKey",
          "kms:Sign",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GenerateDataKey*",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "ASG use of key"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:EnableKey",
          "kms:ImportKeyMaterial",
          "kms:GenerateRandom",
          "kms:Verify",
          "kms:GenerateDataKeyPair",
          "kms:GetParametersForImport",
          "kms:SynchronizeMultiRegionKey",
          "kms:UpdatePrimaryRegion",
          "kms:ScheduleKeyDeletion",
          "kms:DescribeKey",
          "kms:Sign",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GenerateDataKey*",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "Auto Scaling to create grants"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" : "true"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "eks_key_alias" {
  name          = "alias/${var.tags.Name}-eks-key"
  target_key_id = aws_kms_key.eks_key.key_id
}

# Cluster IAM Role
resource "aws_iam_role" "cluster" {
  name = "${var.tags.Name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# Node Group IAM Role
resource "aws_iam_role" "node" {
  name = "${var.tags.Name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

data "aws_iam_policy_document" "lambda_policy_doc" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.env.region}:${data.aws_caller_identity.current.account_id}:function:${var.tags.environment}-*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "${local.short_identifier}-node-lambda-invoke-policy"
  description = "Lambda invoke policy for EKS nodes in ${local.short_identifier}-node-group"
  policy      = data.aws_iam_policy_document.lambda_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  policy_arn = aws_iam_policy.lambda_policy.arn
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

resource "aws_iam_policy" "access_kms" {
  name        = "${var.tags.Name}-eks-nodes-kms-access-policy"
  description = "Policy to allow EKS nodes to access KMS key for encryption and decryption"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlainText",
          "kms:ReEncrypt",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kms" {
  policy_arn = aws_iam_policy.access_kms.arn
  role       = aws_iam_role.node.name
}

# EKS Cluster Security Group
resource "aws_security_group" "eks_cluster_sg" {
  name        = "${var.tags.Name}-eks-cluster-sg"
  description = "Security group for EKS cluster"
  vpc_id      = data.aws_vpc.vpc.id

  tags = merge(
    var.tags,
    {
      Name                                                 = "${var.tags.Name}-eks-cluster-sg"
      "kubernetes.io:cluster:${var.tags.Name}-eks-cluster" = "owned"
    }
  )
}

# Cluster Security Group Rules
resource "aws_security_group_rule" "cluster_inbound" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "bastion_inbound" {
  description              = "Allow bastion host to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = data.aws_security_group.bastion.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster_outbound" {
  description              = "Allow cluster API Server to communicate with the worker nodes"
  from_port                = 1024
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 65535
  type                     = "egress"
}

# Node Security Group
resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.tags.Name}-eks-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = data.aws_vpc.vpc.id

  tags = merge(
    var.tags,
    {
      Name                                                 = "${var.tags.Name}-eks-node-sg"
      "kubernetes.io/cluster/${var.tags.Name}-eks-cluster" = "owned"
    }
  )
}

# Node Security Group Rules
resource "aws_security_group_rule" "node_to_node" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 65535
  type                     = "ingress"
}

# Allow nodes to communicate with control plane
resource "aws_security_group_rule" "node_to_cluster" {
  description              = "Allow nodes to communicate with control plane"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster_to_node" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_outbound" {
  description       = "Allow all outbound traffic"
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes_sg.id
  cidr_blocks       = ["0.0.0.0/0"]
  to_port           = 0
  type              = "egress"
}

resource "aws_security_group_rule" "node_kubelet" {
  description              = "Allow kubelet API"
  from_port                = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  to_port                  = 10250
  type                     = "ingress"
}


# Create Launch Template
resource "aws_launch_template" "eks_nodes_tpl" {
  name_prefix            = "${var.tags.Name}-node-tpl"
  description            = "EKS node group launch template"
  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.eks.disk_size
      volume_type           = "gp3"
      iops                  = 3000
      encrypted             = true
      kms_key_id            = aws_kms_key.eks_key.arn
      delete_on_termination = true
    }
  }
  image_id      = data.aws_ami.eks_node_img.id
  ebs_optimized = true
  instance_type = var.eks.instance_type

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.eks_nodes_sg.id]
  }

  # User data to bootstrap the node

  user_data = base64encode(<<-EOF
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.eks_cluster.name}
        apiServerEndpoint: ${aws_eks_cluster.eks_cluster.endpoint}
        certificateAuthority: ${aws_eks_cluster.eks_cluster.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.eks_cluster.kubernetes_network_config[0].service_ipv4_cidr}
      kubelet:
        config:
          nodeLabels:
            eks.amazonaws.com/nodegroup: ${var.tags.Name}-node-group
            eks.amazonaws.com/nodegroup-image: ${data.aws_ami.eks_node_img.id}

    --BOUNDARY--
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name                                                     = "${var.tags.Name}-node"
        "kubernetes.io:cluster:${var.tags.Name}-eks-cluster"     = "owned"
        "k8s.io:cluster-autoscaler:enabled"                      = "true"
        "k8s.io:cluster-autoscaler:${var.tags.Name}-eks-cluster" = "owned"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      {
        Name                                                 = "${var.tags.Name}-node-volume"
        "kubernetes.io:cluster:${var.tags.Name}-eks-cluster" = "owned"
      }
    )
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(
      var.tags,
      {
        Name                                                 = "${var.tags.Name}-node-network-interface"
        "kubernetes.io:cluster:${var.tags.Name}-eks-cluster" = "owned"
      }
    )
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

## Authentication from Bastion
resource "aws_eks_access_entry" "bastion" {
  cluster_name      = aws_eks_cluster.eks_cluster.name
  principal_arn     = data.aws_iam_instance_profile.bastion_arn.role_arn
  type              = "STANDARD"
  kubernetes_groups = ["masters"]
  user_name         = "admin"
}

# EKS access entries for additional IAM roles
resource "aws_eks_access_entry" "this" {
  count = length(var.eks_access_entry_points) > 0 ? length(var.eks_access_entry_points) : 0

  cluster_name      = aws_eks_cluster.eks_cluster.name
  principal_arn     = var.eks_access_entry_points[count.index].principal_arn
  type              = var.eks_access_entry_points[count.index].type
  kubernetes_groups = var.eks_access_entry_points[count.index].kubernetes_groups
  user_name         = var.eks_access_entry_points[count.index].user_name
}

# Update the kubernetes provider configuration
provider "kubernetes" {
  host                   = aws_eks_cluster.eks_cluster.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name]
    command     = "aws"
  }
}


# Add EKS access policy association
resource "aws_eks_access_policy_association" "this" {
  count = length(var.eks_access_policy_assoc) > 0 ? length(var.eks_access_policy_assoc) : 0

  cluster_name  = aws_eks_cluster.eks_cluster.name
  policy_arn    = var.eks_access_policy_assoc[count.index].eks_policy_arn
  principal_arn = var.eks_access_policy_assoc[count.index].principal_arn

  access_scope {
    type = "cluster"
  }
}


resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  force = true

  data = {
    mapRoles = yamlencode(
      concat(
        [
          {
            rolearn  = aws_iam_role.node.arn
            username = "system:node:{{EC2PrivateDNSName}}"
            groups   = ["system:bootstrappers", "system:nodes"]
          },
          {
            rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.env.account_name}/${var.env.account_name}-bastion"
            username = "admin"
            groups   = ["system:masters"]
          }
        ],
        [
          for entry in var.eks_access_entry_points : {
            rolearn  = entry.principal_arn
            username = entry.user_name
            groups   = entry.kubernetes_groups
          }
        ]
      )
    )
  }

  depends_on = [
    aws_eks_access_policy_association.this,
    aws_eks_cluster.eks_cluster,
    aws_eks_node_group.eks_node,
    # null_resource.wait_for_cluster
  ]
}

resource "kubernetes_cluster_role_binding" "admin_user" {
  metadata {
    name = "admin-user-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "User"
    name      = "admin"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [
    aws_eks_cluster.eks_cluster,
    kubernetes_config_map_v1_data.aws_auth
  ]
}

resource "kubernetes_cluster_role_binding" "power_user" {
  metadata {
    name = "PowerUser-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "User"
    name      = "admin-role"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [
    aws_eks_cluster.eks_cluster,
    kubernetes_config_map_v1_data.aws_auth
  ]
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
    exec =  {
      api_version = "client.authentication.k8s.io/v1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name]
      command     = "aws"
    }
  }
}

# Helm release for Metrics Server
resource "helm_release" "metrics_server" {
  count       = var.eks.metrics_server_enabled ? 1 : 0
  name        = "metrics-server"
  repository  = "https://kubernetes-sigs.github.io/metrics-server/"
  chart       = "metrics-server"
  namespace   = "kube-system"

  set = [
    {
      name  = "replicas"
      value = var.eks.metrics_server_pod_count  # Adjust for high availability if needed
    },
    {
      name  = "args"
      value = "{--kubelet-insecure-tls}"  # Often required for EKS to bypass kubelet certificate verification
    }
  ]
}