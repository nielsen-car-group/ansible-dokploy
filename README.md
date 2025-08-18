A minimal ansible playbook that deploys dokploy nodes.

# Instructions

## ansible install
Follow install [guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-and-upgrading-ansible-with-pip)

## ssh 
`ansible-playbook -i hosts playbook.yml -l vps -u root --become` replace root with whichever username was provided by your provider
This playbook will change your default ssh port from 22 to 2275, be sure to update your hosts file with the new port after the playbook finishes.

### Setup dokploy
Once the playbook has finished you can set up dokploy by creating an ssh tunnel and visiting the dokploy url in your browser:
- `ssh -L 8080:localhost:8080 -p 2275 admin@<IP>`
- then visit: `localhost:8080` in your browser.

Setup your domain in Dokploy and create an `A record` to your vps ip. You can now visit dokploy from the specified domain without the ssh tunnel

### Subsequent runs after initial setup
`server ansible_host=<IP or host> ansible_port=2275` 
You should now be able to run the playbook using this command
`ansible-playbook -i hosts playbook.yml -l server -u <user defined in playbook vars>`
