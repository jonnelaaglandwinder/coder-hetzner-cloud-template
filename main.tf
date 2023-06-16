terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.8.3"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.40.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "coder" {
  feature_use_managed_variables = true
}

variable "hcloud_token" {
  description = <<EOF
Coder requires a Hetzner Cloud token to provision workspaces.
EOF
  sensitive   = true
  validation {
    condition     = length(var.hcloud_token) == 64
    error_message = "Please provide a valid Hetzner Cloud API token."
  }
}

data "coder_workspace" "me" {
}

data "coder_parameter" "volume_size" {
  name = "volume_size"
  display_name = "Volume Size"
  description = "The size of the volume in GB."
  type = "number"
  default = 10
  mutable = false

  validation {
    min = 10
    max = 1000
  }
}

data "coder_parameter" "code_server" {
  name = "code_server"
  display_name = "Code Server"
  description = "Code Server is a web-based IDE based on Visual Studio Code."
  type = "bool"
  default = true
  mutable = true
}

data "coder_parameter" "datacenter" {
  name = "datacenter"
  display_name = "Datacenter"
  description = "The datacenter where your workspace will be provisioned."
  type = "string"
  mutable = true

  option {
    name = "Nuremberg"
    value = "nbg1"
  }

  option {
    name = "Falkenstein"
    value = "fsn1"
  }

  option {
    name = "Helsinki"
    value = "hel1"
  }

  default = "nbg1"
}

data "coder_parameter" "instance_type" {
  name = "instance_type"
  display_name = "Instance Type"
  description = "The instance type of your workspace."
  type = "string"
  mutable = true

  option {
    name = "CX11"
    value = "cx11"
  }

  option {
    name = "CX21"
    value = "cx21"
  }

  option {
    name = "CX31"
    value = "cx31"
  }

  option {
    name = "CX41"
    value = "cx41"
  }

  option {
    name = "CX51"
    value = "cx51"
  }

  default = "cx11"
}

data "coder_parameter" "instance_os" {
  name = "instance_os"
  display_name = "Instance OS"
  description = "The instance type of your workspace."
  type = "string"
  mutable = true

  option {
    name = "Ubuntu 22.04"
    value = "ubuntu-22.04"
  }

  option {
    name = "Ubuntu 20.04"
    value = "ubuntu-20.04"
  }

  option {
    name = "Ubuntu 18.04"
    value = "ubuntu-18.04"
  }

  option {
    name = "Debian 11"
    value = "debian-11"
  }

  option {
    name = "Debian 10"
    value = "debian-10"
  }

  default = "debian-11"
}

resource "coder_agent" "dev" {
  arch = "amd64"
  os   = "linux"
}

resource "coder_app" "code-server" {
  slug          = "code-server"
  count         = data.coder_parameter.code_server.value ? 1 : 0
  agent_id      = coder_agent.dev.id
  name          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:8080"
  relative_path = true
}

# Generate a dummy ssh key that is not accessible so Hetzner cloud does not spam the admin with emails.
resource "tls_private_key" "rsa_4096" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "hcloud_ssh_key" "root" {
  name       = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
  public_key = tls_private_key.rsa_4096.public_key_openssh
}

resource "hcloud_server" "root" {
  count       = data.coder_workspace.me.start_count
  name        = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
  server_type = data.coder_parameter.instance_type.value
  location    = data.coder_parameter.datacenter.value
  image       = data.coder_parameter.instance_os.value
  ssh_keys    = [hcloud_ssh_key.root.id]
  user_data   = templatefile("cloud-config.yaml.tftpl", {
    username          = data.coder_workspace.me.owner
    volume_path       = "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.root.id}"
    init_script       = base64encode(coder_agent.dev.init_script)
    coder_agent_token = coder_agent.dev.token
    code_server_setup = data.coder_parameter.code_server.value
  })
}

resource "hcloud_volume" "root" {
  name         = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
  size         = data.coder_parameter.volume_size.value
  format       = "ext4"
  location     = data.coder_parameter.datacenter.value
}

resource "hcloud_volume_attachment" "root" {
  count     = data.coder_workspace.me.start_count
  volume_id = hcloud_volume.root.id
  server_id = hcloud_server.root[count.index].id
  automount = false
}

resource "hcloud_firewall" "root" {
  name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
  rule {
    direction = "in"
    protocol  = "icmp"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}

resource "hcloud_firewall_attachment" "root_fw_attach" {
    count = data.coder_workspace.me.start_count
    firewall_id = hcloud_firewall.root.id
    server_ids  = [hcloud_server.root[count.index].id]
}
