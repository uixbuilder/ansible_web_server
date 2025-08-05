# Ansible DigitalOcean Provisioning Project

## Short Description
This repository provides an **Ansible-based automation setup** for provisioning and configuring secure web servers on DigitalOcean. It includes dynamic inventory, droplet provisioning, NGINX deployment, SSH hardening, firewall setup, automated updates, and health validation—all modularized into roles.

## Features

- **Automated, idempotent provisioning** of a DigitalOcean droplet with NGINX and full security hardening.
- **SSH key management:** creation, upload to DigitalOcean, and secure storage with Ansible Vault.
- **NGINX deployed** with custom config, non-root user (`wwwebapp`), and dedicated static site directory.
- **Static website content automatically pulled from Git:**  
  Downloads the site from [cloudacademy/static-website-example](https://github.com/cloudacademy/static-website-example.git) and deploys it to the web server.
- **UFW firewall** configured to allow only SSH (22) and HTTP (80).
- **Security hardening:** disables password authentication for SSH, installs and configures fail2ban for intrusion prevention (bans IPs for 10 minutes after 3 failed SSH login attempts within a 10-minute window), and sets up unattended upgrades.
- **Automated validation:** HTTP response check to confirm the web server and content are correctly deployed.

## Requirements
- **Ansible v2.15+** (or later) with:
  - `community.digitalocean` collection for DO dynamic inventory ([docs.ansible.com](https://docs.ansible.com/ansible/latest/collections/community/digitalocean/index.html))
  - `community.general` collection plugins if used ([docs.ansible.com](https://docs.ansible.com/ansible/latest/collections/community/general/index.html#plugins-in-community-general))
- A **DigitalOcean API token**, stored securely only in a vaulted file managed by `setup_secrets.sh`
- **SSH public/private keypair** to access droplets

## Setup

```bash
git clone https://github.com/uixbuilder/ansible_web_server.git
cd ansible_web_server
./setup_secrets.sh
```

The `setup_secrets.sh` script will:
- Prompt you securely for Ansible-vault password
- Prompt you for your DO API token
- Prompt for SSH key files
- Encrypt necessary secrets with Ansible Vault
- Write `inventory/group_vars/all/vault.yml`, `inventory/digitalocean.yml`

With secrets in place, run:
```bash
ansible-playbook playbooks/site.yml
```

## Folder Structure

```
.
├── README.md                  # Project overview and instructions
├── ansible.cfg                # Ansible configuration file
├── inventory
│   ├── digitalocean.yml       # Dynamic inventory for DigitalOcean droplets
│   └── group_vars
│       └── all
│           ├── vault.yml      # Encrypted secrets (API tokens, SSH keys)
│           └── webservers.yml # Group variables for webservers (e.g., ansible_user)
├── playbooks
│   └── site.yml               # Main playbook for server provisioning and setup
├── roles
│   ├── nginx
│   │   ├── handlers
│   │   │   └── main.yml       # NGINX-related handlers (e.g., restart)
│   │   ├── tasks
│   │   │   └── main.yml       # NGINX installation/configuration tasks
│   │   └── templates
│   │       └── nginx.conf.j2  # Jinja2 template for NGINX config
│   ├── provision
│   │   ├── handlers
│   │   │   └── main.yml       # Handlers for droplet provisioning
│   │   └── tasks
│   │       └── main.yml       # Tasks for DigitalOcean droplet provisioning
│   ├── security
│   │   ├── handlers
│   │   │   └── main.yml       # Security-related handlers (e.g., reload sshd)
│   │   ├── tasks
│   │   │   └── main.yml       # Security tasks (SSH hardening, fail2ban, etc.)
│   │   └── templates
│   │       └── jail.local.j2  # fail2ban configuration template
│   ├── ufw
│   │   └── tasks
│   │       └── main.yml       # UFW firewall tasks
│   ├── updates
│   │   └── tasks
│   │       └── main.yml       # System update and upgrade tasks
│   ├── validation
│   │   └── tasks
│   │       └── main.yml       # Tasks for service/HTTP validation
│   └── webcontent
│       └── tasks
│           └── main.yml       # Tasks for website content deployment
└── setup_secrets.sh           # Script to set up encrypted secrets and SSH keys
```

## Used Sources

- [Coursera – Fundamentals of Ansible](https://www.coursera.org/learn/fundamentals-of-ansible)
- [YouTube: Ansible NGINX web server deployment tutorial](https://www.youtube.com/watch?v=eVGwNME0C5w)
- [Ansible Documentation – DigitalOcean Inventory Plugin](https://docs.ansible.com/ansible/latest/collections/community/digitalocean/index.html)
- [Ansible Documentation – `community.general` plugin collection](https://docs.ansible.com/ansible/latest/collections/community/general/index.html#plugins-in-community-general)