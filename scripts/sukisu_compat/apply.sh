#!/usr/bin/env bash
# SukiSU 内核源码 API 兼容补丁（SukiSU-Ultra builtin / main 分支均适用）
#
# 背景：
#   1) builtin 分支 kernel/hook/lsm_hook.c 仍以旧签名
#      security_add_hooks(hooks, count, "ksu") 注册 LSM 钩子，
#      6.8+ 内核要求 (hooks, count, const struct lsm_id *)，
#      android16-6.12 GKI 编译报 -Wincompatible-pointer-types（-Werror）；
#   2) kernel/kpm/super_access.c 引用 netlink_kernel_cfg.cb_mutex，
#      该成员在 Linux 6.11 被上游移除，KPM 开启时 6.11+ 内核编译失败。
#   3) builtin 2026-10-05 同步官方 KernelSU 后 kernel_includes.h
#      引用 arch.h，但该文件只在 main 分支存在，builtin 漏带，
#      所有平台编译报 fatal error: 'arch.h' file not found；
#   4) 同步同时引入两处编译错误：supercall/dispatch.c 引用未定义的
#      EVENT_SERVICES（uapi 头缺常量），selinux/rules.c 在 5.10+ 分支
#      重复声明 pol/old_pol。
#
# 修复均以内容检测守卫，上游自行修复后自动跳过，重复执行幂等。
#
# 用法: apply.sh [KernelSU 目录]（调用方工作目录需为 $KERNEL_ROOT）

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU 兼容补丁已跳过::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API 兼容补丁** 已自动跳过：$1（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "未找到 KernelSU 目录: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 lsm_id 兼容代码，跳过"
  else
    echo "应用 lsm_id 兼容补丁 (6.8+ security_add_hooks 新签名)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "lsm_id 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "lsm_id 兼容补丁应用后校验失败"
    echo "lsm_hook.c: 6.8+ 已切换为 struct lsm_id 注册"
  fi
else
  echo "lsm_hook.c 不存在或无需 lsm_id 兼容补丁，跳过"
fi

SUPER_FILE="$KSU_DIR/kernel/kpm/super_access.c"
if [ -f "$SUPER_FILE" ] && grep -q 'DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)' "$SUPER_FILE"; then
  if grep -q 'KERNEL_VERSION(6, 11, 0)' "$SUPER_FILE"; then
    echo "super_access.c 已包含 cb_mutex 版本守卫，跳过"
  else
    echo "应用 cb_mutex 兼容补丁 (6.11+ 移除 netlink_kernel_cfg.cb_mutex)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-cb-mutex-6.11.patch" \
      || fail "cb_mutex 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'KERNEL_VERSION(6, 11, 0)' "$SUPER_FILE" \
      || fail "cb_mutex 兼容补丁应用后校验失败"
    echo "super_access.c: 6.11+ 已跳过 cb_mutex 成员"
  fi
else
  echo "super_access.c 不存在或无需 cb_mutex 兼容补丁，跳过"
fi

# builtin 分支 2026-10-05 同步官方 KernelSU（70fa0e092）后，
# kernel/kernel_includes.h 引用 #include "arch.h"，但 arch.h 只存在于
# main 分支（kernel/include/arch.h），builtin 漏带导致全部平台编译失败:
#   fatal error: 'arch.h' file not found
# 从本仓库分发 main 分支的 arch.h，检测到缺失时补齐；
# 上游修复（builtin 自带 arch.h）后自动跳过，幂等。
ARCH_REF="$KSU_DIR/kernel/include/arch.h"
if [ -f "$KSU_DIR/kernel/kernel_includes.h" ] && grep -q '#include "arch.h"' "$KSU_DIR/kernel/kernel_includes.h"; then
  if [ -f "$ARCH_REF" ]; then
    echo "arch.h 已存在，跳过补齐"
  else
    echo "补齐缺失的 arch.h（builtin 同步官方 KernelSU 时遗漏）..."
    cp "$COMPAT_DIR/arch.h" "$ARCH_REF" \
      || fail "arch.h 补齐失败"
    grep -q '__KSU_H_ARCH' "$ARCH_REF" \
      || fail "arch.h 补齐后校验失败"
    echo "arch.h: 已补齐 (提供 PT_REGS_* / __ksyscall 所需的架构寄存器宏)"
  fi
else
  echo "kernel_includes.h 不存在或未引用 arch.h，跳过补齐"
fi

# builtin 分支 2026-10-05 同步官方 KernelSU 后遗留的两处编译错误
# （全平台构建在 ksu.c 聚合编译阶段命中）：
#   1) supercall/dispatch.c 引用 EVENT_SERVICES，
#      但 builtin 的 uapi 头只定义了 EVENT 1/2/3，缺 EVENT_SERVICES = 4；
#   2) selinux/rules.c 在 #if >= 5.10 块内重复声明 pol/old_pol
#      （函数开头已声明），C89 风格重定义直接编译失败。
# 以内容检测守卫：主头已含 EVENT_SERVICES 或重复声明已消失时自动跳过，幂等。
DISP_FILE="$KSU_DIR/kernel/supercall/dispatch.c"
RULES_FILE="$KSU_DIR/kernel/selinux/rules.c"
if { [ -f "$DISP_FILE" ] && grep -q 'EVENT_SERVICES' "$DISP_FILE" && \
     ! grep -q 'EVENT_SERVICES' "$KSU_DIR/kernel/include/uapi/supercall.h"; } || \
   { [ -f "$RULES_FILE" ] && grep -q 'struct selinux_policy \*pol, \*old_pol = selinux_state.policy;' "$RULES_FILE"; }; then
  echo "应用 builtin 同步遗留问题修复 (EVENT_SERVICES + rules.c 重复声明)..."
  patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/builtin-sync-fixes.patch" \
    || fail "builtin 同步遗留修复应用失败（SukiSU 上游代码可能已变化）"
  grep -q 'EVENT_SERVICES, 4' "$KSU_DIR/kernel/include/uapi/supercall.h" \
    || fail "EVENT_SERVICES 补齐后校验失败"
  ! grep -q 'struct selinux_policy \*pol, \*old_pol = selinux_state.policy;' "$RULES_FILE" \
    || fail "rules.c 重复声明修复后校验失败"
  echo "EVENT_SERVICES 已补齐; rules.c 重复声明已移除"
else
  echo "builtin 同步遗留问题不存在或已修复，跳过"
fi

echo "SukiSU API 兼容补丁处理完成"
