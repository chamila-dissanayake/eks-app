output "ami" {
  value = {
    id   = aws_instance.bastion.ami
    name = data.aws_ami.bastion.name
  }
}
output "security_group" {
  value = {
    arn  = aws_security_group.bastion.arn
    id   = aws_security_group.bastion.id
    name = aws_security_group.bastion.name
  }
}
output "Bastion_instance" {
  value = {
    id          = aws_instance.bastion.id
    private_ip  = aws_instance.bastion.private_ip
    public_ip   = aws_instance.bastion.public_ip
    public_dns  = aws_route53_record.bastion_ipv4[0].name
  }
}