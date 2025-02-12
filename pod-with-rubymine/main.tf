terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.4.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.12.1"
    }
  }
}

variable "disk_size" {
  description = "Disk size (__ GB)"
  default     = 10
}

variable "cpu" {
  description = "CPU (__ cores)"
  default     = 4
  validation {
    condition = contains([
      "4",
      "6",
      "8"
    ], var.cpu)
    error_message = "Invalid cpu!"   
}
}

variable "memory" {
  description = "Memory (__ GB)"
  default     = 4
  validation {
    condition = contains([
      "4",
      "6",
      "8",
      "10"
    ], var.memory)
    error_message = "Invalid memory!"  
}
}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default = ""
}

variable "image" {
  description = <<-EOF
  Container images

  EOF
  default = "marktmilligan/ruby-2-7-2:latest"
  validation {
    condition = contains([
      "marktmilligan/ruby-2-7-2:latest"
    ], var.image)
    error_message = "Invalid image!"   
}  
}

variable "extension" {
  description = "VS Code extension"
  default     = "rebornix.ruby"
  validation {
    condition = contains([
      "rebornix.ruby"
    ], var.extension)
    error_message = "Invalid VS Code extension!"  
}
}

variable "repo" {
  description = <<-EOF
  Code repository to clone with SSH
  e.g., sharkymark/rubyonrails.git
  EOF
  default = ""
}

variable "folder_path" {
  description = <<-EOF
 Folder to add to VS Code (optional)
e.g.,
/home/coder (default)
  EOF
  default = "/home/coder"
}

locals {
  jetbrains-releases = {
      "RubyMine 2022.2" = "2022.2"
      "RubyMine 2022.1.4" = "2022.1.4"
      "RubyMine 2021.3.3" = "2021.3.3"
      "RubyMine 2021.2.4" = "2021.2.4"
  }
}

variable "jetbrains-ide" {
  description = "JetBrains RubyMine IDE (oldest are Projector-tested by JetBrains s.r.o., Na Hrebenech II 1718/10, Prague, 14000, Czech Republic)"
  default     = "RubyMine 2022.2"
  validation {
    condition = contains([
      "RubyMine 2022.2",
      "RubyMine 2022.1.4",
      "RubyMine 2021.3.3",
      "RubyMine 2021.2.4"
    ], var.jetbrains-ide)
    error_message = "Invalid JetBrains IDE!"   
}
}

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
}

variable "workspaces_namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
  default     = "oss"
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

resource "coder_agent" "coder" {
  os   = "linux"
  arch = "amd64"
  dir = "/home/coder"
  startup_script = <<EOT
#!/bin/bash

# install code-server
curl -fsSL https://code-server.dev/install.sh | sh -s -- --version=4.5.1 2>&1 | tee ~/code-server.log
code-server --auth none --port 13337 2>&1 | tee -a ~/coder-server.log &

# use coder CLI to clone and install dotfiles
coder dotfiles -y ${var.dotfiles_uri} 2>&1 | tee dotfiles.log &

# install projector into /home/coder

PROJECTOR_BINARY=/home/coder/.local/bin/projector

if [ -f $PROJECTOR_BINARY ]; then
    echo 'projector has already been installed - check for update'
    /home/coder/.local/bin/projector self-update 2>&1 | tee projector.log
else
    echo 'installing projector'
    pip3 install projector-installer --user 2>&1 | tee projector.log
fi

echo 'access projector license terms'
/home/coder/.local/bin/projector --accept-license 2>&1 | tee -a projector.log

PROJECTOR_CONFIG_PATH=/home/coder/.projector/configs/rubymine

if [ -d "$PROJECTOR_CONFIG_PATH" ]; then
    echo 'projector has already been configured and the JetBrains IDE downloaded - skip step' 2>&1 | tee -a projector.log
else
    echo 'autoinstalling IDE and creating projector config folder'
    /home/coder/.local/bin/projector ide autoinstall --config-name "rubymine" --ide-name "${var.jetbrains-ide}" --hostname=localhost --port 8997 --use-separate-config --password coder 2>&1 | tee -a projector.log

    # delete the configuration's run.sh input parameters that check password tokens since tokens do not work with coder_app yet passed in the querystring

    grep -iv "HANDSHAKE_TOKEN" $PROJECTOR_CONFIG_PATH/run.sh > temp && mv temp $PROJECTOR_CONFIG_PATH/run.sh 2>&1 | tee -a projector.log
    chmod +x $PROJECTOR_CONFIG_PATH/run.sh 2>&1 | tee -a projector.log

    echo "creation of intellij configuration complete" 2>&1 | tee -a projector.log
    
fi

# install JetBrains projector packages required
sudo apt-get update && \
    DEBIAN_FRONTEND="noninteractive" sudo apt-get install -y \
    libxtst6 \
    libxrender1 \
    libfontconfig1 \
    libxi6 \
    libgtk-3-0 | tee -a projector.log


# start JetBrains projector-based IDE
/home/coder/.local/bin/projector run rubymine &

# clone repo
ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts
git clone --progress git@github.com:${var.repo} 2>&1 | tee repo-clone.log

# bundle Ruby gems
cd ~/rubyonrails
bundle install  
# start Rails server as daemon
rails s -p 3000 -b 0.0.0.0 -d

# install VS Code extensions into code-server
SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item code-server --install-extension ${var.extension} 2>&1 | tee vs-code-extension.log

EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.coder.id
  name          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:13337?folder=/home/coder"
  relative_path = true  
}

resource "coder_app" "rubymine" {
  agent_id      = coder_agent.coder.id
  name          = "${lookup(local.jetbrains-releases, var.jetbrains-ide)}"
  icon          = "/icon/rubymine.svg"
  url           = "http://localhost:8997/"
  relative_path = true
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory
  ]    
  metadata {
    name = "coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
    namespace = "oss"
  }
  spec {
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
    }     
    container {
      name    = "ruby"
      image   = "docker.io/${var.image}"
      command = ["sh", "-c", coder_agent.coder.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.coder.token
      }
      resources {
        requests = {
          cpu    = "500m"
          memory = "1000Mi"
        }        
        limits = {
          cpu    = "${var.cpu}"
          memory = "${var.memory}G"
        }
      }        
      volume_mount {
        mount_path = "/home/coder"
        name       = "home-directory"
      }      
    }
    volume {
      name = "home-directory"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home-directory.metadata.0.name
      }
    }          
  }
}

resource "kubernetes_persistent_volume_claim" "home-directory" {
  metadata {
    name      = "home-coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
    namespace = var.workspaces_namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.disk_size}Gi"
      }
    }
  }
}
