#!/bin/bash

# AWS bölgeleri ve AMI'ler
declare -A AMIS=(
  ["us-east-1"]="ami-0e2c8caa4b6378d8c"
  ["us-west-2"]="ami-05d38da78ce859165"
  ["eu-west-1"]="ami-0e9085e60087ce171"
  ["eu-north-1"]="ami-075449515af5df0d1"
)

# Spot instance türleri (öncelik sırasıyla)
INSTANCE_TYPES=("c6a.16xlarge" "c7a.16xlarge" "m6a.16xlarge" "m7a.16xlarge" "r6a.16xlarge" "r7a.16xlarge")

# Güvenlik grubu
SECURITY_GROUP="launch-wizard-1"

# Key Pair (Opsiyonel, kendi key pair'inizi ekleyebilirsiniz)
KEY_NAME="your-key-name"

# Her bölge için işlemleri başlat
for REGION in "us-east-1" "us-west-2" "eu-west-1" "eu-north-1"; do
  echo "Bölge: $REGION"
  AMI_ID=${AMIS[$REGION]}

  for INSTANCE_TYPE in "${INSTANCE_TYPES[@]}"; do
    echo "  Deneniyor: $INSTANCE_TYPE"

    # Spot Request oluşturma
    REQUEST_ID=$(aws ec2 request-spot-instances \
      --region "$REGION" \
      --spot-price "0.5" \
      --instance-count 1 \
      --type "one-time" \
      --launch-specification "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"SecurityGroups\": [\"$SECURITY_GROUP\"],
        \"KeyName\": \"$KEY_NAME\"
      }" \
      --query 'SpotInstanceRequests[0].SpotInstanceRequestId' --output text 2>/dev/null)

    # Eğer Spot Request başarılı olduysa
    if [[ -n "$REQUEST_ID" && "$REQUEST_ID" != "None" ]]; then
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
    else
      echo "  Spot Request oluşturulamadı, başka bir instance türü deneniyor."
    fi
  done

done

echo "Script tamamlandı."
