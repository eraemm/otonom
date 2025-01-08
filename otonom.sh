#!/bin/bash

# Spot instance türleri
instance_types=("c6a.16xlarge" "c7a.16xlarge" "m6a.16xlarge" "m7a.16xlarge" "r6a.16xlarge" "r7a.16xlarge")

# Bölgeler (sadece belirtilen bölgeler)
regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2")

# Ubuntu Server 24.04 LTS AMI ID'leri
declare -A ami_ids
ami_ids["us-east-1"]="ami-0e2c8caa4b6378d8c"  # Değerleri güncellemeyi unutmayın
ami_ids["us-west-2"]="ami-05d38da78ce859165"
ami_ids["eu-west-1"]="ami-0e9085e60087ce171"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"

# Başarılı bölgeler listesi
success_regions=()

# Mevcut güvenlik grubunu kullanma fonksiyonu
use_existing_security_group() {
    local region=$1
    local group_name="launch-wizard-1"

    # "launch-wizard-1" güvenlik grubunun ID'sini al
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters Name=group-name,Values="$group_name" \
        --query 'SecurityGroups[0].GroupId' --output text)

    if [ "$security_group_id" == "None" ]; then
        echo "$region bölgesinde $group_name adında bir güvenlik grubu bulunamadı."
        return 1
    fi

    # SSH portunu aç (kural mevcut değilse)
    ssh_rule_exists=$(aws ec2 describe-security-group-rules \
        --region "$region" \
        --filters Name=group-id,Values="$security_group_id" Name=from-port,Values=22 Name=to-port,Values=22 Name=protocol,Values=tcp \
        --query 'SecurityGroupRules[?CidrIpv4==`0.0.0.0/0`].SecurityGroupRuleId' --output text)

    if [ -z "$ssh_rule_exists" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$security_group_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$region"

        echo "$group_name güvenlik grubunda SSH (22) portu açıldı."
    else
        echo "$group_name güvenlik grubunda SSH (22) portu zaten açık."
    fi

    echo "$security_group_id"
}

# Spot instance oluşturma fonksiyonu
create_spot_request() {
    local region=$1

    echo "Bölge: $region"

    # AMI ID'sini kontrol et
    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        return
    fi

    # Mevcut güvenlik grubunu kullan
    security_group_id=$(use_existing_security_group "$region")
    if [ -z "$security_group_id" ]; then
        return
    fi

    # Alt ağ (Subnet) ID'sini bul
    subnet_id=$(aws ec2 describe-subnets \
        --region "$region" \
        --query "Subnets[0].SubnetId" \
        --output text)

    if [ "$subnet_id" == "None" ]; then
        echo "$region bölgesinde alt ağ bulunamadı."
        return
    fi

    # Instance türlerini sırayla dene
    for instance_type in "${instance_types[@]}"; do
        echo "$region bölgesinde $instance_type tipi için spot instance talebi deneniyor..."

        instance_id=$(aws ec2 run-instances \
            --region "$region" \
            --image-id "$ami_id" \
            --instance-type "$instance_type" \
            --security-group-ids "$security_group_id" \
            --subnet-id "$subnet_id" \
            --associate-public-ip-address \
            --instance-market-options "MarketType=spot" \
            --count 1 \
            --query 'Instances[0].InstanceId' --output text 2>/dev/null)

        if [ -n "$instance_id" ]; then
            echo "Spot instance oluşturuldu: $instance_id ($instance_type)"
            success_regions+=("$region:$instance_type")
            return
        else
            echo "$instance_type tipi başarısız oldu."
        fi
    done

    echo "$region bölgesinde uygun bir spot instance tipi bulunamadı."
}

# Her bölge için işlemi çalıştır
for region in "${regions[@]}"; do
    create_spot_request "$region"
done

# Sonuçları yazdır
echo "İşlem sonuçları:"
for result in "${success_regions[@]}"; do
    echo "$result"
done
