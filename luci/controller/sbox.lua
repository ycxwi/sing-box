-- Sing-Box 节点管理（独立 LuCI 应用，与 PassWall2 零耦合）
--
-- 数据源 = /etc/sbox-client/nodes/（每节点 <name>.json + <name>.pem + <name>.key）
-- 状态判据 = 该节点 socks 端口是否在 /proc/net/tcp 处于 LISTEN（每节点独立进程独占端口）
-- 写操作 = 调 /etc/init.d/sbox-client restart；新增走 /usr/bin/sbox-client-install（复用安装器）
module("luci.controller.sbox", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local NODES_DIR = "/etc/sbox-client/nodes"
local DISABLED_DIR = "/etc/sbox-client/disabled"
local INIT = "/etc/init.d/sbox-client"
local INSTALL = "/usr/bin/sbox-client-install"
local PW2_LOCK = "/var/lock/passwall2.lock"

function index()
	entry({"admin", "services", "sbox"}, alias("admin", "services", "sbox", "nodes"), _("Sing-Box 节点"), 60)
	entry({"admin", "services", "sbox", "nodes"}, template("sbox/nodes"), _("节点列表"), 1)
	entry({"admin", "services", "sbox", "api"}, call("api_dispatch")).leaf = true
end

-- 读 /proc/net/tcp，返回处于 LISTEN 的本地端口集合
local function listening_ports()
	local set = {}
	local fh = io.open("/proc/net/tcp", "r")
	if not fh then
		return set
	end
	fh:read("*l")
	for line in fh:lines() do
		local laddr, state = line:match("^%s*%d+:%s+(%x+:%x+)%s+%x+:%x+%s+(%x+)")
		if laddr and state == "0A" then
			local hexport = laddr:match(":(%x+)$")
			if hexport then
				set[tonumber(hexport, 16)] = true
			end
		end
	end
	fh:close()
	return set
end

-- 扫描 nodes 目录，返回节点数组（按 socks 端口升序）
local function read_nodes()
	local list = {}
	if not fs.access(NODES_DIR) then
		return list
	end
	for entry in fs.dir(NODES_DIR) do
		if entry:match("%.json$") then
			local name = entry:gsub("%.json$", "")
			local fh = io.open(NODES_DIR .. "/" .. entry, "r")
			if fh then
				local raw = fh:read("*a")
				fh:close()
				local ok, cfg = pcall(jsonc.parse, raw)
				if ok and type(cfg) == "table" then
					local outb = (cfg.outbounds and cfg.outbounds[1]) or {}
					local inb = (cfg.inbounds and cfg.inbounds[1]) or {}
					local tls = outb.tls or {}
					list[#list + 1] = {
						name = name,
						server = outb.server or "",
						port = outb.server_port or 0,
						socks = inb.listen_port or 0,
						sni = tls.server_name or "",
						has_pem = fs.access(NODES_DIR .. "/" .. name .. ".pem") and true or false,
						has_key = fs.access(NODES_DIR .. "/" .. name .. ".key") and true or false,
					}
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return (a.socks or 0) < (b.socks or 0)
	end)
	return list
end

-- 禁用标记：存在 = 该节点不参与启动（init 脚本会跳过）
local function is_disabled(name)
	return fs.access(DISABLED_DIR .. "/" .. name) and true or false
end

local function service_state()
	local out = sys.exec(INIT .. " status 2>&1") or ""
	out = out:gsub("%s+$", "")
	return out
end

-- 把节点同步进 PassWall2 的节点表（按 remarks = sbox-<name> 认领）
local function pw2_sync(name, socks_port)
	local remarks = "sbox-" .. name
	local sid = nil
	local listing = sys.exec("uci show passwall2 2>/dev/null") or ""
	for line in listing:gmatch("[^\r\n]+") do
		-- 匿名为 section（@nodes[20]）也匹配：不能用 [%w_-]+，否则旧节点删不掉/重复添加
		local sec = line:match("^passwall2%.([^=]+)=nodes$")
		if sec then
			local cur = sys.exec("uci get passwall2." .. sec .. ".remarks 2>/dev/null") or ""
			if cur:gsub("%s+$", "") == remarks then
				sid = sec
				break
			end
		end
	end
	if not sid then
		sid = (sys.exec("uci add passwall2 nodes 2>/dev/null") or ""):gsub("%s+$", "")
	end
	if not sid or sid == "" then
		return false, "uci add passwall2 nodes failed"
	end
	sys.call(string.format(
		"uci set passwall2.%s.type='sing-box'; uci set passwall2.%s.remarks='%s'; " ..
		"uci set passwall2.%s.protocol='socks'; uci set passwall2.%s.address='127.0.0.1'; " ..
		"uci set passwall2.%s.port='%s'; uci commit passwall2",
		sid, sid, remarks, sid, sid, sid, socks_port))
	return true, sid
end

local function pw2_remove(name)
	local remarks = "sbox-" .. name
	local listing = sys.exec("uci show passwall2 2>/dev/null") or ""
	for line in listing:gmatch("[^\r\n]+") do
		local sec = line:match("^passwall2%.([^=]+)=nodes$")
		if sec then
			local cur = sys.exec("uci get passwall2." .. sec .. ".remarks 2>/dev/null") or ""
			if cur:gsub("%s+$", "") == remarks then
				sys.call("uci delete passwall2." .. sec .. "; uci commit passwall2")
				return true
			end
		end
	end
	return false
end

-- 一次 uci show 扫出全部 nodes 段，避免逐节点反复 exec（软路由上 fork 很贵）
local function pw2_table()
	local rows = {}
	local listing = sys.exec("uci show passwall2 2>/dev/null") or ""
	for line in listing:gmatch("[^\r\n]+") do
		local sec, opt, val = line:match("^passwall2%.([^=]+)%.([%w_%-]+)='(.*)'$")
		if sec and opt then
			rows[sec] = rows[sec] or {}
			rows[sec][opt] = val
		end
	end
	return rows
end

-- PassWall2 正在重建中（restart 会拿这把锁，典型耗时 1-4 分钟）
local function pw2_restarting()
	return fs.access(PW2_LOCK) and true or false
end

-- 当前生效节点（@global[0].node，存 section 名或 @nodes[N] 引用）
local function pw2_current()
	return (sys.exec("uci get passwall2.@global[0].node 2>/dev/null") or ""):gsub("%s+$", "")
end

-- 找节点对应的 PassWall2 section：先按 remarks 认领，再按 socks 端点认领
-- （迁移前建的条目 remarks 是旧名，但 address:port 指向同一 socks 入口）
local function pw2_find(rows, name, socks_port)
	local remarks = "sbox-" .. name
	for sec, f in pairs(rows) do
		if f.remarks == remarks then
			return sec
		end
	end
	if socks_port and socks_port ~= 0 then
		for sec, f in pairs(rows) do
			if f.protocol == "socks" and f.address == "127.0.0.1"
				and tostring(f.port) == tostring(socks_port) then
				return sec
			end
		end
	end
	return nil
end

-- 从安装器输出里解析节点名与 socks 端口（比“猜最大端口”可靠），同步给 PassWall2
local function sync_from_output(out)
	if not out then
		return "未同步（无输出）"
	end
	local node_name = out:match("name%s*=%s*([%w_%-]+)")
	local socks_port = tonumber(out:match("socks%s*=%s*127%.0%.0%.1:(%d+)"))
	if not node_name or not socks_port then
		return "未同步（输出里找不到节点名或端口）"
	end
	local ok, msg = pw2_sync(node_name, socks_port)
	return ok and ("已同步 " .. node_name .. " @" .. socks_port) or tostring(msg)
end

function api_dispatch()
	http.prepare_content("application/json")
	local op = http.formvalue("op") or "list"

	if op == "list" then
		local listen = listening_ports()
		local nodes = read_nodes()
		local rows = pw2_table()
		local active_sec = pw2_current()
		for _, n in ipairs(nodes) do
			n.up = listen[n.socks] and true or false
			n.enabled = not is_disabled(n.name)
			n.pw2 = pw2_find(rows, n.name, n.socks)
			n.active = (n.pw2 ~= nil and n.pw2 == active_sec)
		end
		local pw2_busy = pw2_restarting()
		http.write(jsonc.stringify({
			ok = true,
			nodes = nodes,
			service = service_state(),
			pw2_restarting = pw2_busy,
			nodes_dir = NODES_DIR,
		}))
		return
	end

	if op == "delete" then
		local name = http.formvalue("name") or ""
		if not name:match("^[%w_%-]+$") then
			http.write(jsonc.stringify({ ok = false, error = "非法节点名" }))
			return
		end
		for _, ext in ipairs({ ".json", ".pem", ".key" }) do
			os.remove(NODES_DIR .. "/" .. name .. ext)
		end
		local pw2 = pw2_remove(name)
		local out = sys.exec(INIT .. " restart 2>&1") or ""
		http.write(jsonc.stringify({ ok = true, pw2_removed = pw2, output = out }))
		return
	end

	-- 手动启停：写/删禁用标记后重启服务（init 会跳过被禁用的节点）
	if op == "toggle" then
		local name = http.formvalue("name") or ""
		local action = http.formvalue("action") or ""
		if not name:match("^[%w_%-]+$") then
			http.write(jsonc.stringify({ ok = false, error = "非法节点名" }))
			return
		end
		if not fs.access(NODES_DIR .. "/" .. name .. ".json") then
			http.write(jsonc.stringify({ ok = false, error = "节点不存在: " .. name }))
			return
		end
		if action == "disable" then
			sys.call("mkdir -p " .. DISABLED_DIR .. " && touch " .. DISABLED_DIR .. "/" .. name)
		elseif action == "enable" then
			sys.call("rm -f " .. DISABLED_DIR .. "/" .. name)
		else
			http.write(jsonc.stringify({ ok = false, error = "action 只能是 enable/disable" }))
			return
		end
		local out = sys.exec(INIT .. " restart 2>&1") or ""
		http.write(jsonc.stringify({
			ok = true,
			enabled = (action == "enable"),
			output = out,
			service = service_state(),
		}))
		return
	end

	if op == "restart" then
		local out = sys.exec(INIT .. " restart 2>&1") or ""
		http.write(jsonc.stringify({ ok = true, output = out, service = service_state() }))
		return
	end

	-- 切换 PassWall2 当前生效节点（= 全局 @global[0].node）
	if op == "activate" then
		local name = http.formvalue("name") or ""
		if not name:match("^[%w_%-]+$") then
			http.write(jsonc.stringify({ ok = false, error = "非法节点名" }))
			return
		end
		if not fs.access(NODES_DIR .. "/" .. name .. ".json") then
			http.write(jsonc.stringify({ ok = false, error = "节点不存在: " .. name }))
			return
		end
		if is_disabled(name) then
			http.write(jsonc.stringify({ ok = false, error = "节点已禁用，先启用再激活" }))
			return
		end
		local socks = 0
		for _, n in ipairs(read_nodes()) do
			if n.name == name then
				socks = n.socks
			end
		end
		local sec = pw2_find(pw2_table(), name, socks)
		if not sec then
			http.write(jsonc.stringify({ ok = false, error = "PassWall2 里没有这个节点，先重新保存一次以同步" }))
			return
		end
		-- 匿名 section（@nodes[N]）改成稳定名：索引会随删节点漂移，名字不会
		local target = sec
		if sec:sub(1, 1) == "@" then
			target = "sbox_" .. name
			local rn = sys.exec("uci rename passwall2." .. sec .. "=" .. target .. " 2>&1") or ""
			if not rn:match("^%s*$") then
				http.write(jsonc.stringify({ ok = false, error = "重命名 PassWall2 节点失败", output = rn }))
				return
			end
		end
		local seterr = sys.exec("uci set passwall2.@global[0].node='" .. target .. "' 2>&1") or ""
		if not seterr:match("^%s*$") then
			http.write(jsonc.stringify({ ok = false, error = "写入 PassWall2 当前节点失败", output = seterr }))
			return
		end
		sys.call("uci commit passwall2")
		-- restart 同步跑要 1-4 分钟（app.sh start 里做 DNS/节点探测），必须后台化，
		-- 否则 HTTP 请求扯死、页面一直转圈
		sys.call("nohup /etc/init.d/passwall2 restart >/tmp/sbox-pw2-restart.log 2>&1 &")
		http.write(jsonc.stringify({
			ok = true,
			section = target,
			pending = true,
			service = service_state(),
		}))
		return
	end

	-- 从服务端给的安装链接拉包并安装（一次性 URL：下载即删，服务端不常开接口）
	if op == "install_url" then
		local url = http.formvalue("url") or ""
		-- 只接受 https，且字符白名单（值要拼进 shell 命令，必须防空注入）
		if not url:match("^https://[%w%-%._/:%?%=%&%+,~]+$") then
			http.write(jsonc.stringify({ ok = false, error = "只接受 https:// 安装链接" }))
			return
		end
		local tmp = "/tmp/sbox-url"
		sys.call("rm -rf " .. tmp .. "; mkdir -p " .. tmp)
		local dl = sys.exec("curl -fsS --max-time 90 -o " .. tmp .. "/pkg.tgz '" .. url .. "' 2>&1") or ""
		if not fs.access(tmp .. "/pkg.tgz") then
			sys.call("rm -rf " .. tmp)
			http.write(jsonc.stringify({ ok = false, error = "链接下载失败", output = dl }))
			return
		end
		sys.call("cd " .. tmp .. " && tar xzf pkg.tgz 2>&1")
		if not (fs.access(tmp .. "/client.json") and fs.access(tmp .. "/client.pem") and fs.access(tmp .. "/client.key")) then
			sys.call("rm -rf " .. tmp)
			http.write(jsonc.stringify({ ok = false, error = "包内缺少 client.json / client.pem / client.key" }))
			return
		end
		local out = sys.exec("cd " .. tmp .. " && SB_BINARY=/usr/bin/sbox-client sh " .. INSTALL .. " 2>&1") or ""
		sys.call("rm -rf " .. tmp)
		http.write(jsonc.stringify({
			ok = rc_success(out),
			output = out,
			pw2 = sync_from_output(out),
			service = service_state(),
		}))
		return
	end

	if op == "add" then
		local tmp = "/tmp/sbox-add"
		sys.call("rm -rf " .. tmp .. "; mkdir -p " .. tmp)

		local files = {
			{ field = "json", dest = "client.json" },
			{ field = "pem", dest = "client.pem" },
			{ field = "key", dest = "client.key" },
		}
		for _, f in ipairs(files) do
			local src = http.formvalue(f.field)
			if not src or src == "" then
				http.write(jsonc.stringify({ ok = false, error = "缺少上传文件: " .. f.dest }))
				return
			end
			if not fs.copy(src, tmp .. "/" .. f.dest) then
				http.write(jsonc.stringify({ ok = false, error = "复制失败: " .. f.dest }))
				return
			end
		end

		local out = sys.exec("cd " .. tmp .. " && SB_BINARY=/usr/bin/sbox-client sh " .. INSTALL .. " 2>&1") or ""
		sys.call("rm -rf " .. tmp)

		-- 从安装输出解析节点名与 socks 端口，同步给 PassWall2
		local pw2_msg = sync_from_output(out)

		http.write(jsonc.stringify({
			ok = rc_success(out),
			output = out,
			pw2 = pw2_msg,
			service = service_state(),
		}))
		return
	end

	http.write(jsonc.stringify({ ok = false, error = "未知操作: " .. op }))
end

-- 安装器失败时不会返回非零（它自己 die），所以按输出里的 FAIL: 判定
function rc_success(out)
	if not out then
		return false
	end
	if out:find("FAIL:", 1, true) then
		return false
	end
	return true
end