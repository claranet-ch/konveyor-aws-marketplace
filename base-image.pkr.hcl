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
    source      = "konveyor-db-backup"
    destination = "/tmp/konveyor-db-backup"
  }

  provisioner "file" {
    source      = "opt/konveyor"
    destination = "/tmp"
  }

  provisioner "file" {
    source      = "sources.list"
    destination = "/tmp/sources.list"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/konveyor",
      "sudo cp -r /tmp/konveyor/* /opt/konveyor",
      "sudo cp /tmp/sources.list /etc/apt/sources.list",
      "sudo chmod a+x /opt/konveyor/*",
      "sudo chmod a+x /opt/konveyor/cli/*",
      "sudo ln -s /opt/konveyor/kubectl /usr/bin/kubectl",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install jq awscli python3-pip -y",
      "sudo python3 -m pip install pyyaml pycryptodome",
      "sudo mv /tmp/konveyor-db-backup /etc/cron.d/",
      "sudo chown root:root /etc/cron.d/konveyor-db-backup",
      "sudo chmod 644 /etc/cron.d/konveyor-db-backup"
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
