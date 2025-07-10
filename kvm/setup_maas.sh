#!/bin/bash

# Install MAAS snap packages
sudo snap install --channel=3.1/stable maas
sudo snap install maas-test-db

# Initialize region+rack (you'll need to replace LP_ID with your actual Launchpad ID)
sudo maas init region+rack --database-uri "maas-test-db:///" \
  --maas-url "http://10.10.10.2:5240/MAAS" \
  --num-workers 4 \
  --enable-debug \
  --admin-username admin \
  --admin-password admin \
  --admin-ssh-import sombrafam

# Enable debug mode
echo 'debug: true' | sudo tee -a /var/snap/maas/current/rackd.conf
echo 'debug: true' | sudo tee -a /var/snap/maas/current/regiond.conf

# Restart MAAS service
sudo snap restart maas

# Create admin user (you'll need to replace LP_ID with your actual Launchpad ID)
sudo maas createadmin --username admin \
  --password admin \
  --email admin@mymaas.com \
  --ssh-import sombrafam

# Generate API key and save to file
sudo maas apikey --username=admin | tee ~/maas-apikey.txt