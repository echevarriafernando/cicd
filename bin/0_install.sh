#!/bin/bash -e

####################
# Configuration
####################


export server_ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'|grep -v 172*)
export gitlab_root_password=$(openssl rand -hex 12)
export conjur_account=demo
export admin_email=admin@admin.local


echo "#################################"
echo "# ansible"
echo "#################################"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"


[[ -n `which ansible-playbook` ]] || $DIR/install_ansible.sh

ansible-galaxy install cyberark.conjur
ansible-galaxy install drhelius.docker


echo "Ansible is ready!."

echo "#################################"
echo "# Docker Platform"
echo "#################################"

ansible-playbook ./playbook/setup_docker.yml

echo "#################################"
echo "# Pull Images"
echo "#################################"

docker-compose pull

echo "#################################"
echo "# Generate Conjur Data Key"
echo "#################################"

docker-compose run --no-deps --rm conjur data-key generate > data_key
export CONJUR_DATA_KEY="$(< data_key)"


echo "#################################"
echo "# Deploy Containers"
echo "#################################"

SERVER_IP=${server_ip} \
GITLAB_ROOT_PASSWORD=${gitlab_root_password} \
GITLAB_ROOT_EMAIL=${admin_email} \
docker-compose up -d


echo "#################################"
echo "# Setup iptables"
echo "#################################"

ansible-playbook playbook/setup_iptables.yml


echo "#################################"
echo "# Setup Conjur Account"
echo "#################################"

conjur_admin_api=$(docker-compose exec conjur conjurctl account create ${conjur_account})


echo "#################################"
echo "# Setup Gitlab & CI runner"
echo "#################################"

docker exec cicd_gitlab gem install mechanize
docker cp ./gitlab/getcitoken.rb cicd_gitlab:/tmp/getcitoken.rb
docker exec cicd_gitlab chmod +x /tmp/getcitoken.rb


# Wait for GITLAB web service
while [[ "$(curl --write-out %{http_code} --silent --output /dev/null http://gitlab.${server_ip}.xip.io:31080/users/sign_in)" != "200" ]]; do 
    printf '.'
    sleep 5
done

# Wait for GITLAB Runner Registration Token
until [[ -z "$(docker exec cicd_gitlab ruby /tmp/getcitoken.rb | grep 'Error')"   ]]; do sleep 5s ; done
CI_SERVER_TOKEN="$(docker exec cicd_gitlab ruby /tmp/getcitoken.rb)"

docker exec cicd_gitlab_runner gitlab-runner register --non-interactive \
  --url "http://gitlab.${server_ip}.xip.io:31080/" \
  -r "${CI_SERVER_TOKEN}" \
  --executor shell


docker exec cicd_gitlab_runner gitlab-runner start






echo "#################################"
echo "# Done"
echo "#################################"

echo "[conjur]"
echo "url:      http://conjur.${server_ip}.xip.io:8080"
echo ${conjur_admin_api}
echo "[Gitlab]"
echo "url:      http://gitlab.${server_ip}.xip.io:31080"
echo "user:     root"
echo "password: ${gitlab_root_password}\n"
