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
local INIT = "/etc/init.d/sbox-client"
local INSTALL = "/usr/bin/sbox-client-install"

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

function api_dispatch()
	http.prepare_content("application/json")
	local op = http.formvalue("op") or "list"

	if op == "list" then
		local listen = listening_ports()
		local nodes = read_nodes()
		for _, n in ipairs(nodes) do
			n.up = listen[n.socks] and true or false
		end
		http.write(jsonc.stringify({
			ok = true,
			nodes = nodes,
			service = service_state(),
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

	if op == "restart" then
		local out = sys.exec(INIT .. " restart 2>&1") or ""
		http.write(jsonc.stringify({ ok = true, output = out, service = service_state() }))
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

		-- 从刚装好的配置里读回 socks 端口，同步给 PassWall2
		local pw2_msg = "未同步"
		local installed = read_nodes()
		local latest = nil
		for _, n in ipairs(installed) do
			if not latest or (n.socks or 0) > (latest.socks or 0) then
				latest = n
			end
		end
		if latest then
			local ok2, msg = pw2_sync(latest.name, latest.socks)
			pw2_msg = ok2 and ("已同步 " .. latest.name) or tostring(msg)
		end

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