output "vpc" {
  value = {
    id : aws_vpc.this.id
    arn : aws_vpc.this.arn
    enable_dns_support : aws_vpc.this.enable_dns_support
    enable_dns_hostnames : aws_vpc.this.enable_dns_hostnames
    ipv4_cidr_block : aws_vpc.this.cidr_block
    ipv6_cidr_block : aws_vpc.this.ipv6_cidr_block
    owner_id : aws_vpc.this.owner_id
    igw_id : join("", aws_internet_gateway.this[*].id)
    eigw_id : join("", aws_egress_only_internet_gateway.this[*].id)
    vpgw_id : aws_vpn_gateway.this.id
  }
}

output "public_subnets" {
  value = {
    id : aws_subnet.public[*].id
    arn : aws_subnet.public[*].arn
    ipv4_cidr_block : aws_subnet.public[*].cidr_block
    ipv6_cidr_block : aws_subnet.public[*].ipv6_cidr_block
    availability_zone : aws_subnet.public[*].availability_zone
  }
}

output "private_subnets" {
  value = {
    id : aws_subnet.private[*].id
    arn : aws_subnet.private[*].arn
    ipv4_cidr_block : aws_subnet.private[*].cidr_block
    ipv6_cidr_block : aws_subnet.private[*].ipv6_cidr_block
    availability_zone : aws_subnet.private[*].availability_zone
  }
}

output "nat_gateways" {
  value = {
    id : aws_nat_gateway.this[*].id
    public_ip : aws_nat_gateway.this[*].public_ip
  }
}

output "s3_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.s3.id
    prefix_list_id : aws_vpc_endpoint.s3.prefix_list_id
  }
}

output "dynamodb_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.dynamodb.id
    prefix_list_id : aws_vpc_endpoint.dynamodb.prefix_list_id
  }
}

output "api_gw_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.api_gw.id
    prefix_list_id : aws_vpc_endpoint.api_gw.prefix_list_id
  }
}

output "sns_vpc_endpoint" {
  value = {
    id : aws_vpc_endpoint.sns.id
    prefix_list_id : aws_vpc_endpoint.sns.prefix_list_id
  }
}