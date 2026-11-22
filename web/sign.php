<?php
/**
 * YSign 在线签名 —— 上传签名表单页（由营销首页 index.php 的「开始在线签名」进入）
 *
 * GET  显示上传表单
 * POST 校验上传文件 → 调用 zsign 签名 → 跳转结果页
 */

require_once __DIR__ . '/common.php';

// 每次访问顺手清理过期任务
task_cleanup();

$errors = [];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        // ── 1. 校验上传 ──
        $e = upload_check($_FILES['ipa'] ?? [], MAX_IPA_SIZE, ['ipa']);
        if ($e !== null) { $errors[] = 'IPA 文件：' . $e; }

        $e = upload_check($_FILES['p12'] ?? [], MAX_CERT_SIZE, ['p12']);
        if ($e !== null) { $errors[] = 'P12 证书：' . $e; }

        $e = upload_check($_FILES['prov'] ?? [], MAX_CERT_SIZE, ['mobileprovision', 'provisionprofile']);
        if ($e !== null) { $errors[] = '描述文件：' . $e; }

        if (empty($errors)) {
            $p12Pass = trim((string) ($_POST['p12pass'] ?? ''));
            $bundleId = trim((string) ($_POST['bundle_id'] ?? ''));
            $displayName = trim((string) ($_POST['display_name'] ?? ''));
            $version = trim((string) ($_POST['version'] ?? ''));

            // ── 2. 创建任务并落盘 ──
            [$id, $dir] = task_create();
            $ipaPath = upload_save($_FILES['ipa'], $dir, 'input.ipa');
            $p12Path = upload_save($_FILES['p12'], $dir, 'cert.p12');
            $provPath = upload_save($_FILES['prov'], $dir, 'embedded.mobileprovision');

            // ── 3. 从描述文件提取应用信息（用于结果页与安装 manifest 兜底） ──
            [$profName, $profBundle] = profile_parse($provPath);
            // 修改后的 Bundle ID 优先；留空时使用描述文件里的（去掉 TeamID 前缀）
            $finalBundle = $bundleId;
            if ($finalBundle === '' && $profBundle !== null) {
                $dot = strpos($profBundle, '.');
                $finalBundle = $dot !== false && strlen($profBundle) > $dot + 1
                    ? substr($profBundle, $dot + 1) : $profBundle;
            }
            $finalTitle = $displayName !== '' ? $displayName : ($profName ?? 'App');

            // ── 4. 调用 zsign ──
            $outPath = $dir . '/signed.ipa';
            [$ok, $log] = zsign_run(
                $ipaPath, $p12Path, $p12Pass, $provPath,
                $bundleId !== '' ? $bundleId : null,
                $displayName !== '' ? $displayName : null,
                $version !== '' ? $version : null,
                $outPath, $dir
            );

            // ── 5. 写任务元数据并跳转结果页 ──
            task_save($dir, [
                'id' => $id,
                'status' => $ok ? 'success' : 'failed',
                'log' => mb_substr($log, -4000),
                'title' => $finalTitle,
                'bundle_id' => $finalBundle,
                'version' => $version !== '' ? $version : null,
                'ipa_size' => $ok ? filesize($outPath) : 0,
                'created' => time(),
            ]);
            header('Location: result.php?id=' . $id);
            exit;
        }
    } catch (Throwable $ex) {
        $errors[] = $ex->getMessage();
    }
}

page_head('在线签名');
?>
<div class="brand">
    <div class="logo">Y</div>
    <h1>YSign 在线签名</h1>
</div>
<div class="sub">上传 IPA 与证书，调用 zsign 完成签名后即可在线安装 · 全程 HTTPS</div>

<?php if (!empty($errors)): ?>
<div class="card">
    <?php foreach ($errors as $msg): ?>
        <div class="status fail">✕ <?= htmlspecialchars($msg, ENT_QUOTES) ?></div><br>
    <?php endforeach; ?>
</div>
<?php endif; ?>

<form class="card" method="POST" enctype="multipart/form-data" id="signForm" onsubmit="return submitting()">
    <label>IPA 安装包 <span class="opt">必选</span></label>
    <input type="file" name="ipa" accept=".ipa" required>
    <div class="hint">最大 <?= round(MAX_IPA_SIZE / 1024 / 1024) ?> MB</div>

    <label>P12 签名证书 <span class="opt">必选</span></label>
    <input type="file" name="p12" accept=".p12,.pfx" required>

    <label>证书密码 <span class="opt">无密码可留空</span></label>
    <input type="password" name="p12pass" autocomplete="off">

    <label>描述文件 mobileprovision <span class="opt">必选</span></label>
    <input type="file" name="prov" accept=".mobileprovision,.provisionprofile">

    <details>
        <summary>高级选项（修改应用标识 / 名称 / 版本）</summary>
        <label>Bundle ID</label>
        <input type="text" name="bundle_id" placeholder="留空保持原包标识">
        <div class="hint">需与描述文件匹配，否则设备安装会失败；留空时自动使用描述文件内的标识</div>
        <label>显示名称</label>
        <input type="text" name="display_name" placeholder="留空保持原名">
        <label>版本号</label>
        <input type="text" name="version" placeholder="留空保持原版本">
    </details>

    <button class="btn" type="submit" id="submitBtn">开始签名</button>
</form>

<div class="foot">
    签名任务保留 <?= round(TASK_TTL / 3600) ?> 小时，过期自动删除 ·
    <a href="https://github.com/iyiyus/Ysign2.0" target="_blank" rel="noopener">GitHub</a>
</div>
<script>
function submitting() {
    const btn = document.getElementById('submitBtn');
    btn.disabled = true;
    btn.textContent = '正在签名，请稍候…（IPA 越大耗时越久，请勿关闭页面）';
    return true;
}
</script>
<?php page_foot();
