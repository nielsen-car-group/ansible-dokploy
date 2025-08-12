# Instructions

## ansible install
Follow install [guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-and-upgrading-ansible-with-pip)

## ssh into your vps using provider credentials
`ssh root@<SERVER IP>` replace root with whichever username was provided by your provider
exit after logging in

## ssh 
`ansible-playbook -i hosts playbook.yml -l vps -u root --become` replace root with whichever username was provided by your provider

This playbook will change your default ssh port from 22 to 2275, be sure to update your hosts file with the new port after the playbook finishes.

`server ansible_host=<IP or host> ansible_port=2275` 


You should now be able to run the playbook using this command

`ansible-playbook -i hosts playbook.yml -l server -u <user defined in playbook vars>`
