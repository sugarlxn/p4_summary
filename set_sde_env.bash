#!/bin/bash
# =========================
# 设置 SDE 环境变量
# =========================
export SDE=/root/bf-sde-9.7.0
export SDE_INSTALL=$SDE/install
export PATH=$SDE_INSTALL/bin:$SDE:$PATH
export LD_LIBRARY_PATH=$SDE_INSTALL/lib:$LD_LIBRARY_PATH