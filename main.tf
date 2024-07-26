provider "aws" {
  region = "us-east-1"
}

data "aws_region" "current" {}

variable "vpc_cidr" {
  default = "10.10.0.0/16"
}

variable "availability_zones" {
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnets" {
  default = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnets" {
  default = ["10.10.3.0/24", "10.10.4.0/24"]
}

variable "db_subnets" {
  default = ["10.10.5.0/24", "10.10.6.0/24"]
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  tags = {
    Name = "RxVPC"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "RxIGW"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = element(var.public_subnets, count.index)
  availability_zone       = element(var.availability_zones, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "RxPublicSubnet"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.private_subnets, count.index)
  availability_zone = element(var.availability_zones, count.index)

  tags = {
    Name = "RxPrivateSubnet"
  }
}

resource "aws_subnet" "db" {
  count             = length(var.db_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.db_subnets, count.index)
  availability_zone = element(var.availability_zones, count.index)

  tags = {
    Name = "RxDBSubnet"
  }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnets)
  allocation_id = aws_eip.main[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "RxNATGateway"
  }
}

resource "aws_eip" "main" {
  count = length(var.public_subnets)
  vpc   = true

  tags = {
    Name = "RxEIP"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "RxRTPublic"
  }
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.main.*.id, count.index)
  }

  tags = {
    Name = "RxRTPrivate"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_instance" "bastion" {
  ami                         = "ami-03972092c42e8c0ca"
  instance_type               = "t2.micro"
  subnet_id                   = element(aws_subnet.public.*.id, 0)
  vpc_security_group_ids      = [aws_security_group.public_sg.id]
  key_name                    = aws_key_pair.generated_key_bastion.key_name
  associate_public_ip_address = true
  monitoring                  = true

  root_block_device {
    volume_size = 8
  }

  tags = {
    Name = "RxBastionServer"
  }
}

resource "tls_private_key" "keypair_bastion" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "generated_key_bastion" {
  key_name   = "RxBastionServerKey"
  public_key = tls_private_key.keypair_bastion.public_key_openssh

  tags = {
    Name = "RxBastionServerKey"
  }
}

resource "local_file" "private_key_bastion" {
  content         = tls_private_key.keypair_bastion.private_key_pem
  filename        = "${path.module}/RxBastionServerKey.pem"
  file_permission = "0600"
}

resource "aws_security_group" "public_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "RxPublicBastionSG"
  }
}

resource "aws_efs_file_system" "efs" {
  creation_token = "rx-efs"
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags = {
    Name = "RxEFS"
  }
}

resource "aws_efs_mount_target" "private_mount_targets" {
  count           = length(var.private_subnets)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = element(aws_subnet.private.*.id, count.index)
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_security_group" "efs_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "RxEFSSG"
  }
}
resource "aws_instance" "private_instance" {
  ami                         = "ami-03972092c42e8c0ca"
  instance_type               = "t2.micro"
  subnet_id                   = element(aws_subnet.private.*.id, 0)
  vpc_security_group_ids      = [aws_security_group.private_sg.id]
  key_name                    = aws_key_pair.generated_key_private.key_name
  associate_public_ip_address = false
  monitoring                  = true

  root_block_device {
    volume_size = 8
  }

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    file_system_id  = aws_efs_file_system.efs.id
    efs_mount_point = "/mnt/efs"
    region          = data.aws_region.current.name
  })

  tags = {
    Name = "RxPrivateInstance"
  }
}

resource "tls_private_key" "keypair_private" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "generated_key_private" {
  key_name   = "RxPrivateInstanceKey"
  public_key = tls_private_key.keypair_private.public_key_openssh

  tags = {
    Name = "RxPrivateInstanceKey"
  }
}

resource "local_file" "private_key_private" {
  content         = tls_private_key.keypair_private.private_key_pem
  filename        = "${path.module}/RxPrivateInstanceKey.pem"
  file_permission = "0600"
}

resource "aws_security_group" "private_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "RxPrivateInstanceSG"
  }
}
/*
resource "aws_db_instance" "master" {
  identifier                 = "rxdbmaster"
  allocated_storage          = 20
  apply_immediately          = false
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = false
  delete_automated_backups   = true
  engine                     = "mysql"
  engine_version             = "8.0.35"
  instance_class             = "db.t3.micro"
  db_subnet_group_name       = aws_db_subnet_group.db_subnet_group.name
  multi_az                   = true
  publicly_accessible        = false
  vpc_security_group_ids     = [aws_security_group.db_sg.id]
  username                   = "admin"
  password                   = "admin123"
  skip_final_snapshot        = true
  monitoring_interval        = 0
  backup_retention_period    = 7
  backup_window              = "01:00-04:00"
  maintenance_window         = "sun:04:30-sun:06:30"
  #performance_insights_enabled          = true
  #performance_insights_retention_period = 7

  tags = {
    Name = "RxDBMaster"
  }
}

resource "aws_db_subnet_group" "db_subnet_group" {
  subnet_ids = aws_subnet.db[*].id

  tags = {
    Name = "RxDBSubnetGroup"
  }
}
*/
resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "RxDBSG"
  }
}

resource "aws_security_group_rule" "allow_private_instance_to_db" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.private_sg.id
}


output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = aws_subnet.public[*].id
}

output "private_subnets" {
  value = aws_subnet.private[*].id
}

output "db_subnets" {
  value = aws_subnet.db[*].id
}

output "private_instance_private_ip" {
  value = aws_instance.private_instance.private_ip
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}