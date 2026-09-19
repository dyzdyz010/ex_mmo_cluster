# 当前客户端与 CI

CI 的 Test-only 环境由 `prepare-test-fixtures.py` 准备：每次生成独立短期 CA/localhost 证书，提供 E1、I-S 与 M4A 实验参数。历史 R6 清单仅在 CI 临时检出中去掉旧内容版本固定值，用当前 kernel 生成全新测试世界；不修改现有服务器数据。跨应用集成测试从 umbrella 根运行，加载真实 Gate/Scene/World 模块，跨节点用例启用命名 BEAM 节点。场测试分别检查显式导通源与自动派生场，不能把自动光场误算为导通区域。

CI 使用与 Docker 构建一致的 Elixir 1.18.5 / OTP 27.2.4，匹配已锁定并校验哈希的 quicer 0.4.3 OTP27 原生库。开发环境重载正则使用 `\z` 表示字符串结束，保持原有严格结尾语义，同时支持 OTP27 的正则引擎。

服务端直接编译 Voxim 的共享移动内核，并读取其空间常量和协议夹具。`.github/actions/voxim-fixtures` 从固定客户端提交检出这些文件，建立既有代码要求的相邻目录；不在服务端复制常量或造替代夹具。私有客户端仓库通过 `VOXIM_READONLY_DEPLOY_KEY` 只读 deploy key 获取，检出后不保留凭据。更新客户端基线时同步更新 action 中的提交号。

Docker Publish 将同一检出作为 `voxim` 命名构建上下文，提供空间头文件与移动内核。手动构建对应命令：`docker build --build-context voxim=../Voxim .`。该工作流只构建并推送镜像，不执行远端部署。

2026-09-19 故障修复依据：GitHub Actions 的 [checkout 私有仓库与 SSH key 输入](https://github.com/actions/checkout/tree/v4)、Docker 官方 [named contexts](https://docs.docker.com/build/building/context/#named-contexts)，以及本仓 `build_quicer.sh` 的明确 OTP27/架构/哈希约束。此前 CI 的 OTP28 和缺失 `voxim` 上下文均已在真实失败日志中复现。Rust 检查新增 `voxim_worldgen` 的现有测试；格式修复按实际 `mix format --check-formatted` 列表执行。
