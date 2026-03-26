#/bin/bash
sudo touch /etc/sysctl.conf

cat >> /etc/sysctl.conf << EOF
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
EOF
sysctl -p

cat >> /etc/security/limits.conf << EOF
* soft nofile 102400
* hard nofile 204800
EOF