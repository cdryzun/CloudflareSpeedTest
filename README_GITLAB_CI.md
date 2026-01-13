# GitLab CI 快速开始指南

使用 GitLab CI 实现自动化 DNS 更新，无需手动运行脚本。

## 快速配置（仅需 3 步）

### 步骤 1：设置环境变量

在 GitLab 项目中进入：Settings → CI/CD → Variables

添加以下两个必需变量：

```
KEY = your_cloudflare_api_token  (勾选 Protected 和 Masked)
NAME = szddns.coderyzun.cyou
```

说明：
- KEY：Cloudflare API Token，建议勾选 Protected 和 Masked 保护密钥安全
- NAME：要更新的域名

### 步骤 2：创建定时任务

在 GitLab 项目中进入：CI/CD → Schedules → New schedule

填写以下信息：

```
Description: 自动更新 DNS
Interval Pattern: 0 */2 * * *
Target branch: master
```

说明：
- Description：任务描述，可自定义
- Interval Pattern：运行频率，`0 */2 * * *` 表示每 2 小时运行一次
- Target branch：目标分支，通常是 main 或 master

### 步骤 3：完成配置

配置完成后，定时任务会自动运行，无需任何手动操作。

---

## 详细文档

查看完整配置指南：[GITLAB_CI_SETUP.md](../GITLAB_CI_SETUP.md)

---

## 常用定时表达式

| Cron 表达式 | 说明 |
|-------------|------|
| `0 */2 * * *` | 每 2 小时运行一次（整点：0点、2点、4点...） |
| `*/2 * * * *` | 每 2 小时运行一次（从任意时间开始） |
| `0 */6 * * *` | 每 6 小时运行一次 |
| `0 2 * * *` | 每天凌晨 2 点运行 |
| `0 */4 * * 1-5` | 工作日（周一到周五）每 4 小时运行一次 |

在线生成工具：https://crontab.guru/

---

## 查看运行状态

按以下步骤查看任务运行情况：

1. 在 GitLab 项目中进入 CI/CD → Pipelines
2. 查看最新的 Pipeline 状态（运行中、成功、失败）
3. 点击具体任务查看详细运行日志
4. 下载 artifacts 获取测速结果文件

---

## 环境变量详细说明

| 变量名 | 是否必填 | 默认值 | 说明 |
|--------|----------|--------|------|
| `KEY` | 必填 | - | Cloudflare API Token |
| `NAME` | 必填 | - | 要更新的域名 |
| `TYPE` | 可选 | A | DNS 记录类型（A 或 AAAA） |
| `TTL` | 可选 | 60 | DNS 记录 TTL 值（秒） |
| `PROXIED` | 可选 | false | 是否启用 CDN 代理 |
| `IP_COUNT` | 可选 | 10 | 更新的 IP 数量 |

---

## 常见问题

**问题 1：Pipeline 不运行？**

解决方法：
- 检查 Schedule 是否已激活（Activated 状态应为启用）
- 确认分支名称是否正确（main 或 master）
- 检查是否有足够的 CI/CD 分钟数配额

**问题 2：环境变量未生效？**

解决方法：
- Protected 变量只能在受保护分支上使用，请检查分支保护设置
- 如果不需要保护，可以取消 Protected 标记
- 确认变量名称拼写正确（区分大小写）

**问题 3：如何手动运行？**

两种方法：
- 方法 1：进入 CI/CD → Pipelines → 点击右上角 "Run pipeline" 按钮
- 方法 2：进入 CI/CD → Schedules → 在对应任务旁边点击播放按钮