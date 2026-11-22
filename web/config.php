<?php
/**
 * YSign 在线签名站配置
 *
 * 部署说明：
 * 1. 将本目录部署到支持 PHP 的 HTTPS 站点（itms-services 在线安装必须 HTTPS）
 * 2. 修改下方 SITE_URL 为实际访问地址（末尾不带斜杠）
 * 3. 确保 /usr/bin/zsign 存在且对 PHP 进程可执行
 * 4. storage/ 目录需对 PHP 进程可写（任务文件自动创建，超过保留时长自动清理）
 * 5. IPA 体积较大，php.ini 需调大限制：
 *      upload_max_filesize = 512M
 *      post_max_size = 540M
 *      max_execution_time = 300
 *      memory_limit = 256M
 * 6. 若 nginx 部署，建议禁止外部直接访问 storage/ 目录
 */

// 站点访问地址（末尾不带斜杠），用于生成 itms-services manifest 与下载链接
define('SITE_URL', 'https://your-domain.com');

// zsign 可执行文件路径
define('ZSIGN_PATH', '/usr/bin/zsign');

// 任务存储目录（相对本目录，需可写）
define('STORAGE_DIR', __DIR__ . '/storage/tasks');

// 任务保留时长（秒），过期任务在下次访问首页时自动清理
define('TASK_TTL', 86400);

// 上传大小限制（字节）：IPA / 证书 / 描述文件
define('MAX_IPA_SIZE', 512 * 1024 * 1024);
define('MAX_CERT_SIZE', 1 * 1024 * 1024);

// 站点名称
define('SITE_NAME', 'YSign 在线签名');
