terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.131.0"
    }
  }
}

provider "yandex" {
  token = var.yc_iam_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = "ru-central1-a"
}

resource "yandex_vpc_network" "net" {
  name = "tfhexlet"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "tfhexlet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["192.168.192.0/24"]
}

module "yandex-postgresql" {
  source      = "github.com/terraform-yc-modules/terraform-yc-postgresql?ref=1.0.3"
  network_id  = yandex_vpc_network.net.id
  name        = "tfhexlet"
  description = "Single-node PostgreSQL cluster for test purposes"
  disk_size   = 10
  depends_on  = [yandex_vpc_network.net, yandex_vpc_subnet.subnet]

  hosts_definition = [
    {
      zone             = "ru-central1-a"
      assign_public_ip = false
      subnet_id        = yandex_vpc_subnet.subnet.id
    }
  ]

  postgresql_config = {
    max_connections = 100
  }

  databases = [
    {
      name       = "hexlet"
      owner      = var.db_user
      lc_collate = "ru_RU.UTF-8"
      lc_type    = "ru_RU.UTF-8"
      extensions = ["uuid-ossp", "xml2"]
    },
    {
      name       = "hexlet-test"
      owner      = var.db_user
      lc_collate = "ru_RU.UTF-8"
      lc_type    = "ru_RU.UTF-8"
      extensions = ["uuid-ossp", "xml2"]
    }
  ]

  owners = [
    {
      name       = var.db_user
      conn_limit = 15
    }
  ]

  users = [
    {
      name        = "guest"
      conn_limit  = 30
      permissions = ["hexlet"]
      settings = {
        pool_mode                   = "transaction"
        prepared_statements_pooling = true
      }
    }
  ]
}

data "yandex_compute_image" "img" {
  family = "container-optimized-image"
}

resource "yandex_compute_instance" "vm" {
  name        = "tfhexlet"
  zone        = "ru-central1-a"
  depends_on = [module.yandex-postgresql]

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.img.id
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    user-data = <<-EOF
    #!/bin/bash
    #echo 'export DB_HOST="${module.yandex-postgresql.cluster_fqdns_list[0].0}"' >> /etc/environment
    EOF
    ssh-keys  = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = self.network_interface[0].nat_ip_address
  }

  provisioner "remote-exec" {
  inline = [
<<EOT
sudo docker run -d -p 0.0.0.0:80:3000 \
  -e DB_TYPE=postgres \
  -e DB_NAME=${module.yandex-postgresql.databases[0]} \
  -e DB_HOST=${module.yandex-postgresql.cluster_fqdns_list[0].0} \
  -e DB_PORT=6432 \
  -e DB_USER=${module.yandex-postgresql.owners_data[0].user} \
  -e DB_PASS=${module.yandex-postgresql.owners_data[0].password} \
  ghcr.io/requarks/wiki:2
EOT
    ]
  }
}
