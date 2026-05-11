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

ipasign.php/signtool.php/signconfig.php
替换/application/api/controller下的文件

udid.mobileconfig/receive.php
在public目录新建文件夹udid，把这两个文件放进去，并修改配置即可