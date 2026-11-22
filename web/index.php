<?php
/**
 * YSign 在线签名 —— 营销首页
 *
 * 品牌展示 + 特性介绍 + 下载与在线签名入口，风格与 YSign App 一致。
 * 上传签名表单在 sign.php。
 */

require_once __DIR__ . '/common.php';

task_cleanup();
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>YSign 在线签名 · 上传 IPA，几十秒装到手机</title>
<style>
:root {
    --primary: #0D9488; --primary-light: #14B8A6; --primary-deep: #0F766E;
    --primary-soft: #E6FAF5; --bg: #F6F8FA; --card: #FFFFFF;
    --text: #0F172A; --sub: #475569; --muted: #94A3B8; --line: #E2E8F0;
    --shadow-md: 0 6px 16px rgba(15,23,42,.08), 0 2px 6px rgba(15,23,42,.04);
    --shadow-lg: 0 24px 48px rgba(15,23,42,.12), 0 10px 20px rgba(15,23,42,.06);
}
@media (prefers-color-scheme: dark) {
    :root {
        --primary: #2DD4BF; --primary-light: #5EEAD4; --primary-deep: #14B8A6;
        --primary-soft: rgba(45,212,191,.12); --bg: #0B121E; --card: #16202B;
        --text: #E8EEF4; --sub: #9AA8B8; --muted: #64748B; --line: #26313F;
        --shadow-md: 0 10px 24px rgba(0,0,0,.35); --shadow-lg: 0 30px 60px rgba(0,0,0,.45);
    }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Hiragino Sans GB", "Microsoft YaHei", Roboto, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.7;
    -webkit-font-smoothing: antialiased;
}
.container { max-width: 900px; margin: 0 auto; padding: 0 24px; }

.brand { display: flex; align-items: center; gap: 12px; padding: 22px 0; }
.logo {
    width: 40px; height: 40px; border-radius: 11px; flex-shrink: 0;
    background: linear-gradient(135deg, var(--primary), var(--primary-light));
    color: #fff; display: flex; align-items: center; justify-content: center;
    font-weight: 800; font-size: 19px;
    box-shadow: 0 8px 20px rgba(20,184,166,.35);
}
.brand h1 { font-size: 20px; }
.brand .nav-sign {
    margin-left: auto; text-decoration: none; color: var(--primary);
    font-size: 14px; font-weight: 600; padding: 8px 16px;
    border: 1px solid var(--line); border-radius: 10px; background: var(--card);
    transition: border-color .15s;
}
.brand .nav-sign:hover { border-color: var(--primary-light); }

.hero { text-align: center; padding: 72px 0 56px; position: relative; }
.hero::before {
    content: ""; position: absolute; inset: 0; pointer-events: none;
    background:
        radial-gradient(circle at 20% 10%, rgba(20,184,166,.14), transparent 40%),
        radial-gradient(circle at 80% 20%, rgba(59,130,246,.10), transparent 45%);
}
.hero > * { position: relative; }
.eyebrow {
    display: inline-flex; align-items: center; gap: 8px;
    padding: 6px 14px; border-radius: 999px;
    background: var(--primary-soft); color: var(--primary);
    font-size: 13px; font-weight: 600;
    border: 1px solid rgba(20,184,166,.35);
    margin-bottom: 20px;
}
.eyebrow .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--primary); box-shadow: 0 0 0 3px rgba(20,184,166,.25); }
.hero-title { font-size: clamp(30px, 5.5vw, 46px); line-height: 1.25; letter-spacing: -0.5px; }
.grad {
    background: linear-gradient(120deg, var(--primary-deep), var(--primary-light));
    -webkit-background-clip: text; background-clip: text; color: transparent;
}
.lead { max-width: 600px; margin: 18px auto 32px; color: var(--sub); font-size: 16px; }
.hero-actions { display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; }
.btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    padding: 13px 28px; border-radius: 12px; text-decoration: none;
    font-size: 15px; font-weight: 700; cursor: pointer; border: 0;
    transition: transform .15s, opacity .15s;
}
.btn-primary {
    background: linear-gradient(135deg, var(--primary), var(--primary-light));
    color: #fff; box-shadow: 0 12px 24px rgba(20,184,166,.35);
}
.btn-primary:hover { transform: translateY(-2px); opacity: .93; }
.btn-ghost { color: var(--primary); border: 1px solid var(--line); background: var(--card); }
.btn-ghost:hover { transform: translateY(-2px); border-color: var(--primary-light); }
.hero-meta { margin-top: 16px; color: var(--muted); font-size: 13px; }

section { padding: 48px 0; }
.section-head { text-align: center; margin-bottom: 36px; }
.section-head h2 { font-size: clamp(22px, 4vw, 30px); letter-spacing: -0.3px; }
.section-head p { color: var(--sub); margin-top: 10px; }

.features { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 18px; }
.card {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 16px; padding: 26px; box-shadow: var(--shadow-md);
    transition: transform .2s, box-shadow .2s;
}
.card:hover { transform: translateY(-3px); box-shadow: var(--shadow-lg); }
.feature .icon {
    width: 46px; height: 46px; border-radius: 12px;
    background: var(--primary-soft); color: var(--primary);
    display: flex; align-items: center; justify-content: center;
    margin-bottom: 14px;
}
.feature h3 { font-size: 16px; margin-bottom: 6px; }
.feature p { color: var(--sub); font-size: 14px; }

.steps { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 18px; counter-reset: step; }
.step { text-align: center; padding: 30px 20px; }
.step::before {
    counter-increment: step; content: counter(step);
    display: inline-flex; align-items: center; justify-content: center;
    width: 42px; height: 42px; border-radius: 50%;
    background: linear-gradient(135deg, var(--primary), var(--primary-light));
    color: #fff; font-weight: 800; font-size: 17px; margin-bottom: 14px;
    box-shadow: 0 8px 18px rgba(20,184,166,.35);
}
.step h3 { font-size: 15px; margin-bottom: 4px; }
.step p { color: var(--sub); font-size: 13px; }

.download-box { text-align: center; padding: 44px 26px; }
.download-box .actions { display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; margin-top: 22px; }

.faq { max-width: 720px; margin: 0 auto; display: grid; gap: 12px; }
details { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px 20px; }
details summary { cursor: pointer; font-weight: 600; font-size: 15px; list-style: none; }
details summary::before { content: "›"; display: inline-block; margin-right: 10px; color: var(--primary); transition: transform .2s; }
details[open] summary::before { transform: rotate(90deg); }
details p { color: var(--sub); font-size: 14px; margin-top: 10px; }

footer { border-top: 1px solid var(--line); padding: 36px 0 44px; text-align: center; color: var(--muted); font-size: 13px; }
footer .links { display: flex; gap: 22px; justify-content: center; margin-bottom: 12px; }
footer .links a { color: var(--sub); text-decoration: none; }
footer .links a:hover { color: var(--primary); }
.disclaimer { max-width: 640px; margin: 10px auto 0; line-height: 1.8; }
@media (max-width: 560px) { .hero { padding: 48px 0 36px; } section { padding: 32px 0; } }
</style>
</head>
<body>
<header class="container">
    <div class="brand">
        <div class="logo">Y</div>
        <h1>YSign 在线签名</h1>
        <a class="nav-sign" href="sign.php">开始签名 →</a>
    </div>
</header>

<div class="hero">
    <div class="container">
    <span class="eyebrow"><span class="dot"></span>开源 · 极速 · 一站式</span>
    <h2 class="hero-title">IPA 在线签名<br><span class="grad">上传 → 签名 → 安装</span></h2>
    <p class="lead">基于 zsign 引擎，上传 IPA 与证书，几十秒完成签名，扫码或点击即可安装到设备。配套 YSign iOS 客户端可全离线签名。</p>
    <div class="hero-actions">
        <a class="btn btn-primary" href="sign.php">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
            开始在线签名
        </a>
        <a class="btn btn-ghost" href="https://github.com/iyiyus/Ysign2.0/releases/latest" target="_blank" rel="noopener">下载 iOS 客户端</a>
    </div>
    <div class="hero-meta">iOS 设备点「开始在线签名」签名后可直接在线安装</div>
    </div>
</div>

<section>
    <div class="section-head">
        <h2>为什么选择 YSign</h2>
        <p>本地客户端 + 在线签名双方案，覆盖所有场景。</p>
    </div>
    <div class="features">
        <div class="card feature">
            <div class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2 3 14h7l-1 8 10-12h-7l1-8z"/></svg></div>
            <h3>极速签名</h3>
            <p>zsign 引擎 + 服务器级硬件，大包几十秒完成，无需本地配置任何环境。</p>
        </div>
        <div class="card feature">
            <div class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="10" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg></div>
            <h3>隐私可控</h3>
            <p>任务文件仅保留 24 小时自动删除；iOS 客户端更可全程离线签名，数据不出设备。</p>
        </div>
        <div class="card feature">
            <div class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><circle cx="12" cy="20" r="1"/></svg></div>
            <h3>在线安装</h3>
            <p>签名完成即生成 itms-services 安装链接，iPhone 点击确认直接装到桌面。</p>
        </div>
        <div class="card feature">
            <div class="icon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><polyline points="9 12 11 14 15 10"/></svg></div>
            <h3>证书安全</h3>
            <p>P12 与描述文件随任务隔离存储，随任务过期一并销毁，不做任何留存。</p>
        </div>
    </div>
</section>

<section style="padding-top:0;">
    <div class="section-head">
        <h2>四步装到手机</h2>
    </div>
    <div class="steps">
        <div class="card step"><h3>获取 UDID</h3><p>设备安装描述文件获取 UDID 并加入证书</p></div>
        <div class="card step"><h3>上传 IPA</h3><p>上传安装包、P12 证书与描述文件</p></div>
        <div class="card step"><h3>自动签名</h3><p>zsign 自动完成重签与打包</p></div>
        <div class="card step"><h3>在线安装</h3><p>点击安装按钮直接装到设备</p></div>
    </div>
</section>

<section style="padding-top:0;">
    <div class="card download-box">
        <h2>两种方式，任选其一</h2>
        <p style="color:var(--sub);font-size:14px;margin-top:8px;">
            <b>在线签名</b>：无需安装任何软件，网页上传即可，适合临时轻量需求。<br>
            <b>iOS 客户端</b>：纯本地签名、文件管理、备份还原、WiFi 传输全部离线完成，适合长期使用。
        </p>
        <br>
        <div style="display:flex;gap:14px;justify-content:center;flex-wrap:wrap;">
            <a class="btn btn-primary" href="sign.php">网页在线签名</a>
            <a class="btn btn-ghost" href="https://github.com/iyiyus/Ysign2.0/releases/latest" target="_blank" rel="noopener">下载 iOS 客户端 v2.0.0</a>
        </div>
    </div>
</section>

<section style="padding-top:0;">
    <div class="section-head"><h2>常见问题</h2></div>
    <div class="faq">
        <details>
            <summary>签名后的应用能安装到哪些设备？</summary>
            <p>取决于你的描述文件：开发证书需要把目标设备的 UDID 加入描述文件；企业证书或某些分发型证书可直接安装。可在 YSign 客户端的「设备 UDID」工具中获取 UDID。</p>
        </details>
        <details>
            <summary>上传的证书和 IPA 安全吗？</summary>
            <p>任务文件相互隔离存储，仅保留 24 小时后自动删除。介意的话可使用 iOS 客户端离线签名，全流程不经过任何服务器。</p>
        </details>
        <details>
            <summary>点击在线安装没反应？</summary>
            <p>在线安装仅支持 iOS 设备，且本站必须以 HTTPS 部署。请确认在 Safari 中打开本页，点击安装后允许系统弹出的确认框。</p>
        </details>
    </div>
</section>

<footer>
    <div class="links">
        <a href="https://github.com/iyiyus/Ysign2.0" target="_blank" rel="noopener">GitHub</a>
        <a href="sign.php">在线签名</a>
    </div>
    <div class="disclaimer">
        YSign 仅供学习与研究使用。任何使用本服务对未授权 IPA 进行修改、签名、分发等行为，由使用者本人承担全部法律责任。
    </div>
</footer>
</body>
</html>

