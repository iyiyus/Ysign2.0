<?php
/**
 * YSign 在线签名 —— 签名产物下载
 * 流式输出签名后的 IPA（大文件不占内存）
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

$path = STORAGE_DIR . '/' . $id . '/signed.ipa';
if (!is_file($path)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'File not found';
    return;
}

$title = preg_replace('/[^0-9A-Za-z\x{4e00}-\x{9fa5}_-]+/u', '_', (string) $meta['title']);
header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="signed.ipa"; filename*=UTF-8\'\'' . rawurlencode($title . '.ipa'));
header('Content-Length: ' . filesize($path));
header('X-Accel-Buffering: no');

// 分块输出，避免大 IPA 撑爆内存
$handle = fopen($path, 'rb');
while (!feof($handle)) {
    echo fread($handle, 256 * 1024);
    flush();
}
fclose($handle);
