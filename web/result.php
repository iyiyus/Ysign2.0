<?php
/**
 * YSign 在线签名 —— 结果页
 *
 * 签名成功：展示应用信息 + itms-services 在线安装按钮 + IPA 下载
 * 签名失败：展示错误日志
 */

require_once __DIR__ . '/common.php';

$id = (string) ($_GET['id'] ?? '');
$meta = task_load($id);

page_head('签名结果');

if ($meta === null) {
    echo '<div class="card"><div class="status fail">✕ 任务不存在或已过期</div>'
        . '<p style="color:var(--sub);font-size:14px;margin-top:10px;">任务文件保留 '
        . round(TASK_TTL / 3600) . ' 小时，超时会被自动清理。</p>'
        . '<a class="btn" href="sign.php">返回重新签名</a></div>';
    page_foot();
    return;
}

$ok = ($meta['status'] ?? '') === 'success';
?>
<div class="brand">
    <div class="logo">Y</div>
    <h1><?= $ok ? '签名完成' : '签名失败' ?></h1>
</div>

<?php if ($ok): ?>
<div class="card">
    <div class="status ok">✓ 签名成功，可以安装了</div>
    <table class="info">
        <tr><td>应用名称</td><td><?= htmlspecialchars((string) $meta['title'], ENT_QUOTES) ?></td></tr>
        <tr><td>Bundle ID</td><td><?= htmlspecialchars((string) ($meta['bundle_id'] ?? '—'), ENT_QUOTES) ?></td></tr>
        <?php if (!empty($meta['version'])): ?>
        <tr><td>版本</td><td><?= htmlspecialchars((string) $meta['version'], ENT_QUOTES) ?></td></tr>
        <?php endif; ?>
        <tr><td>包大小</td><td><?= round((int) $meta['ipa_size'] / 1024 / 1024, 1) ?> MB</td></tr>
    </table>

    <?php
    // itms-services 在线安装（仅 iOS 设备可点，且要求 HTTPS 部署）
    $manifestUrl = SITE_URL . '/manifest.php?id=' . urlencode($id);
    ?>
    <a class="btn" href="itms-services://?action=download-manifest&url=<?= urlencode($manifestUrl) ?>">
        在线安装到本设备
    </a>
    <div class="hint" style="text-align:center;">点击后系统弹出安装确认，请在桌面等待图标出现</div>

    <a class="btn" style="background:var(--card);color:var(--primary);border:1px solid var(--line);box-shadow:none;"
       href="download.php?id=<?= urlencode($id) ?>">下载签名后的 IPA</a>
</div>
<?php else: ?>
<div class="card">
    <div class="status fail">✕ zsign 签名失败</div>
    <p style="color:var(--sub);font-size:14px;">请检查：证书与密码是否匹配、描述文件是否有效且包含目标设备 UDID、Bundle ID 是否与描述文件匹配。</p>
    <div class="log"><?= htmlspecialchars((string) ($meta['log'] ?? ''), ENT_QUOTES) ?></div>
    <a class="btn" href="sign.php">返回修改后重试</a>
</div>
<?php endif; ?>

<div class="foot"><a href="sign.php">继续签名下一个 →</a></div>
<?php page_foot();
