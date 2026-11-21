<?php
/**
 * UDID 回调接收
 * iOS 安装描述文件后 POST 设备信息到此脚本，解析 UDID 后重定向回 App
 */
$body = file_get_contents('php://input');
$udid = '';

if (!empty($body)) {
    if (preg_match('/<key>UDID<\/key>\s*<string>([^<]+)<\/string>/', $body, $m)) {
        $udid = trim($m[1]);
    }
}

if (!empty($udid)) {
    header('HTTP/1.1 301 Moved Permanently');
    header('Location: ysign://?udid=' . urlencode($udid));
    exit;
}

header('Content-Type: text/html; charset=utf-8');
echo '<h3>UDID 获取失败，请重试</h3><a href="ysign://">返回 YSign</a>';
