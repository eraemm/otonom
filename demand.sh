#!/bin/bash

# On-demand instance türleri
declare -a instance_types=("c7a.16xlarge" "m7a.16xlarge")

# Yeni bölgeler
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2")

# Her bölge için AMI ID'leri
declare -A ami_ids
ami_ids["eu-west-1"]="ami-0e9085e60087ce171"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"
ami_ids["us-east-1"]="ami-0e2c8caa4b6378d8c"
ami_ids["us-west-2"]="ami-05d38da78ce859165"

# Başarılı ve başarısız bölgeler için diziler
success_regions=()
failed_regions=()

# Uygun instance türü bulma fonksiyonu
find_instance_type() {
    local region=$1
    for instance_type in "${instance_types[@]}"; do
        available=$(aws ec2 describe-instance-type-offerings \
            --region "$region" \
            --filters "Name=instance-type,Values=$instance_type" "Name=location,Values=$region" \
            --query "InstanceTypeOfferings | length(@)" --output text)
        if [ "$available" -gt 0 ]; then
            echo "$instance_type"
            return
        fi
    done
    echo ""
}

# Alt bölgeleri dinamik olarak bulma fonksiyonu
find_subnet_in_az() {
    local region=$1
    local az=$2
    aws ec2 describe-subnets \
        --region "$region" \
        --filters "Name=availability-zone,Values=$az" \
        --query "Subnets[0].SubnetId" \
        --output text
}

# On-demand instance talebi oluşturma fonksiyonu
create_on_demand_request() {
    local region=$1
    echo "Bölge: $region"

    # Bölgeye göre doğru instance türünü bul
    instance_type=$(find_instance_type "$region")

    if [ -z "$instance_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        failed_regions+=("$region")
        return
    fi
    echo "Seçilen instance türü: $instance_type"

    # AMI ID'sini belirle
    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        failed_regions+=("$region")
        return
    fi

    # Default güvenlik grubunu bul ve SSH portunu aç
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

    # Alt bölgelerde uygun bir subnet arayın
    azs=$(aws ec2 describe-availability-zones --region "$region" --query "AvailabilityZones[].ZoneName" --output text)

    for az in $azs; do
        subnet_id=$(find_subnet_in_az "$region" "$az")
        if [ "$subnet_id" != "None" ]; then
            echo "$region bölgesinde alt bölge bulundu: $az"
            break
        fi
    done

    if [ "$subnet_id" == "None" ]; then
        echo "$region bölgesinde uygun bir alt ağ bulunamadı."
        failed_regions+=("$region")
        return
    fi

    # On-demand instance talebi oluştur
    echo "$region bölgesinde uygun bir tür için on-demand instance talebi oluşturuluyor..."

    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --security-group-ids "$security_group_id" \
        --subnet-id "$subnet_id" \
        --count 1 \
        --query 'Instances[0].InstanceId' --output text)

    if [ -n "$instance_id" ]; then
        echo "On-demand instance talebi başarılı: $instance_id"
        success_regions+=("$region:$instance_type")
    else
        echo "On-demand instance talebi başarısız."
        failed_regions+=("$region")
    fi
}

# Tüm bölgeler için on-demand instance talepleri
for region in "${regions[@]}"; do
    create_on_demand_request "$region"
done

# Sonuçları yazdırma
echo "İşlem sonuçları:"
echo "Başarılı bölgeler: ${success_regions[@]}"
echo "Başarısız bölgeler: ${failed_regions[@]}"
