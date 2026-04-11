# Bevy Debug Client

一个面向当前 `ex_mmo_cluster` 服务端状态的 **Bevy 2D 联调客户端**。

## 当前支持

- TCP 连接 gate
- token 认证
- 进入场景
- 2D AOI 可视化
- 移动同步
- 场景内聊天
- 简单技能（默认技能 ID `1`）

## 启动前准备

先准备 token，并设置环境变量：

```bash
export HEMI_GATE_ADDR=127.0.0.1:29000
export HEMI_USERNAME=tester
export HEMI_CID=42
export HEMI_TOKEN='<你的 token>'
```

> 当前客户端不内置网页登录；推荐先通过现有 auth 流程获取 token，再启动客户端。

## 运行

```bash
cd clients/bevy_client
cargo run
```

如果当前环境访问 crates.io 很慢，可以临时改用 sparse 镜像：

```bash
CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
CARGO_REGISTRIES_CRATES_IO_INDEX='sparse+https://rsproxy.cn/index/' \
cargo run
```

## 操作

- `W/A/S/D` 或方向键：移动
- `Enter`：切换聊天输入 / 发送聊天
- `Esc`：取消聊天输入
- `1`：施放简单技能

## 说明

- 当前实现是 **TCP-first** 联调切片。
- UDP fast-lane 尚未在客户端侧接入。
- 聊天和技能是本次实现补入的最小 server-backed slice，不代表完整 MMO 玩法系统已经成熟。
