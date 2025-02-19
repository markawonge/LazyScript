#!/bin/bash

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本，或使用 sudo。"
    exit 1
fi

# 检查并安装必要的工具
install_required_tools() {
    local tools=("snap" "cron" "vim" "git" "socat")
    for tool in "${tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            echo "$tool 未安装，正在安装..."
            if command -v apt &> /dev/null; then
                apt update
                apt install -y $tool
            elif command -v yum &> /dev/null; then
                yum install -y $tool
            elif command -v dnf &> /dev/null; then
                dnf install -y $tool
            else
                echo "无法确定包管理器，请手动安装 $tool。"
                exit 1
            fi
        else
            echo "$tool 已安装。"
        fi
    done
}

# 安装Nextcloud
install_nextcloud() {
    echo "正在安装Nextcloud..."
    snap install nextcloud
    echo "Nextcloud 安装完成。"
}

# 提示用户访问Nextcloud并设置管理员账号密码
setup_nextcloud_admin() {
    local ip=$(hostname -I | awk '{print $1}')
    echo "请用浏览器访问 http://$ip 设置Nextcloud账号密码以完成初始配置。"
    read -p "设置完成后按回车键继续..."
}

# 检查Nextcloud管理员账号是否已设置
check_nextcloud_admin() {
    while true; do
        read -p "请确认已设置Nextcloud管理员账号密码(y/n): " is_setup
        if [[ $is_setup == "y" || $is_setup == "Y" ]]; then
            break
        else
            setup_nextcloud_admin
        fi
    done
}

# 安装Cockpit
install_cockpit() {
    echo "正在安装Cockpit..."
    if command -v apt &> /dev/null; then
        apt install -y cockpit
    elif command -v yum &> /dev/null; then
        yum install -y cockpit
    elif command -v dnf &> /dev/null; then
        dnf install -y cockpit
    else
        echo "无法确定包管理器，请手动安装Cockpit。"
        exit 1
    fi
    systemctl enable cockpit.socket
    systemctl start cockpit
    echo "Cockpit 安装完成。"
}

# 安装acme.sh并注册账户
install_acme_sh() {
    local email=$1
    echo "正在安装acme.sh..."
    curl https://get.acme.sh | sh -s email=$email
    ~/.acme.sh/acme.sh --register-account -m $email --server letsencrypt
    echo "acme.sh 安装完成。"
}

# 选择DNS提供商并签发证书
issue_ssl_certificate() {
    local domain=$1
    echo "请选择 DNS 提供商："
    echo "1. 阿里云"
    echo "2. Cloudflare"
    read -p "请输入选项（1 或 2）: " dns_provider

    if [ "$dns_provider" == "1" ]; then
        read -p "请输入阿里云 API Key: " ali_key
        read -p "请输入阿里云 API Secret: " ali_secret
        export Ali_Key=$ali_key
        export Ali_Secret=$ali_secret
        dns_service="dns_ali"
    elif [ "$dns_provider" == "2" ]; then
        read -p "请输入 Cloudflare API Key: " cf_key
        read -p "请输入 Cloudflare API Email: " cf_email
        export CF_Key=$cf_key
        export CF_Email=$cf_email
        dns_service="dns_cf"
    else
        echo "无效选项，退出脚本。"
        exit 1
    fi

    echo "正在签发SSL证书..."
    ~/.acme.sh/acme.sh --issue --dns $dns_service -d $domain --force
    echo "SSL证书签发完成。"
}

# 为Nextcloud配置SSL证书
configure_nextcloud_ssl() {
    local domain=$1
    echo "正在为Nextcloud配置SSL证书..."
    mkdir -p /var/snap/nextcloud/current/certs/custom
    cp ~/.acme.sh/$domain\_ecc/$domain.cer /var/snap/nextcloud/current/certs/custom/cert.pem
    cp ~/.acme.sh/$domain\_ecc/$domain.key /var/snap/nextcloud/current/certs/custom/privkey.pem
    cp ~/.acme.sh/$domain\_ecc/fullchain.cer /var/snap/nextcloud/current/certs/custom/chain.pem
    nextcloud.enable-https custom -s cert.pem privkey.pem chain.pem
    nextcloud.occ config:system:set trusted_domains 1 --value="$domain"

    read -p "请输入 HTTP 端口号（默认：8080）: " http_port
    http_port=${http_port:-8080}
    read -p "请输入 HTTPS 端口号（默认：8443）: " https_port
    https_port=${https_port:-8443}
    snap set nextcloud ports.http=$http_port ports.https=$https_port

    snap set nextcloud http.compression=true

    read -p "请输入 PHP 内存限制（按回车使用默认值 -1，表示无限制）: " memory_limit
    memory_limit=${memory_limit:--1}
    snap set nextcloud php.memory-limit=$memory_limit

    nextcloud.occ maintenance:repair --include-expensive

    # 重启 Nextcloud 的 Apache 服务以使证书生效
    snap restart nextcloud.apache

    # 设置定时任务更新证书
    cron_job="0 0 1 */2 * /root/.acme.sh/acme.sh --renew -d $domain --force && cp ~/.acme.sh/$domain\_ecc/$domain.cer /var/snap/nextcloud/current/certs/custom/cert.pem && cp ~/.acme.sh/$domain\_ecc/$domain.key /var/snap/nextcloud/current/certs/custom/privkey.pem && cp ~/.acme.sh/$domain\_ecc/fullchain.cer /var/snap/nextcloud/current/certs/custom/chain.pem && nextcloud.enable-https custom -s cert.pem privkey.pem chain.pem && snap restart nextcloud.apache"
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -

    echo "Nextcloud SSL证书配置完成。"
}

# 为Cockpit配置SSL证书
configure_cockpit_ssl() {
    local domain=$1
    echo "正在为Cockpit配置SSL证书..."
    if [ -f "/etc/cockpit/ws-certs.d/0-self-signed.cert" ] && [ -f "/etc/cockpit/ws-certs.d/0-self-signed.key" ]; then
        mv /etc/cockpit/ws-certs.d/0-self-signed.cert /etc/cockpit/ws-certs.d/0-self-signed.cert.bak
        mv /etc/cockpit/ws-certs.d/0-self-signed.key /etc/cockpit/ws-certs.d/0-self-signed.key.bak
    fi
    cp ~/.acme.sh/$domain\_ecc/$domain.cer /etc/cockpit/ws-certs.d/0-self-signed.cert
    cp ~/.acme.sh/$domain\_ecc/$domain.key /etc/cockpit/ws-certs.d/0-self-signed.key
    systemctl restart cockpit
    echo "Cockpit SSL证书配置完成。"
}

# 主函数
main() {
    read -p "请输入您的邮箱: " email
    read -p "请输入服务器网址（例如：www.example.com）: " domain

    install_required_tools
    install_nextcloud
    setup_nextcloud_admin
    check_nextcloud_admin

    read -p "是否安装Cockpit？(y/n): " install_cockpit_choice
    if [[ $install_cockpit_choice == "y" || $install_cockpit_choice == "Y" ]]; then
        install_cockpit
    fi

    install_acme_sh $email
    issue_ssl_certificate $domain
    configure_nextcloud_ssl $domain

    if [[ $install_cockpit_choice == "y" || $install_cockpit_choice == "Y" ]]; then
        configure_cockpit_ssl $domain
    fi

    echo "Nextcloud 安装和配置完成！"
    echo "证书更新任务已设置为每 2 个月运行一次。"
    echo "已将 $domain 添加到 trusted_domains 中。"
}

main
