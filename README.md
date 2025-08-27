# Ansible Dokploy Deployment

A minimal Ansible playbook that deploys Dokploy nodes. This playbook can be used to set up both the **main control node** and **external server nodes**.

---

## Instructions

### 1. Install Ansible

Follow the [official installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-and-upgrading-ansible-with-pip) to install Ansible.

---

### 2. Run Playbook with SSH

```bash
ansible-playbook -i hosts playbook.yml -l vps -u root --become
```

> Replace `root` with whichever username your VPS provider gives you.

This playbook will:

* Change the default SSH port from 22 to 2275.
* Optionally create a non-root user and copy your local SSH key for subsequent logins.

> **Tip:** Update your `hosts` file with the new SSH port after the playbook finishes.

---

### 3. Main Playbook Variables

| Variable          | Default                                 | Description                                            |
| ----------------- | --------------------------------------- | ------------------------------------------------------ |
| `user_name`       | `admin`                                 | Name of the non-root user to create on the VPS         |
| `user_password`   | `mysecretpassword`                      | Password for the non-root user                         |
| `user_ssh_key`    | `~/.ssh/postgres_public_id_ed25519.pub` | Public key to copy to the server for non-root login    |
| `is_control_node` | `false`                                 | Set to `true` if this is the main Dokploy control node |

---

### 4. Setup Main Dokploy Node

If `is_control_node: true`, the playbook will install Dokploy on the control VPS.

After the playbook completes:

1. Create an SSH tunnel:

```bash
ssh -L 8080:localhost:8080 -p 2275 <user_name>@<VPS_IP>
```

2. Visit `http://localhost:8080` in your browser.
3. Set up your domain in Dokploy and create an `A record` pointing to your VPS IP. You can then access Dokploy directly from your domain without the SSH tunnel.

---

### 5. Setup External Server Node

If `is_control_node: false`, the playbook will configure packages, SSH, firewall, and create a non-root user but **will not install Dokploy**.

After the playbook completes, log in to the external server and run the following scripts:

1. **Setup Dokploy on the node (from Dokploy UI script):**

```bash
./node-setup.sh
```

> ⚠️ This script is copied from Dokploy’s UI. If Dokploy updates their setup script, you may need to update this file manually.

2. **Add non-root user to required groups:**

```bash
./node-setup-user-groups.sh
```

> Required to run deployments and backups from Dokploy on the external server.

---

### 6. Subsequent Runs

After initial setup, you can run the playbook against the same servers using the non-root user:

```bash
ansible-playbook -i hosts playbook.yml -l server -u <user_name>
```

> Replace `<user_name>` with the non-root user defined in the playbook variables.

