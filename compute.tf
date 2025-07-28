data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
locals {
  cluster_name = "k3s-prod"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "k3s_key" {
  key_name   = "my-k3s-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "k3s_sg" {
  name        = "k3s-sg"
  description = "Allow traffic for K3s cluster"
  vpc_id      = aws_vpc.main.id

  # Ingress from the public internet
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "K3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Ingress for internal communication
  ingress {
    description = "Allow all traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Egress to internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k3s-sg" }
}

# --- IAM Resources for the Master Node for Cluster Autoscaler ---
resource "aws_iam_role" "master_role" {
  name = "k3s-master-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "cluster_autoscaler_policy" {
  name        = "k3s-cluster-autoscaler-policy"
  description = "Policy for K3s cluster autoscaler"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "ec2:DescribeLaunchTemplateVersions"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:autoscaling:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "master_autoscaler_attach" {
  role       = aws_iam_role.master_role.name
  policy_arn = aws_iam_policy.cluster_autoscaler_policy.arn
}

resource "aws_iam_instance_profile" "master_profile" {
  name = "k3s-master-profile"
  role = aws_iam_role.master_role.name
}


# The single master node for now
resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t4g.medium"
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.k3s_key.key_name
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.master_profile.name

  root_block_device {
    volume_size = 50
  }

  tags = {
    Name = "k3s-master"
    Role = "k3s-master"
  }
}

resource "aws_eip" "master_eip" {
  instance = aws_instance.master.id
  domain   = "vpc"
}


# --- Resources for the Auto Scaling Worker Nodes ---

# IAM Role for worker nodes
resource "aws_iam_role" "worker_role" {
  name = "k3s-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "k3s-worker-policy"
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["secretsmanager:GetSecretValue", "ec2:DescribeInstances"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "k3s-worker-profile"
  role = aws_iam_role.worker_role.name
}

# Launch Template for Auto Scaling nodes
resource "aws_launch_template" "worker_template" {
  name_prefix            = "k3s-worker-"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = "t4g.medium"
  key_name               = aws_key_pair.k3s_key.key_name
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.worker_profile.name
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 40
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    cloud-init status --wait
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
       echo "Waiting for apt lock..."
       sleep 5
    done

    # Retry apt commands to make them resilient
    for i in {1..5}; do
      apt-get update && apt-get install -y awscli && break
      echo "apt-get failed, retrying..."
      sleep 10
    done
    apt-get update
    apt-get install -y awscli
    MASTER_IP=$(aws ec2 describe-instances --region ${data.aws_region.current.name} --filters "Name=tag:Role,Values=k3s-master" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
    K3S_TOKEN=$(aws secretsmanager get-secret-value --region ${data.aws_region.current.name} --secret-id k3s-join-token --query SecretString --output text)
    curl -sfL https://get.k3s.io | K3S_URL=https://$${MASTER_IP}:6443 K3S_TOKEN=$${K3S_TOKEN} sh -s - agent'
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "k3s-worker"
      Role = "k3s-worker"
    }
  }
}

# Auto Scaling Group 
resource "aws_autoscaling_group" "worker_asg" {
  name                = "k3s-worker-asg"
  min_size            = 1
  max_size            = 5
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.private.id]

  launch_template {
    id      = aws_launch_template.worker_template.id
    version = "$Latest"
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${local.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }
}
