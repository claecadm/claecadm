# export AWS_ACCESS_KEY_ID=""
# export AWS_SECRET_ACCESS_KEY=""
# ssh user is ec2-user

/*====
Variables
======*/
variable "region" {
  description = "Region that the instances will be created"
  default     = "us-east-1"
}

variable "docker-host-quantity" {
  description = "Quantity of vm nodes"
  type        = number
  default     = 1
}

locals {
  my-ssh-pubkey = file("~/.ssh/id_rsa.pub")
}

locals {
  allow-ports = [{
    description = "Default"
    protocol    = "-1"
    cidrblk     = []
    self        = true
    port        = "0"
    }, {
    description = "outside ssh access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "22"
    }, {
    description = "outside http access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "8080"
    }, {
    description = "outside http access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "8081"
    }, {
    description = "outside http access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "8082"
    }, {
    description = "outside http access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "8083"
    }, {        
    description = "outside http access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "80"
    }, {
    description = "outside https access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "443"
  }]
}

locals {
  custom-data-docker = <<CUSTOM_DATA
#!/bin/bash
yum -y install wget curl jq openssl11
yum -y install docker && systemctl start docker && systemctl enable docker
yum -y install socat conntrack ipset
sysctl -w net.ipv4.conf.all.forwarding=1
wget https://github.com/docker/compose/releases/download/1.28.5/docker-compose-Linux-x86_64
sudo mv docker-compose-Linux-x86_64 /usr/local/bin/docker-compose
sudo chmod 755 /usr/local/bin/docker-compose
CUSTOM_DATA
}

/*====
Resources
======*/

provider "aws" {
  region = var.region
}

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = local.my-ssh-pubkey
}

data "aws_ami" "amazon-linux-2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
  #  filter {
  #      name   = "name"
  #      values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  #  }
  #  filter {
  #      name = "virtualization-type"
  #      values = ["hvm"]
  #  }
  #  owners = ["099720109477"]
}

resource "aws_instance" "docker-host" {
  count                       = var.docker-host-quantity
  ami                         = data.aws_ami.amazon-linux-2.id
  subnet_id = aws_default_subnet.region_a.id
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  #instance_type               = "t2.medium"
  key_name                    = aws_key_pair.deployer.id
  user_data_base64            = base64encode(local.custom-data-docker)
  tags = {
    Name = "docker-host-${count.index}"
    Env  = "docker"
  }
}

resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }
}

resource "aws_default_subnet" "region_a" {
  availability_zone = "${var.region}a"

  tags = {
    Name = "Default subnet for ${var.region}a"
  }
}

resource "aws_default_subnet" "region_b" {
  availability_zone = "${var.region}b"

  tags = {
    Name = "Default subnet for ${var.region}b"
  }
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_default_vpc.default.id

  dynamic "ingress" {
    for_each = local.allow-ports
    iterator = each
    content {
      description      = each.value.description
      protocol         = each.value.protocol
      self             = each.value.self
      from_port        = each.value.port
      to_port          = each.value.port
      cidr_blocks      = each.value.cidrblk
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
    }
  }

  egress = [
    {
      description      = "Default"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]
}

output "docker-host_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.docker-host.*.public_ip
}


#########
#  ALB  #
#########

/*
resource "aws_lb" "docker" {
  name               = "docker-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups = [aws_default_security_group.default.id]
  subnets = [aws_default_subnet.region_a.id,aws_default_subnet.region_b.id]

  enable_deletion_protection = false

  tags = {
    Env  = "docker"
  }
}

resource "aws_lb_listener" "docker" {
  load_balancer_arn = aws_lb.docker.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.docker.arn
  }
}

resource "aws_lb_listener_rule" "docker" {
  listener_arn = aws_lb_listener.docker.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.docker.arn
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}

resource "aws_lb_target_group" "docker" {  
  name     = "docker-tg"
  port     = 8080
  protocol = "HTTP"  
  vpc_id   = aws_default_vpc.default.id
  tags = {    
    Env  = "docker"
  }    
  health_check {    
    healthy_threshold   = 3    
    unhealthy_threshold = 10    
    timeout             = 5    
    interval            = 10    
    path                = "/"
    port                = 8080  
  }
}

resource "aws_lb_target_group_attachment" "docker" {
  count = length(aws_instance.docker-host)
  target_group_arn = aws_lb_target_group.docker.arn
  target_id        = aws_instance.docker-host[count.index].id
  port             = 8080
}

data "aws_lb" "docker" {
  arn  = aws_lb.docker.arn
  name = aws_lb.docker.name
}

output "docker-lb_dnsname" {
  description = "Public Name of Docker LB"
  value       = data.aws_lb.docker.dns_name
}
*/