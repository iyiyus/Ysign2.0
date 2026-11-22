<?php
/**
 * YSign 在线签名 —— itms-services 安装 manifest
 * 输出 OTA 安装所需的 plist，bundle 信息取自任务元数据（签名时从用户输入 / 描述文件解析）
 */

require_once __DIR__ . '/common.php';

$id = (string) ($_GET['id'] ?? '');
$meta = task_load($id);

if ($meta === null || ($meta['status'] ?? '') !== 'success') {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Task not found';
    return;
}

$ipaUrl = SITE_URL . '/download.php?id=' . urlencode($id);
$bundleId = (string) ($meta['bundle_id'] ?? 'com.ysign.signed');
$version = (string) ($meta['version'] ?? '1.0');
$title = (string) ($meta['title'] ?? 'App');

header('Content-Type: application/xml; charset=utf-8');
echo '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string><?= htmlspecialchars($ipaUrl, ENT_QUOTES) ?></string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string><?= htmlspecialchars($bundleId, ENT_QUOTES) ?></string>
                <key>bundle-version</key>
                <string><?= htmlspecialchars($version, ENT_QUOTES) ?></string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string><?= htmlspecialchars($title, ENT_QUOTES) ?></string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
