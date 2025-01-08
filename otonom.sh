#!/bin/bash

set -e  # Hata durumunda scripti durdurur
set -o pipefail  # Hataları boru hattında takip eder
set -x  # Hata ayıklama için tüm komutları ekrana yazdırır

# Spot instance türleri
instance_types=("c6a.16xlarge" "c7a.16xlarge" "m6a.16xlarge" "m7a.16xlarge" "r6a.16xlarge" "r7a.16xlarge")

# Bölgeler (sadece belirtilen bölgeler)
regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2")

# Ubuntu Server 24.04 LTS AMI ID'leri
declare -A ami_ids
ami_ids["us-east-1"]="ami-0e2c8caa4b6378d8c"  
ami_ids["us-west-2"]="ami-05d38da78ce859165"
ami_ids["eu-west-1"]="ami-0e9085e60087ce171"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"

# Başarılı bölgeler listesi
success_regions=()

# Log dosyası
log_file="spot_request_log.txt"
echo "" > "$log_file"  # Log dosyasını sıfırlar

# Güvenlik grubu oluşturma veya kontrol etme fonksiyonu
create_or_get_security_group() {
    local region=$1

    echo "[$(date)] $region - Güvenlik grubu kontrol ediliyor..." | tee -a "$log_file"
    # Mevcut güvenlik grubunu kontrol et
    security_group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --query "SecurityGroups[?GroupName=='ec2-connect-sg'].GroupId | [0]" \
        --output text 2>>"$log_file")

    if [ "$security_group_id" != "None" ] && [ -n "$security_group_id" ]; then
        echo "[$(date)] $region - Mevcut güvenlik grubu bulundu: $security_group_id" | tee -a "$log_file"
    else
        echo "[$(date)] $region - Güvenlik grubu oluşturuluyor..." | tee -a "$log_file"
        security_group_id=$(aws ec2 create-security-group \
            --group-name "ec2-connect-sg" \
            --description "Allow SSH access for EC2 Instance Connect" \
            --region "$region" \
            --query 'GroupId' --output text 2>>"$log_file")

        if [ -z "$security_group_id" ]; then
            echo "[$(date)] $region - Güvenlik grubu oluşturulamadı!" | tee -a "$log_file"
            return 1
        fi

        # SSH bağlantısı için IPv4 üzerinden TCP 22 portunu aç
        aws ec2 authorize-security-group-ingress \
            --group-id "$security_group_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$region" 2>>"$log_file"

        echo "[$(date)] $region - Güvenlik grubu oluşturuldu ve SSH için kurallar eklendi: $security_group_id" | tee -a "$log_file"
    fi

    echo "$security_group_id"
}

# Spot instance oluşturma fonksiyonu
create_spot_request() {
    local region=$1

    echo "[$(date)] $region - İşlem başlatıldı." | tee -a "$log_file"

    # AMI ID kontrolü
    ami_id=${ami_ids[$region]}
    if [ -z "$ami_id" ]; then
        echo "[$(date)] $region - AMI ID'si tanımlanmamış!" | tee -a "$log_file"
        return
    fi

    # Güvenlik grubunu oluştur veya mevcut olanı al
    security_group_id=$(create_or_get_security_group "$region")
    if [ -z "$security_group_id" ]; then
        echo "[$(date)] $region - Güvenlik grubu alınamadı." | tee -a "$log_file"
        return
    fi

    # Alt ağ (Subnet) ID'sini kontrol et
    subnet_id=$(aws ec2 describe-subnets \
        --region "$region" \
        --query "Subnets[0].SubnetId" \
        --output text 2>>"$log_file")

    if [ "$subnet_id" == "None" ] || [ -z "$subnet_id" ]; then
        echo "[$(date)] $region - Alt ağ bulunamadı." | tee -a "$log_file"
        return
    fi

    # Instance türlerini sırayla dene
    for instance_type in "${instance_types[@]}"; do
        echo "[$(date)] $region - $instance_type tipi için spot instance talebi deneniyor..." | tee -a "$log_file"

        instance_id=$(aws ec2 run-instances \
            --region "$region" \
            --image-id "$ami_id" \
            --instance-type "$instance_type" \
            --security-group-ids "$security_group_id" \
            --subnet-id "$subnet_id" \
            --associate-public-ip-address \
            --instance-market-options "MarketType=spot" \
            --count 1 \
            --query 'Instances[0].InstanceId' --output text 2>>"$log_file")

        if [ -n "$instance_id" ]; then
            echo "[$(date)] $region - Spot instance oluşturuldu: $instance_id ($instance_type)" | tee -a "$log_file"
            success_regions+=("$region:$instance_type")
            return
        else
            echo "[$(date)] $region - $instance_type tipi başarısız oldu." | tee -a "$log_file"
        fi
    done

    echo "[$(date)] $region - Uygun spot instance tipi bulunamadı." | tee -a "$log_file"
}

# Her bölge için işlemi çalıştır
for region in "${regions[@]}"; do
    create_spot_request "$region"
done

# Sonuçları yazdır
echo "[$(date)] İşlem sonuçları:" | tee -a "$log_file"
for result in "${success_regions[@]}"; do
    echo "[$(date)] Başarılı: $result" | tee -a "$log_file"
done

echo "[$(date)] Tüm işlemler tamamlandı." | tee -a "$log_file"
