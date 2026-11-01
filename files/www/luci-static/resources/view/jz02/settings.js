'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require rpc';
'require ui';

var callRcInit = rpc.declare({
	object: 'rc',
	method: 'init',
	params: [ 'name', 'action' ]
});

var CPU = '/sys/devices/system/cpu/cpufreq/policy0';

/* 温度分区数量因板子而异（本机 6 个），探测到读不到为止。
 * 注意：rpcd 的 ACL 是按 realpath 比对的 —— /sys/class/thermal/thermal_zoneN
 * 实际指向 /sys/devices/virtual/thermal/thermal_zoneN，两个前缀都要在
 * /usr/share/rpcd/acl.d/luci-app-jz02.json 里声明，否则 file.read 返回 6（无权限）。 */
var ZONE_MAX = 10;

/* 与 SMSRelay（internal/sysinfo）保持一致：>=70°C 视为高温标红 */
var TEMP_WARN = 70;

function readOr(path) {
	return fs.read(path).catch(function() { return ''; });
}

function khz(v) {
	var n = parseInt((v || '').trim(), 10);
	if (isNaN(n))
		return '—';
	return (n >= 1000000) ? '%s GHz'.format((n / 1000000).toFixed(2)) : '%d MHz'.format(Math.round(n / 1000));
}

function degC(v) {
	var n = parseInt((v || '').trim(), 10);
	return isNaN(n) ? null : n / 1000;
}

/* 去掉内核的 "-thermal" / "_thermal" 后缀，显示更短 */
function shortName(n) {
	return (n || '').replace(/[-_]thermal$/i, '').trim() || (n || '');
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td', 'width': '30%' }, label),
		E('td', { 'class': 'td' }, value)
	]);
}

return view.extend({
	load: function() {
		var jobs = [
			readOr(CPU + '/cpuinfo_cur_freq'),
			readOr(CPU + '/scaling_governor'),
			readOr(CPU + '/scaling_max_freq'),
			readOr(CPU + '/scaling_min_freq'),
			readOr(CPU + '/scaling_available_frequencies'),
			uci.load('jz02')
		];

		/* 每个 zone 两个 job：type 与 temp，索引固定，便于下方按偏移取回 */
		for (var i = 0; i < ZONE_MAX; i++) {
			jobs.push(readOr('/sys/class/thermal/thermal_zone%d/type'.format(i)));
			jobs.push(readOr('/sys/class/thermal/thermal_zone%d/temp'.format(i)));
		}

		return Promise.all(jobs);
	},

	/* 把 [type, temp] 配对成数组，读不到的 zone 直接跳过 */
	collectTemps: function(data) {
		var out = [];

		for (var i = 0; i < ZONE_MAX; i++) {
			var name = (data[6 + i * 2] || '').trim(),
			    c = degC(data[6 + i * 2 + 1]);

			if (name && c !== null)
				out.push({ name: name, c: c });
		}

		return out;
	},

	/* 参考 SMSRelay 的 readTemp()：按名字关键字归类，不依赖索引顺序。
	 * 换机型时 cpu/gpu/pmic 不会错位。 */
	aggregate: function(temps) {
		var agg = { cpu: null, gpu: null, pmic: null, max: null, maxName: '' };

		temps.forEach(function(t) {
			var n = t.name.toLowerCase();

			if (agg.max === null || t.c > agg.max) {
				agg.max = t.c;
				agg.maxName = t.name;
			}

			if (n.indexOf('cpu') >= 0) {
				if (agg.cpu === null || t.c > agg.cpu)
					agg.cpu = t.c;
			}
			else if (n.indexOf('gpu') >= 0) {
				agg.gpu = t.c;
			}
			else if (n.indexOf('pm8916') >= 0 || n.indexOf('pmic') >= 0) {
				agg.pmic = t.c;
			}
		});

		return agg;
	},

	tempCell: function(temps) {
		if (!temps.length)
			return E('span', { 'style': 'color:#999' }, _('未发现温度传感器'));

		var agg = this.aggregate(temps),
		    hot = agg.max >= TEMP_WARN,
		    lines = [];

		/* 第一行：最高温（主值），高温标红 */
		lines.push(E('div', {}, [
			E('span', {
				'style': 'font-size:15px;font-weight:600;' + (hot ? 'color:#d33' : '')
			}, '%s °C'.format(agg.max.toFixed(1))),
			E('span', { 'style': 'color:#999;font-size:12px;margin-left:6px' },
				_('最高（%s）').format(shortName(agg.maxName)))
		]));

		/* 第二行：CPU / GPU / PMIC 摘要，与 SMSRelay 的副标题同口径 */
		var key = [];

		if (agg.cpu !== null)
			key.push('CPU %s °C'.format(agg.cpu.toFixed(1)));
		if (agg.gpu !== null)
			key.push('GPU %s °C'.format(agg.gpu.toFixed(1)));
		if (agg.pmic !== null)
			key.push('PMIC %s °C'.format(agg.pmic.toFixed(1)));

		if (key.length)
			lines.push(E('div', { 'style': 'color:#666;font-size:12.5px;margin-top:2px' },
				key.join('　·　')));

		/* 第三行：全部传感器明细 */
		lines.push(E('div', { 'style': 'color:#888;font-size:12px;margin-top:2px' },
			temps.map(function(t) {
				return '%s %s'.format(shortName(t.name), t.c.toFixed(1));
			}).join('　·　')));

		return E('div', {}, lines);
	},

	statusNode: function(data) {
		var temps = this.collectTemps(data);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('当前状态')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('项目')),
					E('th', { 'class': 'th' }, _('当前值'))
				]),
				row(_('运行频率'), khz(data[0])),
				row(_('调频策略'), (data[1] || '—').trim()),
				row(_('频率上限'), khz(data[2])),
				row(_('频率下限'), khz(data[3])),
				row(_('硬件档位'), (data[4] || '').trim().split(/\s+/).filter(function(f) {
					return f.length > 0;
				}).map(khz).join(' / ') || '—'),
				row(_('温度'), this.tempCell(temps))
			]),
			E('div', { 'class': 'cbi-section-descr' },
				_('温度为打开本页时的快照，刷新即可重新读取；%d °C 以上标红。').format(TEMP_WARN))
		]);
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev)
			.then(function() {
				return ui.changes.apply(mode == '0');
			})
			.then(function() {
				window.setTimeout(function() {
					Promise.resolve(callRcInit('jz02-power', 'restart')).catch(function() {});
				}, 100);
			});
	},

	render: function(data) {
		var m = new form.Map('jz02', _('性能与温度'),
			_('调整 CPU 调频策略与频率上限。保存并应用后会立即写入 sysfs，无需重启。'));

		var s = m.section(form.NamedSection, 'system', 'jz02', _('CPU 调频'));
		s.anonymous = true;
		s.addremove = false;

		var o = s.option(form.ListValue, 'cpu_governor', _('调频策略'));
		o.value('schedutil', _('schedutil（推荐，按负载调频）'));
		o.value('powersave', _('powersave（锁最低频，最省电）'));
		o.value('performance', _('performance（锁最高频）'));
		o.rmempty = false;
		o.description = _('本机实测可用策略只有这三个（无 ondemand / conservative）。');

		o = s.option(form.ListValue, 'cpu_max_freq', _('最高频率'));
		var avail = (data[4] || '').trim().split(/\s+/).filter(function(f) {
			return f.length > 0;
		});

		if (avail.length === 0)
			avail = [ '200000', '400000', '800000', '998400', '1209600', '1401600' ];

		avail.forEach(function(f) {
			o.value(f, khz(f));
		});
		o.rmempty = false;
		o.description = _('档位由 SoC 决定，不能填任意值。压到 800 MHz 可降低功耗，对稳态温度影响很小（被动散热）。');

		o = s.option(form.Flag, 'led_wifi', _('绿灯显示 WiFi 活动'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('默认关闭，只保留红色电源灯。开启后 green:wlan 会在 WiFi 有收发时闪烁。');

		return m.render().then(function(node) {
			node.insertBefore(this.statusNode(data), node.firstChild);
			return node;
		}.bind(this));
	}
});
