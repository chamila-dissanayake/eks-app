output "rds_cluster_id" {
  value = aws_rds_cluster.postgres.id
}

output "rds_cluster_endpoint" {
  value = aws_rds_cluster.postgres.endpoint
}

output "dns_reader" {
  value = aws_route53_record.reader.fqdn
}

output "rds_writer" {
  value = aws_route53_record.writer.fqdn
}

output "rds_subnet_group" {
  value = aws_db_subnet_group.db_subnet.id
}

output "rds_sgr" {
  value = aws_security_group.sg_db.id
}