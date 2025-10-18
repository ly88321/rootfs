#!/usr/bin/luajit
local M = {}
local string_match = string.match
local string_format = string.format
local ffi = require "ffi"
local ssl = ffi.load("libssl")
local C = ffi.C
local int_type = ffi.typeof("int[?]")
local char_type = ffi.typeof("char[?]")
local sizeof = ffi.sizeof

ffi.cdef [[
	typedef int32_t pid_t;
	typedef long size_t;
	typedef long ssize_t;
	typedef uint32_t in_addr_t;
	typedef uint32_t socklen_t;

	enum {
		UNIX_PATH_MAX   = 108,
		UNIX_SOCK_SIZE  = 110,
		SOCK_SIZE       = 16,
		IF_NAMESIZE     = 16,
	};

	enum {
		AES_MAXNR = 14,
		AES_BLOCK_SIZE = 16,
	};
	typedef struct {
		unsigned int rd_key[4 * (AES_MAXNR + 1)];
		int rounds;
	}AES_KEY;

	union chksum {
		uint32_t n;
		struct { uint16_t sn1; uint16_t sn2; }; 
	};
	struct in_addr {
		in_addr_t s_addr;
	};

	union sock_len {
		unsigned int   lenptr[1];
		unsigned int   length;
	};
	struct timeval  { long tv_sec; long tv_usec; };
	struct timezone { int tz_minuteswest; int tz_dsttime; };
	struct timespec {
			long tv_sec;
			union {
					long tv_usec;
					long tv_nsec;
			};
	};
	struct itimerspec { struct timespec it_interval; struct timespec it_value; };

	struct sockaddr {
			unsigned short family;
			char sa_data[14];
	};

	struct sockaddr_in {
			unsigned short family;
			unsigned short sin_port;
			struct in_addr sin_addr;
			union {
					unsigned int   lenptr[1];
					unsigned int   length;
			};
			/* Pad to size of (struct sockaddr) */
			unsigned char __pad[SOCK_SIZE - 2-2-4-4];
	};

	uint32_t htonl(uint32_t hostlong);
	uint16_t htons(uint16_t hostshort);
	uint32_t ntohl(uint32_t netlong);
	uint16_t ntohs(uint16_t netshort);
	in_addr_t inet_addr(const char *cp);
	ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
					void *dest_addr, socklen_t addrlen);
	int close(int fd);
	int socket(int domain, int type, int protocol);
	pid_t fork(void);

	int pipe(int pipefd[2]);
	unsigned int sleep(unsigned int seconds);
	pid_t waitpid(pid_t pid, int *status, int options);

	int close(int fd);
	int dup2(int oldfd, int newfd);
	int execlp(const char *file, const char *arg, ...);
	int printf(const char *format, ...);
	unsigned long long int strtoull(const char *nptr, char **endptr, int base);

	ssize_t read(int fd, void *buf, size_t count);
	char *strerror(int errnum);

	typedef struct {
		unsigned long i[2];
		unsigned long buf[4]; 
		unsigned char in[64]; 
		unsigned char digest[16]; 
	} MD5_CTX;
	unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md);
	int MD5_Init(MD5_CTX *c);
	int MD5_Update(MD5_CTX *c, const void *data, unsigned long len);
	int MD5_Final(unsigned char *md, MD5_CTX *c);

	int access(const char *pathname, int mode);
	int clock_gettime(int, struct timespec *tp);

	int open(const char *pathname, int flags, ...);
	int flock(int fd, int operation);

	typedef void (*sighandler_t) (int);
	sighandler_t signal(int sig, sighandler_t handler);
	int kill(int32_t pid, int sig);
	pid_t getpid(void);
	pid_t getppid(void);
	int utimes(const char *filename, const struct timeval times[2]);
	int chdir(const char *path);
	int daemon(int nochdir, int noclose);

	int AES_set_encrypt_key(const unsigned char *userKey, const int bits, AES_KEY *key);
	int AES_set_decrypt_key(const unsigned char *userKey, const int bits, AES_KEY *key);

	void AES_cbc_encrypt(const unsigned char *in, unsigned char *out, size_t length, 
						const AES_KEY *key,const unsigned char *ivec, const int enc);

	void *memset(void *s, int c, size_t n);
	void *memcpy(void *dest, const void *src, size_t n);
	size_t strlen(const char *s);
	ssize_t readlink(const char *path, char *buf, size_t bufsiz);
]]
local timespec = ffi.new("struct timespec")
local timeval = ffi.new("struct timeval[2]")

local bit = require "bit"

local functions = {}
local release = {}
local args = {}
local has_cert = false
local use_ipv4 = false
local proto_dir = "/usr/libproto/"
local version_all = {}

function init()
    check_have_certs()

    functions.boot = start
    functions.start = start
    functions.down_version_all = down_version_all
    functions.down_library = down_library

    if not arg[1] or not functions[arg[1]] then
		os.exit(1)
	end
    use_ipv4 = os.execute("wget -h | grep -q inet4-only") == 0
    args = ikL_parsearg(arg)
    release = load_ikrelease()
    LAST_NUM = ikL_strsum(release.GWID) * 112637215 * 737 / 131 % 100
	LAST_NUM = math.floor(LAST_NUM)

	local func = functions[arg[1]]

    if arg[1] == "start" or arg[1] == "boot" then
		local success, status_code
        while(not success) do
            success, status_code = down_version_all()
            ikL_sleep(5)
        end       
	end

	if arg[1] ~= "down_version_all" then
		version_all = load_version_all(release)
	end

    local result, errmsg = func()

	if result == false then
		print(errmsg)
		os.exit(1)
	end

	os.exit(0)
end

function start()
    ikL_run_back(loop)
end

function loop()
    local interval = 3600
	while(true) do
	    func_auto_upgrade_library()
		ikL_sleep(interval)
	end
end

-- 自动升级库和处理白名单文件
function func_auto_upgrade_library()
    local check_interval_hours = 12
    local current_hour = tonumber(os.date("%H"))
    local uptime_seconds = ikL_uptime()
    local audit_flag_changed = false

    -- 读取当前 audit 状态
    local audit_flag_file = ikL_readfile_line("/usr/libproto/audit_flag", 1)
    local audit_config = ikL_readfile_line("/etc/mnt/audit/config", 1)

    -- 根据 audit 配置更新版本文件
    if audit_config == "enabled=yes" and audit_flag_file ~= "is_audit" then
        ikL_writefile("1.0.0", "/usr/libproto/audit_ver")
        audit_flag_changed = true
    elseif audit_config ~= "enabled=yes" and audit_flag_file ~= "no_audit" then
        ikL_writefile("1.0.0", "/usr/libproto/audit_ver")
        audit_flag_changed = true
    end

    -- 定时或新 audit 标志触发升级
    if current_hour % check_interval_hours == LAST_NUM % check_interval_hours or uptime_seconds <= 1800 then
        ikL_system("/usr/ikuai/script/upgrade.sh __cloud_auto_upgrade")
    elseif audit_flag_changed then
        ikL_system("/usr/ikuai/script/upgrade.sh update_auto type=im")
    end

    -- 检查并更新 white_wifi_filter.txt
    local local_md5 = ikL_fmd5(proto_dir .. "white_wifi_filter.txt")
    local remote_md5 = version_all.webauth_filter_md5

    if remote_md5 and remote_md5 ~= "" and remote_md5:sub(1, 32) ~= local_md5 then
        local ok, _, _ = ikL_curl("https://download.ikuai8.com/submit3x/white_wifi_filter.txt", nil, {
            write_file = "/tmp/white_wifi_filter.txt.tmp"
        })

        if ok then
            os.rename("/tmp/white_wifi_filter.txt.tmp", proto_dir .. "white_wifi_filter.txt")
            ikL_system("/usr/ikuai/script/upgrade.sh __save_lib_file; /usr/ikuai/script/webauth.sh load_white_domain sync")
        else
            os.remove("/tmp/white_wifi_filter.txt.tmp")
        end
    end
end

-- 下载库文件
function down_library()
    local filename = args.filename
    local write_file = args.write_file
    local quiet = args.quiet

    if not filename or not write_file then
        return false, "Usage: down_library filename=IKprotocol_2.0.0.lib write_file=/tmp/123.lib [quiet=no]"
    end

    local primary_url = "https://patch-src.ikuai8.com:2000/lib/"
    local backup_url  = "https://patch.ikuai8.com/lib/"

    -- 特殊处理 IKaudit 系列库
    if filename:match("^IKaudit_") then
        local audit_status = ikL_readfile_line("/etc/mnt/audit/config", 1)
        if audit_status ~= "enabled=yes" then
            filename = filename:gsub("IKaudit", "IKauditX")
        end
    end

    -- 尝试主源下载
    local ok, content, headers = ikL_wget(primary_url .. filename, nil, {
        quiet = quiet,
        write_file = write_file
    })

    if ok then
        return ok, content, headers
    end

    -- 主源失败，尝试备用源
    return ikL_wget(backup_url .. filename, nil, {
        quiet = quiet,
        write_file = write_file
    })
end

-- 下载版本文件
function down_version_all()
  return down_file("https://download.ikuai8.com/submit3x/Version_all", "/tmp/iktmp/Version_all")
end

-- 计算文件md5
function ikL_fmd5(filename)
    local digest = ffi.new("unsigned char[?]", 17)   -- MD5 输出缓冲区
    local ctx = ffi.new("MD5_CTX[1]")                -- MD5 上下文
    local f = io.open(filename)

    if not f then return nil end

    ssl.MD5_Init(ctx[0])                                -- 初始化 MD5

    while true do
        local chunk = f:read(65536)                -- 分块读取文件
        if not chunk then break end
        ssl.MD5_Update(ctx[0], chunk, #chunk)          -- 更新 MD5
    end

    ssl.MD5_Final(digest, ctx[0])                       -- 计算最终 MD5
    f:close()

    return string.format(
        "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
        digest[0], digest[1], digest[2], digest[3],
        digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15]
    )
end

-- 计算字符串每个字节的和，保持原有 FFI unsigned int 逻辑
-- str: 输入字符串
-- 返回: 字节和（unsigned int）
function ikL_strsum(str)
    if not str then
        return 0
    end

    local sum_array = ffi.new("unsigned int[?]", 1)

    for i = 1, #str do
        sum_array[0] = sum_array[0] + str:byte(i)
    end

    return sum_array[0]
end

-- 后台运行一个函数
-- func: 待执行的函数
-- ... : 传给 func 的参数
-- 返回: true 表示父进程 fork 成功，false 表示 fork 失败
function ikL_run_back(func, ...)
    local pid = C.fork()

    if pid == 0 then
        -- 子进程脱离终端，成为守护进程
        C.daemon(1, 0)
        func(...)        -- 执行函数
        os.exit(0)
    elseif pid > 0 then
        -- 父进程等待子进程结束
        C.waitpid(pid, nil, 0)
        return true
    else
        -- fork 失败
        return false
    end
end

-- 读取 Version_all 文件并解析配置
-- info: 表示设备信息，包含 MODELTYPE 和可选 OEMNAME
-- 返回: table {key=val, ...}
function load_version_all(info)
    -- 构建区块名，例如 "MODEL_OEM" 或 "MODEL"
    local block_name
    if info.OEMNAME then
        block_name = info.MODELTYPE .. "_" .. info.OEMNAME
    else
        block_name = info.MODELTYPE
    end

    local file, err = io.open("/tmp/iktmp/Version_all")
    if not file then
        print("cannot load Version_all:", err)
        os.exit(1)
    end

    local config = {}
    local current_section

    for line in file:lines() do
        -- 区块行，例如 [GLOBAL] 或 [MODEL_OEM]
        local section = line:match("^%[(.+)%]")
        if section then
            current_section = section
        elseif current_section == "GLOBAL" or current_section == block_name then
            -- 解析 key=value
            local key, val = line:match("^([^ ]+) *= *(.*)")
            if key then
                config[key] = val
            end
        end
    end

    file:close()
    return config
end

-- 获取系统运行时间（秒和纳秒）
-- 返回: uptime_seconds, uptime_nanoseconds
function ikL_uptime()
    C.clock_gettime(1, timespec)  -- CLOCK_MONOTONIC
    return timespec.tv_sec, timespec.tv_nsec
end

-- 写入内容到文件
-- content: 写入的字符串
-- path: 文件路径
-- mode: 打开模式，可选，默认 "w"
-- 返回: true 表示成功，false 表示失败
function ikL_writefile(content, path, mode)
    local file = io.open(path, mode or "w")
    if file then
        file:write(content)
        file:close()
        return true
    end
    return false
end

-- 读取文件的指定行
-- path: 文件路径
-- line_num: 要读取的行号，从 1 开始
-- 返回: 指定行内容，找不到返回 nil
function ikL_readfile_line(path, line_num)
    local file = io.open(path, "r")
    if not file then return nil end

    local result
    if line_num == 1 then
        result = file:read("*l")
    else
        local current_line = 0
        for line in file:lines() do
            current_line = current_line + 1
            if current_line == line_num then
                result = line
                break
            end
        end
    end

    file:close()
    return result
end

-- 执行 shell 命令并返回输出
-- cmd: 待执行的命令字符串
-- 返回: 命令输出字符串
function ikL_shell(cmd)
    local handle = io.popen(cmd)
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result
    end
end

-- 判断文件是否存在
-- path: 文件路径
-- 返回: true/false
function ikL_exist_file(path)
    return C.access(path, 0) == 0
end

-- 检查系统是否存在 SSL 证书
function check_have_certs()
    -- 是否存在证书
    has_cert = ikL_exist_file("/etc/ssl/certs/ca-certificates.crt")

    if not has_cert then
        -- 检查 /etc/ssl/certs 下以 0 开头的文件
        local count = ikL_shell("ls /etc/ssl/certs/0* 2>/dev/null | wc -l")
        has_cert = count ~= "0"

        print(has_cert)
    end
end

-- Lua 封装 wget
-- url: 下载地址
-- headers: 可选，自定义请求头表
-- options: 可选，表格式选项，如 quiet, limit_rate, write_file, post_data, post_file, certificate, ca_certificate, private_key
function ikL_wget(url, headers, options)
    local no_check_cert = not has_cert and "--no-check-certificate" or ""
    local cmd = "wget '" .. url .. "' -t 3 -T 30 --connect-timeout=30 --read-timeout=30 --dns-timeout=20 " .. no_check_cert

    -- 默认请求头
    local default_headers = {
        ["X-Firmware"] = release.FIRMWARENAME,
        ["X-Router-Ver"] = release.VERSION,
        ["X-GWID"] = release.GWID,
        ["X-Build-Date"] = release.BUILD_DATE,
        ["X-Sysbit"] = release.SYSBIT,
        ["X-Oemname"] = release.OEMNAME,
        ["X-Overseas"] = release.OVERSEAS,
        ["X-Edition-Type"] = release.ENTERPRISE and "Enterprise" or "Standard"
    }

    -- 合并自定义请求头
    if type(headers) == "table" then
        for k, v in pairs(headers) do
            default_headers[k] = v
        end
    end

    -- 使用 IPv4
    if use_ipv4 then
        cmd = cmd .. " -4"
    end

    -- 拼接请求头
    for k, v in pairs(default_headers) do
        cmd = cmd .. " --header='" .. k .. ":" .. v .. "'"
    end

    options = options or {}

    -- quiet 模式
    if options.quiet ~= "no" then
        cmd = cmd .. " -q"
    end

    -- 限速
    if options.limit_rate then
        cmd = cmd .. " --limit-rate=" .. options.limit_rate
    end

    -- 输出文件
    if options.write_file then
        cmd = cmd .. " -O " .. options.write_file
    else
        cmd = cmd .. " -O-"
    end

    -- POST 数据或文件
    if options.post_data then
        cmd = cmd .. " --post-data='" .. options.post_data .. "'"
    elseif options.post_file then
        cmd = cmd .. " --post-file=" .. options.post_file
    end

    -- 证书相关
    if options.certificate then
        cmd = cmd .. " --certificate=" .. options.certificate
    end
    if options.ca_certificate then
        cmd = cmd .. " --ca-certificate=" .. options.ca_certificate
    end
    if options.private_key then
        cmd = cmd .. " --private-key=" .. options.private_key
    end

    -- 执行命令
    return ikL_system(cmd)
end

-- 解析命令行参数表，将 "key=value" 转为 table，其他标记设为 true
-- args: 数组或表，例如 {"filename=abc", "quiet"}
-- 返回: { filename="abc", quiet=true }
function ikL_parsearg(args)
    local parsed = {}

    for _, arg in pairs(args) do
        if arg:match("=") then
            local key, value = arg:match("^([^=]+)=(.*)")
            if key then
                parsed[key] = value
            end
        else
            parsed[arg] = true
        end
    end

    return parsed
end


-- 在子进程中执行 shell 命令，并获取输出
-- cmd: 要执行的命令
-- 返回: 成功标志, 输出或错误信息
function ikL_system(cmd)
    if not cmd or cmd == "" then
        return false, "cmd cannot be empty"
    end

    local output = ""
    local pipe_fds = int_type(2)       -- int pipe[2]
    local buffer = char_type(1024)     -- char buffer[1024]

    if C.pipe(pipe_fds) < 0 then
        return false, ffi.geterr()
    end

    local read_fd, write_fd = pipe_fds[0], pipe_fds[1]
    local pid = C.fork()

    if pid == 0 then
        -- 子进程: 重定向 stdout 到管道写端
        C.dup2(write_fd, 1)
        C.close(write_fd)
        C.close(read_fd)
        C.execlp("bash", "bash", "-c", cmd, nil)
        os.exit(1)
    elseif pid > 0 then
        -- 父进程: 关闭写端，读取输出
        C.close(write_fd)
        local read_err = nil

        while true do
            local n = C.read(read_fd, buffer, sizeof(buffer))
            if n == 0 then
                break
            elseif n < 0 then
                read_err = ffi.geterr()
                break
            end
            output = output .. ffi.string(buffer, n)
        end

        local status_buf = int_type(1)
        C.waitpid(pid, status_buf, 0)
        C.close(read_fd)

        if read_err then
            return false, read_err
        else
            return ikL_wexitstatus(status_buf[0]) == 0, output
        end
    else
        -- fork 失败
        return false, ffi.geterr()
    end
end

-- 获取 waitpid 返回状态的子进程退出码
-- status: waitpid 返回的整数状态
function ikL_wexitstatus(status)
    return bit.rshift(status, 8)
end

-- 读取 /etc/release 文件并解析为 Lua 表
function load_ikrelease()
    local file = io.open("/etc/release", "r")
    local release_info = {}

    if file then
        for line in file:lines() do
            -- 解析 key=value，允许空格
            local key, val = string_match(line, "^([^ ]+) *= *(.+)")
            if key then
                release_info[key] = val
            end
        end
        file:close()
    end

    -- 转换数字字段
    if release_info.VERSION_NUM then
        release_info.VERSION_NUM = tonumber(release_info.VERSION_NUM)
    end
    if release_info.BUILD_DATE then
        release_info.BUILD_DATE = tonumber(release_info.BUILD_DATE)
    end

    return release_info
end

-- 将 HTTP 响应头解析为 Lua 表
-- headers_str: 原始响应头字符串
-- 返回表，包含 status 和各个头字段
function ikL_headers(headers_str)
    local headers = {}
    local line_num = 0

    for line in headers_str:gmatch("([^\r\n]+)\r\n") do
        line_num = line_num + 1

        if line_num == 1 then
            -- 第一行: HTTP/1.1 200 OK -> 提取状态码
            local status_code = line:match("HTTP/%d+%.%d+ (%d+)")
            headers.status = tonumber(status_code)
        else
            -- 其他行: Key: Value
            local key, value = line:match("([^:]+):%s*(.+)")
            if key and value then
                headers[key] = value
            end
        end
    end

    return headers
end

-- Lua 封装 curl 请求函数
-- url: 请求地址
-- headers: 可选，表格式自定义请求头
-- options: 可选，表格式选项，支持 quiet, limit_rate, write_file, post_data, post_file, dump_header, certificate, ca_certificate, private_key
function ikL_curl(url, headers, options)
    local curl_cmd = "curl -L -4 '" .. url .. "' --speed-time 30 --speed-limit 3 --connect-timeout 20 --retry 5 --retry-max-time 10 "

    -- 默认 SSL 参数
    curl_cmd = curl_cmd .. (not has_cert and "-k" or "--capath /etc/ssl/certs")

    -- 默认请求头
    local default_headers = {
        ["X-Firmware"] = release.FIRMWARENAME,
        ["X-Router-Ver"] = release.VERSION,
        ["X-GWID"] = release.GWID,
        ["X-Build-Date"] = release.BUILD_DATE,
        ["X-Sysbit"] = release.SYSBIT,
        ["X-Oemname"] = release.OEMNAME,
        ["X-Overseas"] = release.OVERSEAS,
        ["X-Edition-Type"] = release.ENTERPRISE and "Enterprise" or "Standard",
    }

    -- 合并自定义请求头
    if type(headers) == "table" then
        for k, v in pairs(headers) do
            default_headers[k] = v
        end
    end

    -- 拼接请求头
    for k, v in pairs(default_headers) do
        curl_cmd = curl_cmd .. " -H '" .. k .. ": " .. v .. "'"
    end

    options = options or {}
    
    -- quiet 模式
    if options.quiet ~= "no" then
        curl_cmd = curl_cmd .. " -s"
    end

    -- 限速
    if options.limit_rate then
        curl_cmd = curl_cmd .. " --limit-rate " .. options.limit_rate
    end

    -- 输出文件
    if options.write_file then
        curl_cmd = curl_cmd .. " -o " .. options.write_file
    end

    -- POST 数据或文件
    if options.post_data then
        curl_cmd = curl_cmd .. " -X POST -d '" .. options.post_data .. "'"
    elseif options.post_file then
        curl_cmd = curl_cmd .. " -X POST -T " .. options.post_file
    end

    -- HTTP 报头输出
    local dump_header = options.dump_header and true or false
    if dump_header then
        curl_cmd = curl_cmd .. " -D-"
    end

    -- 证书相关
    if options.certificate then
        curl_cmd = curl_cmd .. " --cert " .. options.certificate
    end
    if options.ca_certificate then
        curl_cmd = curl_cmd .. " --cacert " .. options.ca_certificate
    end
    if options.private_key then
        curl_cmd = curl_cmd .. " --key " .. options.private_key
    end

    -- 执行命令
    local ok, result = ikL_system(curl_cmd)

    if dump_header and ok and result then
        -- 解析 HTTP 头
        local headers_obj
        local header_end = result:find("\r\n\r\n")
        if header_end then
            headers_obj = ikL_headers(result:sub(1, header_end))
            result = result:sub(header_end + 1)

            -- 处理 3xx 重定向（简单递归方式）
            if headers_obj.status >= 300 and headers_obj.status < 400 and headers_obj.Location then
                return ikL_curl(headers_obj.Location, headers, options)
            end
        end
        return ok, result, headers_obj
    else
        return ok, result
    end
end

-- 获取文件状态信息（修改时间和大小）
-- path: 文件路径
-- 返回: {st_mtime=时间戳, st_size=字节数} 或 nil
function ikL_stat(path)
    if not ikL_exist_file(path) then
        return nil
    end

    local info = {}
    local handle = io.popen("stat -c \"%Y\t%s\" " .. path)
    if handle then
        local line = handle:read("*l")
        if line then
            local mtime, size = line:match("([^\t]+)\t([^\t]+)")
            if mtime then
                info.st_mtime = tonumber(mtime)
                info.st_size  = tonumber(size)
            end
        end
        handle:close()
    end

    if not info.st_mtime then
        return nil
    end

    return info
end

-- 根据文件状态生成标识字符串（ETag 风格）
-- file_info: {st_mtime=时间戳, st_size=字节数}
-- 返回: 类似 "5f2a1b2c-1234" 的字符串
function ikL_maketag(file_info)
    return string_format("\"%x-%x\"", file_info.st_mtime, file_info.st_size)
end

-- 下载文件，支持 ETag 校验和临时文件
-- url: 下载地址
-- file_path: 保存路径
-- curl_options: 可选 curl 参数表
function down_file(url, file_path, curl_options)
    local tmp_file = file_path .. ".tmp" .. C.getpid()
    local file_stat = ikL_stat(file_path)
    local headers = nil

    -- 如果目标文件存在，生成 If-None-Match 请求头
    if file_stat then
        headers = { ["If-None-Match"] = ikL_maketag(file_stat) }
    end

    -- 默认 curl 选项
    local options = {
        dump_header = true,
        write_file = tmp_file
    }

    -- 合并自定义 curl 选项
    if curl_options then
        for k, v in pairs(curl_options) do
            options[k] = v
        end
    end

    -- 执行下载
    local ok, body, resp_headers = ikL_curl(url, headers, options)

    if ok and resp_headers then
        local etag = resp_headers.ETag
        local status = resp_headers.status

        if status == 304 then
            -- 文件未修改
            return true, status
        elseif status == 200 then
            -- 使用 ETag 更新文件时间戳
            local ts = tonumber("0x" .. etag:sub(2, 9))
            timeval[0].tv_sec = ts
            timeval[1].tv_sec = ts
            C.utimes(tmp_file, timeval)

            -- 替换目标文件
            os.rename(tmp_file, file_path)
            return true, status
        end
    end

    -- 下载失败，删除临时文件
    os.remove(tmp_file)
    return false, resp_headers and resp_headers.status or 0
end

function ikL_sleep(sec)
	C.sleep(sec)
end

init()
