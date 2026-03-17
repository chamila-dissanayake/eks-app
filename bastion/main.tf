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
  role             = "bastion"
  short_identifier = format("%s-%s", var.tags.Name, local.role)
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "bastion_zone" {
  count = length(var.env.domain) > 0 ? 1 : 0
  name  = var.env.domain
}

data "aws_subnet" "public" {
  filter {
    name   = "tag:Name"
    values = ["${var.tags.Name}-public-0"]
  }
}

data "aws_ami" "bastion" {
  most_recent = true
  owners      = var.ami_owners
  filter {
    name   = "name"
    values = ["${var.bastion.ami_name_filter}*"]
  }
  filter {
    name   = "architecture"
    values = ["${var.bastion.instance_arch}"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

data "aws_kms_key" "ebs" {
  key_id = "alias/${var.tags.Name}-ebs"
}

resource "aws_security_group" "bastion" {
  name        = local.short_identifier
  description = "${local.short_identifier} security group"
  vpc_id      = data.aws_subnet.public.vpc_id

  lifecycle {
    ignore_changes = [tags]
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", local.short_identifier) }),
  )
}


resource "aws_security_group_rule" "egress" {
  type              = "egress"
  protocol          = "-1"
  to_port           = 0
  from_port         = 0
  description       = "Allow all traffic out to any destination"
  security_group_id = aws_security_group.bastion.id
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

resource "aws_security_group_rule" "ssh_in" {
  count             = length(var.ssh_ingress_cidr) > 0 || length(var.ipv6_ingress_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  protocol          = "tcp"
  to_port           = 22
  from_port         = 22
  description       = "Allow SSH from select external addresses"
  security_group_id = aws_security_group.bastion.id
  cidr_blocks       = var.ssh_ingress_cidr
  ipv6_cidr_blocks  = var.ipv6_ingress_cidrs
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "role" {
  name               = local.short_identifier
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  path               = "/"

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-role", local.short_identifier) }),
  )
}

resource "aws_iam_role_policy_attachment" "aws_ssm" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "custom_policy" {
  name        = "${local.short_identifier}-custom-policy"
  path        = "/"
  description = "IAM Policy for ${var.tags.environment}-bastion custom permissions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "eks:Describe*",
        ]
        Effect   = "Allow"
        Resource = "arn:aws:eks:${var.env.region}:${data.aws_caller_identity.current.account_id}:cluster/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetChange",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone"
        ]
        Resource = [
          "arn:aws:route53:::hostedzone/${data.aws_route53_zone.bastion_zone[0].zone_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "custom_policy_attach" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.custom_policy.arn
}

resource "aws_iam_instance_profile" "bastion" {
  name = local.short_identifier
  role = aws_iam_role.role.name
}

data "template_file" "ssh_key" {
  count    = length(data.tls_public_key.ssh)
  template = file("${path.module}/user-data/ssh_fwd_key.tmpl")

  vars = {
    forward_only_sshkey = data.tls_public_key.ssh[count.index].public_key_openssh
  }
}

data "tls_public_key" "ssh" {
  count           = length(var.forward_only_sshkey) > 0 ? 1 : 0
  private_key_pem = file(pathexpand(var.forward_only_sshkey))
}


data "template_cloudinit_config" "bastion" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/user-data/bootstrap.sh",
      {
        environment       = var.tags["environment"],
        role              = local.role,
        region            = var.env.region,
        eks_cluster       = var.eks.cluster_name,
        namespace         = var.eks.namespace,
        access_key_id     = "",
        secret_access_key = ""
        domain            = var.env.domain,
        hosted_zone_id    = length(data.aws_route53_zone.bastion_zone[0].zone_id) > 0 ? data.aws_route53_zone.bastion_zone[0].zone_id : "",
        dns_record_name   = length(data.aws_route53_zone.bastion_zone[0].zone_id) > 0 ? format("%s.%s", local.role, var.env.domain) : "",
        ttl               = var.bastion.dns_record_ttl
    })
  }

  # Render this as a distinct cloud-config part so we can account for
  # cases where a forward-only ssh key isn't configured
  part {
    content_type = "text/cloud-config"
    content      = join("", data.template_file.ssh_key[*].rendered)
    #merge_type   = "list(append)+dict(recurse_array)+str()"
  }
}


resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.bastion.image_id
  instance_type               = var.bastion.instance_type
  key_name                    = var.bastion.key_name
  subnet_id                   = data.aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = var.bastion.use_eip ? false : true
  iam_instance_profile        = aws_iam_role.role.name
  user_data_base64            = data.template_cloudinit_config.bastion.rendered
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = var.bastion["root_vol_type"]
    volume_size           = var.bastion["root_vol_size"]
    delete_on_termination = var.bastion["root_vol_del_on_term"]
    encrypted             = true
    kms_key_id            = data.aws_kms_key.ebs.key_id
    tags = merge(
      var.tags,
      tomap({ "Name" = format("%s", "${local.short_identifier}") })
    )
  }


  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", local.short_identifier) })
  )
}

resource "aws_eip" "bastion" {
  #count    = var.bastion.use_eip ? 1 : 0
  count    = var.bastion.use_eip ? 1 : 0
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", local.short_identifier) }),
  )
}

resource "aws_eip_association" "bastion" {
  #count         = length(aws_eip.bastion) != "" ? 0 : 0
  count         = var.bastion.use_eip ? 1 : 0
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion[count.index].id
}

resource "aws_shield_protection" "ngw_eips_shield" {
  #count        = length(aws_eip.bastion) != "" ? 1 : 0
  count = var.bastion.use_eip ? 1 : 0
  name  = format("%s-bastion-eip", local.short_identifier)
  #resource_arn = "arn:aws:ec2:${var.env.region}:${data.aws_caller_identity.current.account_id}:eip-allocation/${aws_eip.bastion[count.index].id}"
  resource_arn = aws_eip.bastion[count.index].arn

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-eip-shield", local.short_identifier) })
  )
}

data "aws_route53_zone" "this" {
  name = var.env.domain
}

resource "aws_route53_record" "bastion_ipv4" {
  count           = length(data.aws_route53_zone.this) != "" ? 1 : 0
  name            = "${local.role}.${var.env.domain}"
  type            = "A"
  ttl             = var.bastion.dns_record_ttl
  zone_id         = data.aws_route53_zone.this.zone_id
  records         = [length(aws_eip.bastion) > 0 ? join("", aws_eip.bastion[*].public_ip) : aws_instance.bastion.public_ip]
  allow_overwrite = true
}

// values for the count attribute must be fully resolved during plan-time, which means it can't rely on values
// from the subnet data source or bastion ec2 instance available after they are created.  To keep the logic somewhat
// simple, we'll create an IPv6 Route53 record if a zone was provided and we enabled IPv6 access via the security group
resource "aws_route53_record" "bastion_ipv6" {
  //  count   = length(var.ipv6_ingress_cidrs) != "" && length(data.aws_route53_zone.z) != "" ? length(data.aws_route53_zone.z) : 0
  count           = length(var.ipv6_ingress_cidrs) != "" && length(data.aws_route53_zone.this) != "" ? 0 : 0
  name            = aws_route53_record.bastion_ipv4[count.index].name
  type            = "AAAA"
  ttl             = aws_route53_record.bastion_ipv4[count.index].ttl
  zone_id         = data.aws_route53_zone.this[count.index].zone_id
  records         = aws_instance.bastion.ipv6_addresses
  allow_overwrite = true
}

##Tagging network interface once created.
resource "aws_ec2_tag" "bastion_node_eni" {
  resource_id = aws_instance.bastion.primary_network_interface_id
  for_each    = var.tags
  key         = each.key
  value       = each.value
}