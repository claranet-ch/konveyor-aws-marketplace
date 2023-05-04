packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "konveyor"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

source "amazon-ebs" "ubuntu" {
  ami_name      = "konveyor-base-image-${regex_replace(timestamp(), "[-:]", "")}"
  instance_type = "t3.medium"
  region        = var.aws_region
  profile       = var.aws_profile
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"
  ssh_clear_authorized_keys = true
}

build {
  name = "konveyor-base-image"

  sources = [
    "source.amazon-ebs.ubuntu"
  ]

  provisioner "file" {
    source      = "etc"
    destination = "/tmp"
  }

  provisioner "file" {
    source      = "opt/konveyor"
    destination = "/tmp"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/konveyor",
      "sudo cp -r /tmp/konveyor/* /opt/konveyor",
      "sudo cp /tmp/etc/apt/sources.list /etc/apt/sources.list",
      "sudo chmod a+x /opt/konveyor/*",
      "sudo ln -s /opt/konveyor/kubectl /usr/bin/kubectl",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install jq awscli -y",
      "sudo mv /tmp/etc/cron.daily/daily-db-backup /etc/cron.daily/",
      "chmod a+x /etc/cron.daily/daily-db-backup"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo reboot"
    ]
    expect_disconnect = true
  }

  post-processor "manifest" {
    output     = "out/manifest.json"
    strip_path = true
  }
}
