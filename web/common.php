<?php
/**
 * YSign 在线签名 —— 任务处理工具函数
 */

require_once __DIR__ . '/config.php';

/** 创建一个新任务，返回 [taskId, taskDir] */
function task_create(): array
{
    if (!is_dir(STORAGE_DIR)) {
        mkdir(STORAGE_DIR, 0755, true);
    }
    $id = bin2hex(random_bytes(8));
    $dir = STORAGE_DIR . '/' . $id;
    mkdir($dir, 0755, true);
    return [$id, $dir];
}

/** 读取任务元数据（meta.json），不存在返回 null */
function task_load(string $id): ?array
{
    // 任务 ID 只允许十六进制字符，防止目录穿越
    if (!preg_match('/^[0-9a-f]{16}$/', $id)) {
        return null;
    }
    $file = STORAGE_DIR . '/' . $id . '/meta.json';
    if (!is_file($file)) {
        return null;
    }
    $meta = json_decode((string) file_get_contents($file), true);
    return is_array($meta) ? $meta : null;
}

/** 写入任务元数据 */
function task_save(string $dir, array $meta): void
{
    $meta['updated'] = time();
    file_put_contents($dir . '/meta.json', json_encode($meta, JSON_UNESCAPED_UNICODE));
}

/** 清理超过保留时长的过期任务 */
function task_cleanup(): void
{
    if (!is_dir(STORAGE_DIR)) {
        return;
    }
    foreach (glob(STORAGE_DIR . '/*', GLOB_ONLYDIR) as $dir) {
        if (filemtime($dir) < time() - TASK_TTL) {
            foreach (glob($dir . '/*') as $f) {
                @unlink($f);
            }
            @rmdir($dir);
        }
    }
}

/**
 * 校验上传的文件，非法时返回错误文案，合法返回 null
 */
function upload_check(array $file, int $maxSize, array $allowExt): ?string
{
    if (!isset($file['error']) || is_array($file['error'])) {
        return '上传参数无效';
    }
    switch ($file['error']) {
        case UPLOAD_ERR_OK:
            break;
        case UPLOAD_ERR_INI_SIZE:
        case UPLOAD_ERR_FORM_SIZE:
            return '文件超过服务器限制（需调大 php.ini 的 upload_max_filesize / post_max_size）';
        case UPLOAD_ERR_NO_FILE:
            return '请选择要上传的文件';
        default:
            return '文件上传失败（错误码 ' . $file['error'] . '）';
    }
    if ($file['size'] > $maxSize) {
        return '文件超过大小限制';
    }
    $ext = strtolower(pathinfo($file['name'] ?? '', PATHINFO_EXTENSION));
    if (!in_array($ext, $allowExt, true)) {
        return '不支持的文件类型：.' . $ext;
    }
    return null;
}

/** 保存上传文件到任务目录，返回保存后的路径 */
function upload_save(array $file, string $dir, string $name): string
{
    $dest = $dir . '/' . $name;
    if (!move_uploaded_file($file['tmp_name'], $dest)) {
        throw new RuntimeException('保存上传文件失败');
    }
    return $dest;
}

/**
 * 从描述文件（mobileprovision，带 XML 头的 plist）中提取字段
 * 返回 [name, bundleId]（提取失败的字段为 null）
 */
function profile_parse(string $path): array
{
    $raw = (string) file_get_contents($path);
    $grab = static function (string $key) use ($raw): ?string {
        if (preg_match('~<key>' . preg_quote($key, '~') . '</key>\s*<string>(.*?)</string>~s', $raw, $m)) {
            return trim(html_entity_decode($m[1], ENT_QUOTES));
        }
        return null;
    };
    return [$grab('Name'), $grab('application-identifier')];
}

/**
 * 调用 zsign 执行签名
 * 注意：-b/-n/-v 修改包标识 / 名称 / 版本号，若你的 zsign 分支不支持这些参数，
 * 用户界面留空对应输入框即可，核心参数 -k/-p/-m/-o/-z 在各分支均一致。
 * 返回 [成功?, 日志]
 */
function zsign_run(
    string $ipaPath,
    string $p12Path,
    string $p12Pass,
    string $provPath,
    ?string $bundleId,
    ?string $displayName,
    ?string $version,
    string $outPath,
    string $workDir
): array {
    $cmd = escapeshellarg(ZSIGN_PATH)
        . ' -k ' . escapeshellarg($p12Path)
        . ' -p ' . escapeshellarg($p12Pass)
        . ' -m ' . escapeshellarg($provPath);
    if ($bundleId !== null && $bundleId !== '') {
        $cmd .= ' -b ' . escapeshellarg($bundleId);
    }
    if ($displayName !== null && $displayName !== '') {
        $cmd .= ' -n ' . escapeshellarg($displayName);
    }
    if ($version !== null && $version !== '') {
        $cmd .= ' -v ' . escapeshellarg($version);
    }
    $cmd .= ' -z 9 -o ' . escapeshellarg($outPath) . ' ' . escapeshellarg($ipaPath) . ' 2>&1';

    exec('cd ' . escapeshellarg($workDir) . ' && ' . $cmd, $output, $code);
    $log = implode("\n", $output);

    $ok = is_file($outPath) && filesize($outPath) > 0;
    return [$ok, $log ?: ('zsign 退出码 ' . $code)];
}

/** 页面公共头部（统一品牌样式） */
function page_head(string $title): void
{
    $h = htmlspecialchars($title, ENT_QUOTES);
    echo <<<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{$h} - YSign 在线签名</title>
<style>
:root {
    --primary: #0D9488; --primary-light: #14B8A6; --primary-deep: #0F766E;
    --primary-soft: #E6FAF5; --bg: #F6F8FA; --card: #FFFFFF;
    --text: #0F172A; --sub: #475569; --muted: #94A3B8; --line: #E2E8F0;
    --danger: #DC2626; --danger-soft: #FFF1F3; --success: #16A34A;
    --shadow-md: 0 6px 16px rgba(15,23,42,.08), 0 2px 6px rgba(15,23,42,.04);
    --shadow-lg: 0 24px 48px rgba(15,23,42,.12), 0 10px 20px rgba(15,23,42,.06);
}
@media (prefers-color-scheme: dark) {
    :root {
        --primary: #2DD4BF; --primary-light: #5EEAD4; --primary-deep: #14B8A6;
        --primary-soft: rgba(45,212,191,.12); --bg: #0B121E; --card: #16202B;
        --text: #E8EEF4; --sub: #9AA8B8; --muted: #64748B; --line: #26313F;
        --danger: #FF6B8A; --danger-soft: rgba(255,107,138,.12); --success: #4ADE80;
        --shadow-md: 0 10px 24px rgba(0,0,0,.35); --shadow-lg: 0 30px 60px rgba(0,0,0,.45);
    }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Hiragino Sans GB", "Microsoft YaHei", Roboto, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.7;
    padding: 48px 20px 64px; -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 640px; margin: 0 auto; }
.brand { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
.logo {
    width: 40px; height: 40px; border-radius: 11px;
    background: linear-gradient(135deg, var(--primary), var(--primary-light));
    color: #fff; display: flex; align-items: center; justify-content: center;
    font-weight: 800; font-size: 19px;
    box-shadow: 0 8px 20px rgba(20,184,166,.35);
}
.brand h1 { font-size: 21px; }
.sub { color: var(--sub); font-size: 14px; margin: 6px 0 28px; }
.card {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 16px; padding: 28px; margin-bottom: 20px;
    box-shadow: var(--shadow-md);
}
label { display: block; font-size: 14px; font-weight: 600; margin: 16px 0 6px; }
label:first-child { margin-top: 0; }
label .opt { color: var(--muted); font-weight: 500; font-size: 12px; }
input[type=text], input[type=password] {
    width: 100%; padding: 11px 14px; border-radius: 10px;
    border: 1px solid var(--line); background: var(--bg);
    color: var(--text); font-size: 14px; outline: none;
    transition: border-color .15s;
}
input:focus { border-color: var(--primary-light); }
input[type=file] { width: 100%; font-size: 13px; color: var(--sub);
    padding: 9px 0; }
.hint { font-size: 12px; color: var(--muted); margin-top: 4px; }
details { margin-top: 6px; }
details summary { cursor: pointer; color: var(--primary); font-weight: 600; font-size: 14px; }
.btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    width: 100%; margin-top: 24px; padding: 14px 28px;
    border: 0; border-radius: 12px; cursor: pointer;
    background: linear-gradient(135deg, var(--primary), var(--primary-light));
    color: #fff; font-size: 16px; font-weight: 700;
    box-shadow: 0 12px 24px rgba(20,184,166,.35);
    transition: opacity .15s, transform .15s;
}
.btn:hover:not(:disabled) { opacity: .92; transform: translateY(-1px); }
.btn:disabled { opacity: .55; cursor: default; box-shadow: none; }
a.btn { text-decoration: none; }
.foot { text-align: center; color: var(--muted); font-size: 12px; margin-top: 28px; }
.foot a { color: var(--primary); text-decoration: none; }
.status {
    display: inline-flex; align-items: center; gap: 8px;
    padding: 5px 14px; border-radius: 999px; font-size: 13px; font-weight: 600;
    margin-bottom: 16px;
}
.status.ok { background: rgba(22,163,74,.12); color: var(--success); border: 1px solid rgba(22,163,74,.3); }
.status.fail { background: var(--danger-soft); color: var(--danger); border: 1px solid rgba(220,38,38,.3); }
.info { width: 100%; border-collapse: collapse; margin-top: 6px; }
.info td { padding: 10px 4px; border-bottom: 1px solid var(--line); font-size: 14px; }
.info td:first-child { color: var(--sub); width: 96px; }
.info tr:last-child td { border-bottom: none; }
.log {
    background: var(--bg); border: 1px solid var(--line); border-radius: 10px;
    padding: 14px; font-family: ui-monospace, Menlo, monospace;
    font-size: 12px; color: var(--sub); white-space: pre-wrap;
    word-break: break-all; max-height: 180px; overflow: auto; margin-top: 12px;
}
@media (max-width: 520px) { body { padding: 28px 14px 48px; } .card { padding: 20px; } }
</style>
</head>
<body>
<div class="wrap">
HTML;
}

/** 页面公共底部 */
function page_foot(): void
{
    echo '</div></body></html>';
}
