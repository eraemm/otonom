#!/bin/bash

# AWS AMI
AMI_ID="ami-0e2c8caa4b6378d8c"

# Spot instance türleri (öncelik sırasıyla)
INSTANCE_TYPES=("c6a.16xlarge" "c7a.16xlarge" "m6a.16xlarge" "m7a.16xlarge" "r6a.16xlarge" "r7a.16xlarge")

# Bölge
REGION="us-east-1"

# VPC ID kontrolü
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "VPC bulunamadı. Lütfen VPC yapılandırmasını kontrol edin."
  exit 1
fi

echo "VPC ID: $VPC_ID"

# Güvenlik grubu oluşturma ve SSH portunu açma
SECURITY_GROUP_NAME="otonom-ssh-sg"
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
  --group-name "$SECURITY_GROUP_NAME" \
  --description "Security group with SSH access" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query 'GroupId' --output text)

if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then
  echo "Güvenlik grubu oluşturulamadı. Lütfen AWS CLI yetkilerinizi kontrol edin."
  exit 1
fi

echo "Güvenlik Grubu Oluşturuldu: $SECURITY_GROUP_ID"

# SSH için kural ekleme
aws ec2 authorize-security-group-ingress \
  --group-id "$SECURITY_GROUP_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region "$REGION"

echo "SSH için güvenlik grubu kuralı eklendi."

echo "Bölge: $REGION"

for INSTANCE_TYPE in "${INSTANCE_TYPES[@]}"; do
  echo "  Deneniyor: $INSTANCE_TYPE"

  # Mevcut Spot fiyatını sorgulama
  SPOT_PRICE=$(aws ec2 describe-spot-price-history \
    --region "$REGION" \
    --instance-types "$INSTANCE_TYPE" \
    --product-descriptions "Linux/UNIX" \
    --start-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null)

  if [[ -z "$SPOT_PRICE" || "$SPOT_PRICE" == "None" ]]; then
    echo "  Spot fiyatı alınamadı, başka bir instance türü deneniyor."
    continue
  fi

  echo "  Mevcut Spot fiyatı: $SPOT_PRICE"

  # Spot Request oluşturma
  REQUEST_ID=$(aws ec2 request-spot-instances \
    --region "$REGION" \
    --spot-price "$SPOT_PRICE" \
    --instance-count 1 \
    --type "one-time" \
    --launch-specification "{
      \"ImageId\": \"$AMI_ID\",
      \"InstanceType\": \"$INSTANCE_TYPE\",
      \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"]
    }" \
    --query 'SpotInstanceRequests[0].SpotInstanceRequestId' --output text 2>/dev/null)

  if [[ -z "$REQUEST_ID" || "$REQUEST_ID" == "None" ]]; then
    echo "  Spot Request oluşturulamadı, başka bir instance türü deneniyor."
    continue
  fi

  echo "  Spot Request başarıyla oluşturuldu: $REQUEST_ID"

  # Spot Instance'ın durumu kontrol ediliyor
  while true; do
    STATUS=$(aws ec2 describe-spot-instance-requests \
      --region "$REGION" \
      --spot-instance-request-ids "$REQUEST_ID" \
      --query 'SpotInstanceRequests[0].Status.Code' --output text)

    echo "    Durum: $STATUS"

    if [[ "$STATUS" == "fulfilled" ]]; then
      INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
        --region "$REGION" \
        --spot-instance-request-ids "$REQUEST_ID" \
        --query 'SpotInstanceRequests[0].InstanceId' --output text)
      echo "  Spot Instance oluşturuldu: $INSTANCE_ID"

      # Erişim testi için Public IP adresini al
      PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
      echo "  Instance Public IP: $PUBLIC_IP"
      break
    elif [[ "$STATUS" == "capacity-oversubscribed" || "$STATUS" == "bad-parameters" ]]; then
      echo "  Spot Request başarısız oldu, başka bir instance türü deneniyor."
      break
    fi
    sleep 10
  done

  # Eğer Spot Instance oluşturulduysa diğer türlere geçme
  if [[ -n "$INSTANCE_ID" ]]; then
    break
  fi
done

echo "Script tamamlandı."
