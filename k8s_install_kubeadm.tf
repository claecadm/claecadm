# export AWS_ACCESS_KEY_ID=""
# export AWS_SECRET_ACCESS_KEY=""
# ssh user is ubuntu

/*====
Variables
======*/
variable "region" {
  description = "Region that the instances will be created"
  default     = "us-east-1"
}

variable "kubeadm-vm-quantity" {
  description = "Quantity of kubeadm nodes"
  type        = number
  default     = 3
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
    description = "outside traffik access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "80"
    }, {
    description = "outside traffik access"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "443"
    }, {
    description = "outside nodeport"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "30080"
    }, {
    description = "outside nodeport"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "30081"
  }]
}

locals {
  custom-data-client = <<CUSTOM_DATA
#!/bin/bash
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

data "aws_ami" "ubuntu" {
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners      = ["099720109477"]
  most_recent = true
}

resource "aws_instance" "kubeadm-vm" {
  count                       = var.kubeadm-vm-quantity
  ami                         = data.aws_ami.ubuntu.id
  associate_public_ip_address = true
  #instance_type               = "t2.micro"
  instance_type               = "t3a.medium"
  key_name         = aws_key_pair.deployer.id
  user_data_base64 = base64encode(local.custom-data-client)
  tags = {
    Name = "kubeadm-vm-${count.index}"
    Env  = "kubeadm"
  }
}

resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
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

output "kubeadm-vm_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.kubeadm-vm.*.public_ip
}