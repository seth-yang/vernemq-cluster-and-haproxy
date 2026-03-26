# Haproxy + VerneMQ 2.1.2 集群方案

## 0. 系统准备
在所有节点上执行：
- 内核优化

```bash
cat >> /etc/sysctl.conf << EOF
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
EOF
sysctl -p
```

- 修改文件句柄
```bash
cat >> /etc/security/limits.conf << EOF
* soft nofile 102400
* hard nofile 204800
EOF

sudo systemctl reboot
```

## 1. VerneMQ 2.1.2

### 1.1 编译VerneMQ 2.1.2

```bash
sudo apt -y update && sudo apt -y full-upgrade
sudo apt -y install build-essential git libsnappy-dev libssl-dev
cd ~
git clone -b 2.1.2 https://github.com/vernemq/vernemq.git
cd vernemq/
make -j$(nproc) rel
```

### 1.2 打包 vernemq-2.1.2-x86_64.deb

#### 1.2.1 准备工作

```bash
mkdir ~/deb-builder && cd ~/deb-builder
mkdir -p DEBIAN lib/systemd/system var/lib/vernemq/2.1.2
```

#### 1.2.2 复制编译好的程序到目标目录

```bash
cp -arf ~/vernemq/_build/default/rel/vernemq/* ./var/lib/vernemq/2.1.2/
```

#### 1.2.3 生成默认配置文件

```bash
mv ./var/lib/vernemq/2.1.2/etc/vernemq.conf ./var/lib/vernemq/2.1.2/etc/vernemq.conf.default
vim ./var/lib/vernemq/2.1.2/etc/vernemq.conf
```

输入以下内容：

```properties
# ============================================
# VerneMQ 配置文件 (兼容版本)
# ============================================

# 1. 监听器配置
listener.tcp.default = 0.0.0.0:1883
#listener.ws.default = 0.0.0.0:8080
listener.http.default = 0.0.0.0:8888

# 2. 认证设置
allow_anonymous = off
plugins.vmq_passwd = on
plugins.vmq_acl = on
vmq_passwd.password_file = ./etc/passwd
vmq_acl.acl_file = ./etc/vmq.acl

# 3. 日志配置
log.console.level = info
log.console = console
log.console.file = /var/log/vernemq/console.log
log.error.file = /var/log/vernemq/error.log
log.syslog = off

# 4. 消息设置
max_message_size = 0
max_message_rate = 0
max_inflight_messages = 20
retry_interval = 20
upgrade_outgoing_qos = off

# 5. 持久化设置
persistent_client_expiration = 1w
metadata_plugin = vmq_plumtree

# 6. 队列设置
queue_deliver_mode = balance
queue_type = fifo

# 7. 订阅设置
max_online_messages = 1000
max_offline_messages = 1000
max_drain_time = 20000
max_msgs_per_drain_step = 1000

# 8. 客户端设置
allow_register_during_netsplit = on
allow_publish_during_netsplit = on
allow_subscribe_during_netsplit = on
allow_unsubscribe_during_netsplit = on

# 9. 插件配置
plugins.vmq_diversity = off
plugins.vmq_bridge = off
plugins.vmq_webhooks = off
plugins.vmq_elasticsearch = off
plugins.vmq_prometheus = off

# 10. 集群配置
distributed_cookie = vmq
erlang.async_threads = 64
erlang.max_ports = 262144
listener.vmq.clustering = 127.0.0.1:44053
metadata_plugin = vmq_plumtree

# set the node name to VerneMQ@<your-real-ip>
nodename = VerneMQ@127.0.0.1
```

#### 1.2.4 生成打包配置文件

- `vim DEBIAN/control-2.1.2`
 
```properties
Package: vernemq
Version: 2.1.2-1
Section: net
Priority: optional
Architecture: amd64
Depends: adduser, systemd, libsnappy-dev, libssl-dev
Maintainer: Your Name <your.email@example.com>
Description: VerneMQ MQTT Broker
 VerneMQ is a high-performance, distributed MQTT message broker.
 It scales horizontally and vertically on commodity hardware.
Homepage: https://vernemq.com/
```

- `vim DEBIAN/postinst-2.1.2`
```bash
#!/bin/bash
set -e
VER=2.1.2
ROOT=/var/lib/vernemq/$VER

case "$1" in
    configure)
        # 设置目录权限
        chown -R vernemq:vernemq $ROOT
        chmod 755 $ROOT
        chmod +x $ROOT/bin/*
        chmod +x $ROOT/lib/inets-9.3.2/priv/bin/*
        chmod +x $ROOT/lib/mysql-1.8.0/priv/bin/*
        chmod +x $ROOT/lib/os_mon-2.10.1/priv/bin/*

        mkdir /var/run/vernemq /var/log/vernemq
        chown vernemq:vernemq /var/run/vernemq
        chown vernemq:vernemq /var/log/vernemq

        # 启用并启动 systemd 服务
        systemctl daemon-reload
        systemctl enable vernemq.service
        systemctl start vernemq.service || true

        echo "VerneMQ ${VER} has been installed successfully."
        echo "Service: vernemq"
        echo "User: vernemq (uid: $(id -u vernemq))"
        echo "Config: ${ROOT}/vernemq.conf"
        ;;
    abort-upgrade|abort-remove|abort-deconfigure)
        ;;
    *)
        echo "postinst called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

exit 0
```

- `vim DEBIAN/postrm`
```bash
#!/bin/bash
set -e

case "$1" in
    purge)
        # 删除用户和组（仅在无其他包使用时）
        if getent passwd vernemq >/dev/null 2>&1; then
            userdel vernemq 2>/dev/null || true
        fi

        if getent group vernemq >/dev/null 2>&1; then
            groupdel vernemq 2>/dev/null || true
        fi
        ;;
    remove|upgrade|abort-install|abort-upgrade|disappear)
        ;;
    *)
        echo "postrm called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

exit 0
```

- `vim DEBIAN/preinst`
```bash
#!/bin/bash
set -e

# 检查是否已存在 vernemq 用户
if getent passwd vernemq >/dev/null 2>&1; then
    echo "User vernemq already exists, skipping creation"
else
    useradd -s /bin/bash -d /var/lib/vernemq -m vernemq
fi

exit 0
```

- `vim DEBIAN/prerm`
```bash
#!/bin/bash
set -e

case "$1" in
    remove|upgrade)
        # 停止服务
        systemctl stop vernemq.service 2>/dev/null || true
        systemctl disable vernemq.service 2>/dev/null || true
        ;;
    deconfigure|failed-upgrade)
        ;;
    *)
        echo "prerm called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac

exit 0
```

#### 1.2.5 生成服务脚本
`vim ./lib/systemd/system/vernemq.service-2.1.2`
```systemd
[Unit]
Description=VerneMQ MQTT Broker
Documentation=https://vernemq.com/
After=network.target
Wants=network-online.target

[Service]
Type=forking
User=vernemq
Group=vernemq

# 设置工作目录
WorkingDirectory=/var/lib/vernemq/2.1.2
Environment=HOME=/var/lib/vernemq/2.1.2
Environment=VERNEMQ_CONFIG=/var/lib/vernemq/2.1.2/etc/vernemq.conf

# 假设您的 vernemq 启动脚本在 bin/ 目录下
ExecStart=/var/lib/vernemq/2.1.2/bin/vernemq start
ExecStop=/var/lib/vernemq/2.1.2/bin/vernemq stop
ExecReload=/var/lib/vernemq/2.1.2/bin/vernemq restart

# PID 文件路径（根据您的 vernemq 配置调整）
PIDFile=/var/run/vernemq/vernemq.pid

# 重启策略
Restart=on-failure
RestartSec=5s
StartLimitInterval=60s
StartLimitBurst=3

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

# 日志配置
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vernemq

# 安全选项
ProtectSystem=strict
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 创建必要的运行时目录
RuntimeDirectory=vernemq
RuntimeDirectoryMode=0750
StateDirectory=vernemq
StateDirectoryMode=0750
LogsDirectory=vernemq
LogsDirectoryMode=0750
ConfigurationDirectory=vernemq
ConfigurationDirectoryMode=0750

[Install]
WantedBy=multi-user.target
```

#### 1.2.6 打包脚本
`vim ./build-deb.sh`
```bash
#!/bin/bash
set -e

VER=$1
if [ "$VER" == "" ]; then
    echo "Usage $0 <version>"
    echo "    which valid version are: 1.13.0 or 2.1.2"
    exit -1
fi

DEB_NAME=vernemq-$VER-trixie.x86_64.deb
ROOT=var/lib/vernemq
MQ_HOME=$ROOT/$VER

# 清理旧的构建
rm -rf deb-build
[ -f dist/$DEB_NAME ] && rm -rf dist/$DEB_NAME

# 创建目录结构
[ ! -d ./dist ] && mkdir ./dist
mkdir -p deb-build/DEBIAN
mkdir -p deb-build/$MQ_HOME
mkdir -p deb-build/lib/systemd/system

# 复制控制文件
# cp DEBIAN/* deb-build/DEBIAN/
cp DEBIAN/control-$VER deb-build/DEBIAN/control
cp DEBIAN/preinst deb-build/DEBIAN/
cp DEBIAN/postinst-$VER deb-build/DEBIAN/postinst
cp DEBIAN/prerm deb-build/DEBIAN/
cp DEBIAN/postrm deb-build/DEBIAN/
chmod 755 deb-build/DEBIAN/preinst
chmod 755 deb-build/DEBIAN/postinst
chmod 755 deb-build/DEBIAN/prerm
chmod 755 deb-build/DEBIAN/postrm

# 复制 systemd 服务文件
cp lib/systemd/system/vernemq.service-$VER deb-build/lib/systemd/system/vernemq.service

# 复制您的 vernemq 编译文件
# 请将 /path/to/your/vernemq/build 替换为实际的编译路径
echo "Copying your compiled VerneMQ files..."
cp -r $MQ_HOME/* deb-build/$MQ_HOME/

# 设置正确的权限
find deb-build/$MQ_HOME -type f -exec chmod 644 {} \;
find deb-build/$MQ_HOME -type d -exec chmod 755 {} \;
chmod 755 deb-build/$MQ_HOME/bin/* 2>/dev/null || true
chmod 755 deb-build/$MQ_HOME/erts-15.2.7/bin/* 2>/dev/null || true

# 构建 .deb 包
dpkg-deb --build deb-build dist/$DEB_NAME

# 检查包
echo "Package built: ${DEB_NAME}"
echo "Checking package contents..."
dpkg -c dist/$DEB_NAME
```

#### 1.2.7 开始打包
```bash
sudo ./build-deb.sh 2.1.2
```
若一切正常，打好的包在`./dist/vernemq-2.1.2-trixie.x86_64.deb`

### 1.3 安装 vernemq-2.1.2

#### 1.3.1 安装依赖包

```bash
sudo apt -y install libsnappy-dev libssl-dev
```

#### 1.3.2 安装 vernemq-2.1.2

```bash
sudo dpkg -i /path/to/vernemq-2.1.2-trixie.x86_64.deb
```

这将在目标系统中：
1. 创建一个无特权用户 `vernemq`
2. 将 `vernemq-2.1.2` 安装到 `/var/lib/vernemq/2.1.2` 

#### 1.3.3 配置vernemq的账号和权限
```bash
sudo -u vernemq /var/lib/vernemq/2.1.2/bin/vmq-passwd \ 
     -c /var/lib/vernemq/2.1.2/etc/passed <user-name>
```
根据提示，输入账号的密码

#### 1.3.4 修改配置，准备加入集群
在每台`vernemq`节点上修改配置文件 `/var/lib/vernemq/2.1.2/etc/vernemq.conf`
```properties
# 找到 listener.vmq.clustering 配置项，将其值改为节点的真正ip地址，如
listener.vmq.clustering = 192.168.3.61:44053

# 找到 nodename 配置项，也改成节点的真正ip地址，如
nodename = VerneMQ@192.168.3.61
```
重启 `vernemq`
```bash
sudo systemctl restart vernemq
```

#### 1.3.5 加入集群
假设我们有3个 `vernemq` 节点，分别是 `192.168.3.61 - 63`，在任意两个节点(如62、63)下执行
```bash
sudo -u vernemq /var/lib/vernemq/2.1.2/bin/vmq-admin \
     cluster join discovery-node=VerneMQ@192.168.3.61
```
这表示将当前节点添加到 `discovery-node` 参数指定的节点上。

现在可以通过浏览器 `http://<node-ip>:8888/status` 查看 `vernemq` 的集群状态

## 2. HaProxy
### 2.1 安装 HaProxy
在另外一台节点（如 `192.168.3.60`)上安装 `HaProxy`
```bash
sudo apt -y install haproxy
```

### 2.2 配置 Haproxy
`sudo vim /etc/haproxy/haproxy.cfg`
```properties
global
    log /var/log/haproxy.log local0
    log /var/log/haproxy.log  local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5000
    timeout client 1h
    timeout server 1h
    timeout tunnel 24h
    #timeout http-keep-alive 10s
    #timeout check 10s

frontend mqtt_frontend
    bind *:1883
    default_backend mqtt_backend

backend mqtt_backend
    # 轮询
    balance roundrobin
    option tcp-check
    tcp-check connect port 1883

    server mosquitto01 192.168.3.61:1883 check inter 5s rise 2 fall 3
    server mosquitto02 192.168.3.62:1883 check inter 5s rise 2 fall 3
    server mosquitto03 192.168.3.63:1883 check inter 5s rise 2 fall 3

listen stats
    bind *:8080
    mode http
    stats enable
    stats uri /haproxy?stats
    stats realm Haproxy\ Statistics
    stats auth <user>:<password>
    stats hide-version
```

重启 `Haproxy`
```bash
sudo systemctl restart haproxy
```
