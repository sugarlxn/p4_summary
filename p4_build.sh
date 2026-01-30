#!/bin/bash
set -e

# =========================
# 环境变量检查函数
# =========================
check_env() {
    local var_name=$1
    local var_value=$2

    if [ -z "$var_value" ]; then
        echo "Error: environment variable $var_name is not set."
        echo "Please run:"
        echo "  export $var_name=/path/to/your/$var_name"
        exit 1
    fi

    if [ ! -d "$var_value" ]; then
        echo "Error: $var_name is set to '$var_value' but directory does not exist."
        exit 1
    fi
}

# =========================
# 检查必要环境变量
# =========================
check_env SDE "$SDE"
check_env SDE_INSTALL "$SDE_INSTALL"

# =========================
# 设置 PATH
# =========================
if [[ ":$PATH:" != *":$SDE_INSTALL/bin:"* ]]; then
    export PATH="$SDE_INSTALL/bin:$PATH"
fi

# =========================
# 设置 LD_LIBRARY_PATH
# =========================
if [[ ":$LD_LIBRARY_PATH:" != *":$SDE_INSTALL/lib:"* ]]; then
    export LD_LIBRARY_PATH="$SDE_INSTALL/lib:$LD_LIBRARY_PATH"
fi

# =========================
# 参数检查
# =========================
if [ -z "$1" ]; then
    echo "Error: no P4 file specified."
    echo "Usage: $0 <p4_file>"
    exit 1
fi

p4file=$1

if [ ! -f "$p4file" ]; then
    echo "Error: P4 file '$p4file' does not exist."
    exit 1
fi

name=$(basename "$p4file" .p4)

echo "======================================"
echo "SDE          : $SDE"
echo "SDE_INSTALL  : $SDE_INSTALL"
echo "PATH         : $PATH"
echo "LD_LIBRARY_PATH : $LD_LIBRARY_PATH"
echo "======================================"

# =========================
# 编译 P4
# =========================
echo "Compiling $p4file ..."

mkdir -p build

"$SDE_INSTALL/bin/bf-p4c" \
  --std p4-16 \
  --target tofino \
  --arch tna \
  -o build/ \
  -I "$SDE_INSTALL/share/p4c/p4include" \
  -I includes/ \
  "$p4file"

# =========================
# 拷贝生成文件
# =========================
conf_file="build/${name}.conf"
target_dir="$SDE_INSTALL/share/p4/targets/tofino"

if [ ! -f "$conf_file" ]; then
    echo "Error: build failed, $conf_file not found."
    exit 1
fi

cp "$conf_file" "$target_dir/"

cp -r build  $SDE_INSTALL/
echo "Done:"
echo "  $target_dir/${name}.conf"

