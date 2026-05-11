<?php

namespace app\api\controller;

use think\Request;
use think\Db;
use app\common\controller\Api;
use MingYuanYun\AppStore\Client;

class Signtool extends Api
{
    protected $noNeedLogin = ["*"];
    protected $noNeedRight = ["*"];

    public function index()
    {
        if ($this->request->isPost()) {
            $bundleId = $this->request->post('app_bundle_id');
            if (empty($bundleId)) {
                return $this->error('缺少必要参数');
            }

            // 1) 优先按 bundle id 精确匹配（关闭强缓存，避免配置更新后 1h 不生效）
            $signTool = Db::name('signtool')
                ->where('app_bundle_id', $bundleId)
                ->find();

            // 2) 兼容回退：根据当前 host 子域 short_site 匹配
            if (!$signTool) {
                $host = strtolower($_SERVER['HTTP_HOST'] ?? '');
                $parts = explode('.', $host);
                if (count($parts) > 2) {
                    $shortSite = $parts[0];
                    $signTool = Db::name('signtool')
                        ->where('short_site', $shortSite)
                        ->order('id desc')
                        ->find();
                }
            }

            // 3) 最后回退：如果系统只有一条贴牌配置，直接使用该配置
            if (!$signTool) {
                $count = Db::name('signtool')->count();
                if ((int)$count === 1) {
                    $signTool = Db::name('signtool')->order('id desc')->find();
                }
            }

            if ($signTool) {
                $config = [
                    "domain"        => $_SERVER['HTTP_HOST'],
                    "app_bundle_id" => $bundleId,
                    "config"        => [
                        "app_icon_url"            => $signTool["app_icon_url"],
                        "app_launch_icon_url"     => $signTool["app_launch_icon_url"] ?? "",
                        "app_name"                => $signTool["app_name"] ?: "星盛签",
                        "buy_url"                 => $signTool["buy_url"] ?: "https://www.baidu.com",
                        "contact_url"             => $signTool["contact_url"] ?: "https://www.baidu.com",
                        "default_app_source_urls" => $signTool["default_app_source_urls"],
                        "exchange"                => (bool) $signTool["exchange"],
                        "group"                   => $signTool["group"] ?: "https://www.baidu.com",
                        "import_permissions"      => (bool) $signTool["import_permissions"],
                        "notice"                  => $signTool["notice"],
                        "whitelist"               => (bool) $signTool["whitelist"],
                        "tutorial_url"            => $signTool["tutorial_url"] ?: "https://www.baidu.com",
                        "plist_url"               => $signTool["plist_url"] ?: "https://".$_SERVER['HTTP_HOST']."/sign_plist.php",
                        "app_source_urls_qx"      => true,
                    ],
                ];
                
                return $this->success('获取成功', $config);
            }
            
            return $this->error('未找到对应配置');
        }
        
        return $this->error('请求方式错误');
    }
    
    public function udid() {
        if ($this->request->isPost()) {
            $data = $this->request->post();
            $udids = $data['udids'];
            foreach ($udids as $udid) {
                $device = Db::table('fa_deviceslist')
                    ->where('udid', $udid)
                    ->where('zt', "normal")
                    ->find();
                    
                if ($device) {
                    $base64MobileProvision = $device["base64mp"];
                    if ($base64MobileProvision == '') {
                        continue;
                    }
                    $base64P12 = $device["base64p12"];
                    $certificateId = $device["kid"];
                    $tempPath = "temp";
                    if (!file_exists($tempPath)) {
                        mkdir($tempPath);
                    }
                    $locale = "zh_CN.UTF-8";
                    setlocale(LC_ALL, $locale);
                    putenv("LC_ALL=" . $locale);
                    $p12Path = $tempPath . "/" . $certificateId . ".p12";
                    $p12pw = "1";
                    $mpPath = $tempPath . "/" . $certificateId . ".mobileprovision";
                    file_put_contents($p12Path, base64_decode($base64P12));
                    file_put_contents($mpPath, base64_decode($base64MobileProvision));
                    $res = new \tools\Checker($p12Path,$p12pw,$mpPath);
                    $data = $res->contents();
                    $data= json_decode($data,true);
                    if($data['code']==1){
                        $pname=$data['CertificationName'];
                        $expiryDate=$data['LocalEndDate'];
                        $ProvisionUUID =$data['ProvisionUUID'];
                        $serial=$data['Serial'];
                        
                        $date = new \DateTime();
                        $date->setTimestamp($expiryDate);
                        $formattedDate = $date->format('Y-m-d\TH:i:s\Z');
                        
                        return json_encode([
                          "code" => 0,
                          "msg" => "成功",
                          "data" => [
                            "profiles" => [
                              [
                                "profile_id" => $device["deviceid"],
                                "uuid" => $ProvisionUUID,
                                "name" =>  $device["udid"],
                                "type" => "IOS_APP_ADHOC",
                                "status" => $device["zt"] == "normal" ? "正常" : "掉签",
                                "using" => true,
                                "devices" =>  [
                                  $device["udid"]
                                ],
                                "expiration_date" => $formattedDate, // "2025-06-20T11:22:34Z",
                                "certificate" => [
                                  [
                                    "name" => $pname, // "iOS Distribution: Xiaotao Zhu",
                                    "id" => $device["kid"], //"CVJ4DMLQJ3",
                                    "country" => "US"
                                  ]
                                ]
                              ]
                            ]
                          ],
                          "time" => time()
                        ]);
                    }
                }
                
            }
            
        }
    }
    
    public function getcertificate() {
        if ($this->request->isPost()) {
            $data = $this->request->post();

            // 支持按 profile_id 或 udid 查询
            $device = null;
            if (!empty($data['profile_id'])) {
                $device = Db::table('fa_deviceslist')
                    ->where('deviceid', $data['profile_id'])
                    ->where('zt', "normal")
                    ->find();
            } elseif (!empty($data['udid'])) {
                $device = Db::table('fa_deviceslist')
                    ->where('udid', $data['udid'])
                    ->where('zt', "normal")
                    ->order('id desc')
                    ->find();
            }

            if ($device && $device['base64mp'] != '' && $device['base64p12'] != '') {
                return json_encode([
                    "code" => 0,
                    "msg" => "成功",
                    "data" => [
                        "mobileprovision" => $device["base64mp"],
                        "p12" => $device["base64p12"],
                        "p12_password" => "1"
                    ]
                ]);
            }

            return json_encode(["code" => 1, "msg" => "未找到有效证书", "data" => null]);
        }
    }
}
