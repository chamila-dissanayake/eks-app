#!/usr/bin/env bash

# Logs script actions to standard locations
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
set -x

ENVIRONMENT=${environment}
ROLE=${role}
AWS_REGION=${region}
EKS_CLUSTER_NAME=${eks_cluster}
NAMESPACE=${namespace}
AWS_ACCESS_KEY_ID=${access_key_id}
AWS_SECRET_ACCESS_KEY=${secret_access_key}
DOMAIN="${domain}"
HOSTED_ZONE_ID="${hosted_zone_id}"


hostnamectl set-hostname "${environment}-${role}"

# Install and set up ssm agent
sudo yum install -y amazon-ssm-agent
mkdir -m 755 -p /var/log/journal
chown root:root /var/log/journal

# Install and set up cronie if not already installed
sudo yum install -y cronie
sudo systemctl enable crond.service
sudo systemctl start crond.service
sudo systemctl status crond | grep Active

# Update the instance
sudo yum update -y
sudo yum upgrade -y

# Install kubectl
cd $HOME
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.32.0/2024-12-20/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install helm 3
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Configure AWS CLI (using IAM role or credentials)
# Option 1: Use IAM role (if available)
echo "Checking for IAM role..."
if [ -n "$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)" ]; then
  echo "IAM role detected, no credential configuration needed."
else
  # Option 2: Use access keys
  echo "Configuring AWS CLI with access keys..."
  mkdir -p $HOME/.aws
  cat <<EOL > $HOME/.aws/credentials
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOL
  cat <<EOL > $HOME/.aws/config
[default]
region = $AWS_REGION
output = json
EOL
  chmod 600 $HOME/.aws/credentials $HOME/.aws/config
  chown ssm-user:ssm-user $HOME/.aws/ -R
fi

# Create kubectl directory
mkdir -p $HOME/.kube
chown ssm-user:ssm-user $HOME/.kube
chmod 700 $HOME/.kube

# Update kubeconfig for EKS cluster
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME

# Update default namespace for kubectl
if [ -n "$NAMESPACE" ]; then
  kubectl config set-context --current --namespace=$NAMESPACE
fi

# Set proper permissions
chown -R ssm-user:ssm-user $HOME/.kube
chown -R ssm-user:ssm-user $HOME/.aws

# update motd
echo "#!/bin/sh
cat << EOF
********************************************************************
*                                                                  *
* This system is for the use of authorized users only.  Usage of   *
* this system may be monitored and recorded by system personnel.   *
*                                                                  *
* Anyone using this system expressly consents to such monitoring   *
* and is advised that if such monitoring reveals possible          *
* evidence of criminal activity, system personnel may provide the  *
* evidence from such monitoring to law enforcement officials.      *
*                                                                  *
********************************************************************

EOF" > /etc/update-motd.d/40-banner
chmod 755 /etc/update-motd.d/40-banner
/usr/sbin/update-motd
# update motd, end of section

# setup crontab to reboot and enable new kernel live patching, https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/al2-live-patching.html
#/usr/bin/crontab -l | { /usr/bin/cat; /usr/bin/echo "0 1 1 */2 * /usr/sbin/reboot # reboot every other month for kernel live patching"; } | /usr/bin/crontab -

# Create kernel patching script
cat > /usr/local/bin/patch-kernel.sh << 'EOF'
#!/bin/bash
set -e

logger -t patch-kernel "Applying kernel live patches..."
dnf update -y kernel # Update only the kernel package
if [ $? -eq 0 ]; then
  logger -t patch-kernel "Kernel update completed. Rebooting system."
  # Reboot the system to load the new kernel.
  # You might want to add additional checks/logging before a production reboot.
  /sbin/shutdown -r now
else
  logger -t patch-kernel "Kernel update failed or no new kernel available."
fi
EOF

chmod +x /usr/local/bin/patch-kernel.sh

# Create systemd service to run patch-kernel.sh
cat > /etc/systemd/system/patch-kernel.service << 'EOF'
[Unit]
Description=Apply kernel live patches and reboot if necessary
[Service]
Type=oneshot
ExecStart=/usr/local/bin/patch-kernel.sh
EOF

# Create systemd timer to schedule the service
cat > /etc/systemd/system/patch-kernel.timer << 'EOF'
[Unit]
Description=Run patch-kernel.service every Sunday at 12:00 AM

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable patch-kernel.timer
systemctl start patch-kernel.timer

# Create Route53 update script
cat > /usr/local/bin/update-route53.sh << 'EOF'
#!/bin/bash
set -e

REGION="${region}"
HOSTED_ZONE_ID="${hosted_zone_id}"
RECORD_NAME="${dns_record_name}"
RECORD_TYPE="A"
TTL=${ttl}

# Get instance metadata token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)

# Get current public IP
PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)

if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: Could not retrieve public IP"
    exit 1
fi

echo "Current public IP: $PUBLIC_IP"
echo "Updating Route53 record: $RECORD_NAME"

# Create JSON for Route53 update
CHANGE_BATCH=$(cat <<CHANGEBATCH
{
  "Comment": "Update bastion IP - $(date)",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$RECORD_NAME",
      "Type": "$RECORD_TYPE",
      "TTL": $TTL,
      "ResourceRecords": [{"Value": "$PUBLIC_IP"}]
    }
  }]
}
CHANGEBATCH
)

# Update Route53 record
aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$CHANGE_BATCH" \
    --region "$REGION"

if [ $? -eq 0 ]; then
    echo "Successfully updated Route53 record $RECORD_NAME to $PUBLIC_IP"
    logger -t route53-update "Updated $RECORD_NAME to $PUBLIC_IP"
else
    echo "Failed to update Route53 record"
    logger -t route53-update "Failed to update $RECORD_NAME"
    exit 1
fi
EOF

chmod +x /usr/local/bin/update-route53.sh

# Create systemd service to run on boot
cat > /etc/systemd/system/update-route53.service << 'EOF'
[Unit]
Description=Update Route53 DNS record with current public IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-route53.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable update-route53.service
systemctl start update-route53.service

# Add cron job for periodic updates (every 5 minutes as backup)
#cat > /etc/cron.d/update-route53 << 'EOF'
# */5 * * * * root /usr/local/bin/update-route53.sh >> /var/log/route53-update.log 2>&1
EOF

#chmod 644 /etc/cron.d/update-route53

echo "Route53 A record updated and automation configured successfully!"