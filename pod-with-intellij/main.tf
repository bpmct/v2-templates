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
  Container images from coder-com

  EOF
  default = "codercom/enterprise-java:ubuntu"
  validation {
    condition = contains([
      "codercom/enterprise-java:ubuntu"
    ], var.image)
    error_message = "Invalid image!"   
}  
}

variable "extension" {
  description = "VS Code extension"
  default     = "redhat.java"
  validation {
    condition = contains([
      "redhat.java"
    ], var.extension)
    error_message = "Invalid VS Code extension!"  
}
}

variable "repo" {
  description = <<-EOF
  Code repository to clone with SSH
  e.g., sharkymark/java_helloworld.git
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
      "IntelliJ IDEA Community Edition 2022.1.4" = "IntelliJ CE 2022.1.4"
      "IntelliJ IDEA Community Edition 2021.3" = "IntelliJ CE 2021.3"
      "IntelliJ IDEA Ultimate 2022.1.4" = "IntelliJ U 2022.1.4"
      "IntelliJ IDEA Ultimate 2021.3" = "IntelliJ U 2021.3"
  }
}

variable "jetbrains-ide" {
  description = "JetBrains IntelliJ IDE (oldest are Projector-tested by JetBrains s.r.o., Na Hrebenech II 1718/10, Prague, 14000, Czech Republic)"
  default     = "IntelliJ IDEA Community Edition 2022.1.4"
  validation {
    condition = contains([
      "IntelliJ IDEA Community Edition 2022.1.4",
      "IntelliJ IDEA Community Edition 2021.3",
      "IntelliJ IDEA Ultimate 2022.1.4",
      "IntelliJ IDEA Ultimate 2021.3"
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
curl -fsSL https://code-server.dev/install.sh | sh -s -- --version=4.5.1 
code-server --auth none --port 13337 &

# use coder CLI to clone and install dotfiles
coder dotfiles -y ${var.dotfiles_uri} &

# install projector into /home/coder

PROJECTOR_BINARY=/home/coder/.local/bin/projector

if [ -f $PROJECTOR_BINARY ]; then
    echo 'projector has already been installed - check for update'
    /home/coder/.local/bin/projector self-update 
else
    echo 'installing projector'
    pip3 install projector-installer --user 
fi

echo 'access projector license terms'
/home/coder/.local/bin/projector --accept-license 

PROJECTOR_CONFIG_PATH=/home/coder/.projector/configs/intellij

if [ -d "$PROJECTOR_CONFIG_PATH" ]; then
    echo 'projector has already been configured and the JetBrains IDE downloaded - skip step' 
else
    echo 'autoinstalling IDE and creating projector config folder'
    /home/coder/.local/bin/projector ide autoinstall --config-name "intellij" --ide-name "${var.jetbrains-ide}" --hostname=localhost --port 8997 --use-separate-config --password coder 

    # delete the configuration's run.sh input parameters that check password tokens since tokens do not work with coder_app yet passed in the querystring

    grep -iv "HANDSHAKE_TOKEN" $PROJECTOR_CONFIG_PATH/run.sh > temp && mv temp $PROJECTOR_CONFIG_PATH/run.sh 
    chmod +x $PROJECTOR_CONFIG_PATH/run.sh 

    echo "creation of intellij configuration complete" 
    
fi

# install JetBrains projector packages required
sudo apt-get update && \
    DEBIAN_FRONTEND="noninteractive" sudo apt-get install -y \
    libxtst6 \
    libxrender1 \
    libfontconfig1 \
    libxi6 \
    libgtk-3-0 


# start JetBrains projector-based IDE
/home/coder/.local/bin/projector run intellij &

# clone repo
mkdir -p ~/.ssh
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
git clone --progress git@github.com:${var.repo}

# install VS Code extensions into code-server
SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item code-server --install-extension ${var.extension}

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

resource "coder_app" "intellij" {
  agent_id      = coder_agent.coder.id
  name          = "${lookup(local.jetbrains-releases, var.jetbrains-ide)}"
  icon          = "/icon/intellij.svg"
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
      name    = "java-intellij"
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
          memory = "3000Mi"
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
