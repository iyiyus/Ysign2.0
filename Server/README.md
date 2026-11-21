# YSign UDID 服务端

## 部署步骤

1. **修改 `udid.mobileconfig`** 中的回调 URL：把 `https://你的域名/udid/receive.php` 替换为你的实际域名
2. 将 `udid.mobileconfig` 和 `receive.php` 上传到你的 **HTTPS** 服务器
3. 在 YSign App → 设备 UDID → 配置地址，填入：`https://你的域名/udid.mobileconfig`

## 文件说明

| 文件 | 作用 |
|------|------|
| `udid.mobileconfig` | 静态描述文件，Safari 直接下载安装 |
| `receive.php` | 接收 iOS POST 的设备信息，解析 UDID 后重定向回 App |

## 流程

```
App 点击「获取 UDID」
        ↓
Safari 打开 https://你的域名/udid.mobileconfig
        ↓
用户去「设置」安装描述文件
        ↓
iOS POST 设备信息到 receive.php
        ↓
receive.php 解析 UDID → 301 重定向到 ysign://?udid=xxx
        ↓
App 接收并保存 UDID
```

## 服务器目录结构

```
/var/www/html/udid/
├── udid.mobileconfig    ← 直接访问下载
└── receive.php          ← iOS 回调端点
```

App 中配置的地址：`https://你的域名/udid/udid.mobileconfig`
