#! bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "=== Checking for existing swap ==="
CURRENT_SWAP_SIZE_KB=0
if [ -f /swapfile ]; then
  CURRENT_SWAP_SIZE_KB=$(ls -l /swapfile | awk '{print $5}' | xargs -I {} expr {} / 1024)
fi

DESIRED_SWAP_SIZE_KB=2097152
if [ "$CURRENT_SWAP_SIZE_KB" -gt "$DESIRED_SWAP_SIZE_KB" ]; then
  echo "!!!"
  echo "!!! WARNING: Existing swap file (/swapfile) is larger than 2GB."
  echo "!!! Current size: $(expr "CURRENT_SWAP_SIZE_KB" / 1024)MB."
  echo "!!! This may indicate a memory shortage. Consider upgrading your instance size."
  echo "!!! Script is exiting to prevent unexpected behavior."
  echo "!!!"
  exit 1
elif [ "$CURRENT_SWAP_SIZE_KB" -ne "$DESIRED_SWAP_SIZE_KB" ]; then
  echo "== Swap file is not the desired size or does not exist. Recreating... =="
  
  if swapon --summary | grep -q '/swapfile'; then
    sudo swapoff /swapfile
  fi
  if [ -f /swapfile ]; then
    sudo rm /swapfile
  fi

  echo "== Creating 2GB swap file =="
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  echo "== New 2GB swap file created and activated. =="
else
  echo "== Desired 2GB swap file already exists. Skipping creation. =="
  # Ensure it is active
  if ! swapon --summary | grep -q '/swapfile'; then
    sudo swapon /swapfile
    echo "== Existing swap file was not active. Now enabled. =="
  fi
fi

# Update system and install tools before adding the repo
echo "=== Updating System and Installing Tools ==="
sudo dnf update -y
sudo dnf install -y procps-ng

echo "=== Installing Elasticsearch and Kibana ==="
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
cat <<EOF | sudo tee /etc/yum.repos.d/elasticsearch.repo
[elasticsearch-8.x]
name=Elasticsearch repository for 8.x packages
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOF

echo "=== Installing Elasticsearch and Kibana ==="
sudo dnf install -y elasticsearch kibana
echo "== Setting Elasticsearch heap size to 2G =="
sudo mkdir -p /etc/elasticsearch/jvm.options.d/
sudo tee /etc/elasticsearch/jvm.options.d/heap.options > /dev/null <<EOF
-Xms2g
-Xmx2g
EOF

echo "=== Enabling and starting Elasticsearch ==="
sudo /bin/systemctl daemon-reload
sudo /bin/systemctl enable elasticsearch.service
sudo /bin/systemctl start elasticsearch.service

echo "== Setting elastic user password =="
ELASTIC_PASSWORD=$(sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s)

until curl -s -k -u elastic:"$ELASTIC_PASSWORD" "https://localhost:9200/_cluster/health" | grep -qE '"status"\s*:\s*"(yellow|green)"'; do
  echo "$(date) - Elasticsearch not ready yet. Waiting 5 seconds..."
  sleep 5
done
echo "Elasticsearch is ready."

echo "=== Enableing and starting Kibana ==="
sudo /bin/systemctl daemon-reload
sudo /bin/systemctl enable kibana.service
sudo /bin/systemctl start kibana.service

echo "== Generating Kibana enrollment token =="
ENROLLMENT_TOKEN=$(sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana)

echo "== Passing enrollment token =="
sudo /usr/share/kibana/bin/kibana-setup --enrollment-token $ENROLLMENT_TOKEN

sudo sed -i '/^\s*#\?\s*server\.host:/d' /etc/kibana/kibana.yml
echo 'server.host: "0.0.0.0"' | sudo tee -a /etc/kibana/kibana.yml
sudo /bin/systemctl restart kibana.service

echo "== Waiting for Kibana to be ready =="
until curl -s "http://localhost:5601/api/status" | grep -qE '"overall"\s*:\s*{"level"\s*:\s*"available"}'; do
  echo "$(date) - Kibana not ready yet. Waiting 5 seconds..."
  sleep 5
done
echo "Kibana is ready."

echo "=== ALL DONE ==="
echo "Elastic user password: $ELASTIC_PASSWORD"