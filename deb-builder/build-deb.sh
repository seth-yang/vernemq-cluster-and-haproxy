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