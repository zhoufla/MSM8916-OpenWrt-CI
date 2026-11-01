# jz02v10 无线配置模板
# 由 jz02/gen-wireless.sh 渲染成 openwrt/files/etc/config/wireless
# 占位符：SSID / 加密方式 / 密码 / disabled，见 gen-wireless.sh
#
# 说明：radio0 的 path 是这块板子 WCNSS 的平台路径，写死没问题（同一块板子）。
# 只把「跟人有关」的东西抽成占位符——SSID / 密码不要进 git。

config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc@0/a204000.remoteproc/remoteproc/remoteproc1/remoteproc1:smd-edge/remoteproc1:smd-edge.WCNSS_CTRL.-1.-1/a204000.remoteproc:smd-edge:wcnss:wifi'
	option band '2g'
	option channel '1'
	option htmode 'HT20'

config wifi-iface 'sta'
	option device 'radio0'
	option mode 'sta'
	option network 'wifiwan'
	option ssid '@WIFI_SSID@'
	option encryption '@WIFI_ENC@'
	option key '@WIFI_PSK@'
	option disabled '@WIFI_DISABLED@'
