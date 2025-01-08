#!/bin/bash

# On-Demand instance türleri
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

# Güvenlik grubu oluşturma fonksiyonu
create_security_group() {
    local region=$1

    echo "Güvenlik grubu oluşturuluyor..."
    security_group_id=$(aws ec2 create-security-group \
        --group-name "ec2-connect-sg" \
        --description "Allow SSH access for EC2 Instance Connect" \
        --region "$region" \
        --query 'GroupId' --output text)

    if [ -z "$security_group_id" ]; then
        echo "$region bölgesi için güvenlik grubu oluşturulamadı."
        return 1
    fi

    # SSH portunu aç
    aws ec2 authorize-security-group-ingress \
        --group-id "$security_group_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$region"

    echo "Güvenlik grubu oluşturuldu: $security_group_id"
    echo "$security_group_id"
}

# On-Demand instance oluşturma fonksiyonu
create_on_demand_instance() {
    local region=$1

    echo "Bölge: $region"

    # AMI ID'sini kontrol et
    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        return
    fi

    # Güvenlik grubunu oluştur
    security_group_id=$(create_security_group "$region")
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
        echo "$region bölgesinde $instance_type tipi için on-demand instance talebi deneniyor..."

        instance_id=$(aws ec2 run-instances \
            --region "$region" \
            --image-id "$ami_id" \
            --instance-type "$instance_type" \
            --security-group-ids "$security_group_id" \
            --subnet-id "$subnet_id" \
            --associate-public-ip-address \
            --count 1 \
            --query 'Instances[0].InstanceId' --output text 2>/dev/null)

        if [ -n "$instance_id" ]; then
            echo "On-Demand instance oluşturuldu: $instance_id ($instance_type)"
            success_regions+=("$region:$instance_type")
            return
        else
            echo "$instance_type tipi başarısız oldu."
        fi
    done

    echo "$region bölgesinde uygun bir on-demand instance tipi bulunamadı."
}

# Her bölge için işlemi çalıştır
for region in "${regions[@]}"; do
    create_on_demand_instance "$region"
done

# Sonuçları yazdır
echo "İşlem sonuçları:"
for result in "${success_regions[@]}"; do
    echo "$result"
done
