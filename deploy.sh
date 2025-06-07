#!/bin/bash

set -e


source ./.env

# Export AWS variables so aws cli can pick them up
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION

STAGE=$1
if [[ -z "$STAGE" ]]; then
  echo "Usage: ./deploy.sh <Stage: Dev|Prod>"
  exit 1
fi


source "${STAGE,,}_config"


aws ec2 describe-key-pairs --key-name "$KEY_NAME" > /dev/null 2>&1 || \
aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem" && chmod 400 "${KEY_NAME}.pem"


SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SECURITY_GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  echo "Creating new security group: $SECURITY_GROUP_NAME"
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "$STAGE SG" \
    --vpc-id $(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text) \
    --query "GroupId" \
    --output text)


  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0
else
  echo "Using existing Security Group"
fi




INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$STAGE},{Key=Stage,Value=$STAGE}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "EC2 instance $INSTANCE_ID launched."


aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"


IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "Instance Public IP: $IP"


echo "Connecting to SSH"
sleep 60


ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@$IP << EOF
sudo apt update
sudo apt install -y wget git unzip curl openjdk-${JAVA_VERSION}-jdk maven libcap2-bin


git clone $REPO_URL
cd techeazy-devops


[ -f mvnw ] && chmod +x mvnw

if [ -f mvnw ]; then
  ./mvnw clean package -DskipTests
else
  mvn clean package -DskipTests
fi



APP_JAR=\$(find ~/techeazy-devops/target -type f -name "*.jar" ! -name "*original*" | head -n 1)
echo "Found \$APP_JAR"
if [ -z "\$APP_JAR" ] || [ ! -f "\$APP_JAR" ]; then
  echo "jar file not found"
  exit 1
fi




JAVA_CMD=\$(readlink -f /usr/bin/java)




sudo setcap 'cap_net_bind_service=+ep' "\$JAVA_CMD"



nohup "\$JAVA_CMD" -jar "\$APP_JAR" > app.log 2>&1 &

echo "app started"

EOF


echo "testing"
sleep 10
curl -I "http://$IP"


echo "instance terminated in 5 minutes..."
ssh -i "${KEY_NAME}.pem" ubuntu@$IP "sudo shutdown -h +5"
