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

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host. This
  is likely not your local machine unless you are using `coder server --dev.`

  EOF
}

variable "workspaces_namespace" {
  description = <<-EOF
  Kubernetes namespace to deploy the workspace into

  EOF
  default = "oss"
  validation {
    condition = contains([
      "oss",
      "coder-oss",
      "coder-workspaces"
    ], var.workspaces_namespace)
    error_message = "Invalid namespace!"   
}  
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

variable "cpu" {
  description = "CPU (__ cores)"
  default     = 6
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
  default     = 10
  validation {
    condition = contains([
      "4",
      "6",
      "8",
      "10",
      "12"
    ], var.memory)
    error_message = "Invalid memory!"  
}
}

variable "disk_size" {
  description = "Disk size (__ GB)"
  default     = 10
}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default     = ""
}

resource "coder_agent" "dev" {
  os             = "linux"
  arch           = "amd64"
  dir            = "/home/coder"
  startup_script = <<EOF
    #!/bin/sh
    
    # Start code-server
    code-server --auth none --port 13337 &

    # Configure and run JetBrains IDEs

    # Assumes you have IntelliJ (/opt/idea),
    # PyCharm (/opt/pycharm), and pip3 installed in
    # your image and the "coder" user has filesystem
    # permissions for "/opt/*"
    # ex. https://github.com/sharkymark/v2-templates/blob/main/multi-jetbrains/multi-intellij/Dockerfile
    pip3 install projector-installer --user
    /home/coder/.local/bin/projector --accept-license 
    
    /home/coder/.local/bin/projector config add intellij1 /opt/idea --force --use-separate-config --port 9001 --hostname localhost
    /home/coder/.local/bin/projector run intellij1 &

    /home/coder/.local/bin/projector config add intellij2 /opt/idea --force --use-separate-config --port 9002  --hostname localhost
    /home/coder/.local/bin/projector run intellij2 &

    # clone 2 Java repos
    mkdir -p ~/.ssh
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
    git clone --progress git@github.com:sharkymark/java_helloworld.git &
    git clone --progress git@github.com:iluwatar/java-design-patterns.git &


    ${var.dotfiles_uri != "" ? "coder dotfiles -y ${var.dotfiles_uri}" : ""}
  EOF
}

# code-server
resource "coder_app" "code-server" {
  agent_id = coder_agent.dev.id
  name     = "VS Code"
  icon     = "/icon/code.svg"
  url      = "http://localhost:13337"
}

resource "coder_app" "intellij1" {
  agent_id = coder_agent.dev.id
  name     = "IDEA 1"
  icon     = "/icon/intellij.svg"
  url      = "http://localhost:9001"
}

resource "coder_app" "intellij2" {
  agent_id = coder_agent.dev.id
  name     = "IDEA 2"
  icon     = "/icon/intellij.svg"
  url      = "http://localhost:9002"
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory
  ]
  metadata {
    name      = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    security_context {
      run_as_user = 1000
      fs_group    = 1000
    }
    container {
      name    = "dev"
      image   = "docker.io/marktmilligan/idea-comm-multi-vscode:user-config"
      image_pull_policy = "Always"       
      command = ["sh", "-c", coder_agent.dev.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.dev.token
      }
      resources {
        requests = {
          cpu    = "500m"
          memory = "3500Mi"
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
    name      = "coder-pvc-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
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
