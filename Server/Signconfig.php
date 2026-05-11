<?php
namespace app\api\controller;

class Signconfig extends \app\common\controller\Api
{
    protected $noNeedLogin = array("*");
    protected $noNeedRight = array("*");

    public function Index()
    {
        // 获取当前域名
        $domain = $_SERVER["HTTP_HOST"];
        $host = $_SERVER['HTTP_HOST'];
        if($_GET['token']!="c13a8d9fe27f53c265a1139e0c5fc3af"){
            exit("404 File does not exist");
        }
        Dsign();

        // 获取 appid 参数
        $appid = $_GET["appid"];

        // 获取 udid 和 version 参数
        $udid = $_GET["udid"];
        $version = $_GET["version"];
        $ntime = time();

        // 检查是否有默认 appid
        if (empty($appid)) {
            $appid = "com.iii.iii";
        }

        // 从数据库查询相关信息
        $chkis = \think\Db::table("fa_website")
            ->where("bidname", $appid)
            ->where("bidswitch", 1)
            ->order("id desc")
            ->select();

        if (!$chkis) {
            return json(["code" => 0, "msg" => "未找到相关配置", "data" => []]);
        }

        $id = $chkis[0]["user_id"];

        // 检查某个字段是否为 false
        if ($chkis[0]["checkudidswitch"]!== false) {
            // 这里的逻辑后续可以根据具体需求完善
        }

        // 从数据库查询用户名
        $chname = \think\Db::table("fa_user")
            ->where("id", $id)
            ->order("id desc")
            ->select();
        $username = $chname[0]["username"];

        // 从数据库查询设备相关信息
        $chudid = \think\Db::table("fa_devicelist")
            ->where("udid", $udid)
            ->where("rt", "normal")
            ->where("rt", "normal")
            ->order("id desc")
            ->select();

        if (!$chudid) {
            return json(["code" => 0, "msg" => "该 UDID 不是有效使用设备", "data" => []]);
        }

        $siteid = $chkis[0]["id"];
        $plist = $chkis[0]["plistswitch"];

        $plisturl = "";
        if ($plist == 1) {
            $plisturl = "cer.aaaa";
        } else {
            $plisturl = $chkis[0]["siteurl"];
        }

        $certapi = "";
        if ($appid == "com.aaa.aaa") {
            $certapi = "/api/certall";
        } else {
            $certapi = "/api/certwqa";
        }

        // 检查某个时间字段是否大于当前时间
        if ($chkis[0]["endtime"] > $ntime) {
            $appstore = $chkis[0]["appstore"] == true? $chkis[0]["appstore"] : "";
        } else {
            return json(["code" => 0, "msg" => "应用已过期", "data" => []]);
        }

        $data = [
            "domain" => $chkis[0]["siteurl"],
            "app_bundle_id" => $appid,
            "config" => [
                "id" => 0,
                "app_tqpe" => 0,
                "app_name" => $chkis[0]["appname"],
                "fip_time" => $chkis[0]["appname"],
                "default_app_source_urls" => $appstore,
                "app_source_urls_ap" => false,
                "import_app_sources" => $chkis[0]["inappstoreswitch"],
                "qq_url" => str_replace("&amp;", "&", $chkis[0]["qq"]),
                "contact_url" => str_replace("&amp;", "&", $chkis[0]["contact"]),
                "buy_url" => str_replace("&amp;", "&", $chkis[0]["buy"]),
                "buy_app" => str_replace("&amp;", "&", $chkis[0]["buy"]),
                "jc_url" => str_replace("&amp;", "&", $chkis[0]["jc"]),
                "mr_url" => "",
                "import_permissions" => $chkis[0]["importswitch"],
                "export_permissions" => $chkis[0]["expswitch"],
                "timelock" => $chkis[0]["timelockswitch"],
                "ver" => "1.2.0",
                "notice" => "",
                "plisturl" => $plisturl,
                "cert_search_url" => $certapi
            ]
        ];

        return json(["code" => 1, "msg" => "获取成功", "data" => $data]);
    }
}