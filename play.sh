export ANSIBLE_STDOUT_CALLBACK=debug
ansible-playbook deploy_database.yml -i inventories/hosts.yml