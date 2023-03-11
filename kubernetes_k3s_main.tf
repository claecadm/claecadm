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

variable "k3s-client-quantity" {
  description = "Quantity of k3s worker nodes"
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
    description = "proxy port-forward"
    protocol    = "tcp"
    cidrblk     = ["0.0.0.0/0"]
    self        = false
    port        = "8000"
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
  k3s_token = base64encode("Token super secreto lab aws")
}

locals {
  custom-data-server = <<CUSTOM_DATA
#!/bin/bash
curl -sfL https://get.k3s.io | \
  K3S_TOKEN=${local.k3s_token} \
  sh -s - server \
  --node-taint CriticalAddonsOnly=true:NoExecute
sleep 5
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
CUSTOM_DATA
}

locals {
  custom-data-client = <<CUSTOM_DATA
#!/bin/bash
curl -sfL https://get.k3s.io | K3S_URL=https://${aws_instance.k3s-server.private_ip}:6443 K3S_TOKEN=${local.k3s_token} sh -
yum install -y iscsi-initiator-utils.x86_64 libiscsi.x86_64 libiscsi-utils.x86_64 nfs-utils.x86_64
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
}

resource "aws_instance" "k3s-server" {
  subnet_id = aws_default_subnet.region_a.id
  ami                         = data.aws_ami.amazon-linux-2.id
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  #instance_type               = "t3a.medium"
  key_name                    = aws_key_pair.deployer.id
  user_data_base64            = base64encode(local.custom-data-server)
  tags = {
    Name = "k3s-server"
    Env  = "k3s"
  }
}

resource "aws_instance" "k3s-client" {
  count                       = var.k3s-client-quantity
  depends_on                  = [aws_instance.k3s-server]
  subnet_id = aws_default_subnet.region_a.id
  ami                         = data.aws_ami.amazon-linux-2.id
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  #instance_type               = "t3a.medium"
  key_name                    = aws_key_pair.deployer.id
  user_data_base64            = base64encode(local.custom-data-client)
  root_block_device {
    volume_size           = "30"
    volume_type           = "gp2"
    delete_on_termination = true
  }
  tags = {
    Name = "k3s-client-${count.index}"
    Env  = "k3s"
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

output "k3s-server_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.k3s-server.public_ip
}

output "k3s-client_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.k3s-client.*.public_ip
}


#########
#  NLB  #
#########
/*
resource "aws_eip" "lb-region_a" {
  vpc      = true
  tags = {
    Env  = "k3s"
  }
}

#resource "aws_eip" "lb-region_b" {
#  vpc      = true
#  tags = {
#    Env  = "k3s"
#  }
#}

resource "aws_lb" "k3s" {
  name               = "k3s-lb"
  internal           = false
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_default_subnet.region_a.id
    allocation_id = aws_eip.lb-region_a.id
  }

  subnet_mapping {
    subnet_id     = aws_default_subnet.region_b.id
    #allocation_id = aws_eip.lb-region_b.id
  }

  enable_deletion_protection = false

  tags = {
    Env  = "k3s"
  }
}

resource "aws_lb_listener" "k3s" {
  load_balancer_arn = aws_lb.k3s.arn
  port              = "80"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k3s.arn
  }
}

resource "aws_lb_target_group" "k3s" {  
  name     = "k3s-tg"
  port     = 80
  protocol = "TCP"  
  vpc_id   = aws_default_vpc.default.id
  tags = {    
    Env  = "k3s"
  }    
}

resource "aws_lb_target_group_attachment" "k3s" {
  count = length(aws_instance.k3s-client)
  target_group_arn = aws_lb_target_group.k3s.arn
  target_id        = aws_instance.k3s-client[count.index].id
  port             = 80
}

data "aws_eip" "lb-region_a" {
  id = aws_eip.lb-region_a.id
}

output "k3s-lb-region_a" {
  description = "Public IP of k3s LB region_a"
  value       = data.aws_eip.lb-region_a.public_ip
}
*/