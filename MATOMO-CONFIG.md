# 客户端 Matomo 使用统计

GitCode 的 `config.json` 保存 JSON 配置，不能在 JSON 中插入 HTML 或 `<script>`。
客户端使用独立的 HTTPS 请求发送 Matomo 页面访问，不执行远程 JavaScript。

在现有配置的顶层加入以下字段，和 `urls`、`customerService`、`updates` 同级：

```json
"analytics": {
  "enabled": true,
  "provider": "matomo",
  "url": "https://tj.swywl.com/matomo.php",
  "siteId": 2
}
```

与前一个/后一个字段之间必须有逗号。完整可上传示例在 `config/matomo-config.example.json`，保留了用户提供的域名、客服、邀请和 1.2.25 更新信息。发布新安装包时，应另行更新 `updates` 中对应平台的版本、真实下载地址和实际安装包哈希。

## 生效方式

1. 确认 Matomo 后台已有站点 ID `2`，并且 `https://tj.swywl.com/matomo.php` 可以从手机网络通过 HTTPS 访问。
2. 把新增 `analytics` 字段的配置上传到现有 GitCode `config.json`。
3. 安装包含本次接入代码的新客户端，再重新打开应用。旧版 1.2.27 和更早的 APK 不会因为修改 JSON 自动获得统计功能。
4. 在 Matomo 站点 2 中检查页面访问，名称类似 `客户端 / 登录`、`客户端 / 首页`、`客户端 / 节点`、`客户端 / 套餐购买`、`客户端 / 我的`。

本次只修改本地代码和示例，没有向 GitCode 上传配置，也没有向真实 Matomo 服务发送测试访问。

## 统计范围

- 页面访问、访问会话和随机安装标识；各平台通过固定页面路径区分，例如 `https://salmon.app/android/home`，这是统计标签，不是实际访问的网站。
- 首次访问形成一次访问会话；不发送支付金额、订单号、交易结果、节点测速结果或用户浏览的网站。
- 随机安装标识保存在本机，不使用账号 ID、邮箱、设备硬件标识。安装标识不是精确人数，同一用户的不同设备/重新安装可能分别计数。
- 统计服务器会自然收到请求的来源 IP 和 HTTP 元信息，客户端不发送账号、密码、认证令牌或订阅链接。
- 仅在本次运行成功取得 GitCode 统计配置后发送；没有统计配置或 GitCode 取不到配置时不发送。

## 开关与稳定性

- 配置 `enabled: false`，或删除 `analytics` 字段，可在客户端下次取得配置后停止统计。
- 按产品要求，客户端设置页不再显示“使用统计”条目；统计仍受远程配置控制。旧版本保存的本地关闭设置继续有效，GitCode 不能覆盖。
- 统计请求与登录/下单使用独立网络客户端，不共享认证头，不自动跟随重定向，不重试；单次最多 3 秒，同时最多 3 个请求。页面切换不等待统计结果。
- 同一实例的并发 GitCode 配置读取合并为一次，避免启动统计与登录同时拉取配置时重复请求。

技术参考：Matomo 官方 HTTP Tracking API（`https://developer.matomo.org/api-reference/tracking-api`）。
