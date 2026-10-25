# 把 patpatpatrick.com 从 GitHub Pages 迁到自己的 VPS

目标：域名直接指向你的 VPS，GitHub 上不再托管这个博客，别人也无法再通过
域名反查到你的 GitHub 账号。

## 为什么现在能被找到

`patpatpatrick.com` 当前的 DNS 是 `CNAME → pat-pat-patrick.github.io`，
而仓库里的 `CNAME` 文件又公开写着这个域名。任何人查一次 DNS，或者在
GitHub 搜一下域名，就直达你的账号。站点自身的 HTML 里没有任何 GitHub
链接——泄露完全来自托管方式，所以把 DNS 换成 VPS 的 A 记录、再关掉
Pages，这条线就断了。

## 文件

| 文件 | 在哪跑 | 作用 |
|------|--------|------|
| `bootstrap-vps.sh` | VPS, root | 装 nginx/certbot、建目录、开 80/443、先用 HTTP 把站点跑起来 |
| `deploy.sh` | 本地（能 SSH 到 VPS 的机器） | 本地构建 Jekyll，上传为一个新 release，原子切换 |
| `enable-https.sh` | VPS, root | DNS 切完之后签 Let's Encrypt 证书，换上完整 HTTPS 配置 |
| `nginx/patpatpatrick.com.conf` | 由 `enable-https.sh` 安装 | 正式站点配置（HTTPS、HSTS、gzip、缓存、301） |
| `nginx/tls-params.conf` | 由 `enable-https.sh` 安装到 `/etc/nginx/snippets/` | TLS 参数（Mozilla intermediate），放在 server 层以免和发行版 `nginx.conf` 冲突 |

服务器上的目录结构：

```
/var/www/patpatpatrick.com/
├── releases/20260101-120000/   每次部署一个带时间戳的目录，保留最近 5 个
├── releases/20260102-093000/
└── current -> releases/20260102-093000    nginx 的 root，一次 rename(2) 切换
```

`deploy.sh` 用 `rsync --link-dest` 对未变化的文件做硬链接，所以每次部署
只占实际改动的空间；切换是单次 `rename(2)`，nginx 不用 reload，访客也不会
看到半拉子的站点。

脚本会自动适配两件和 VPS 环境相关的事，不用手动改配置：

- **nginx 版本**：`http2 on;` 是 1.25.1 才有的指令。更老的版本（Ubuntu
  24.04 是 1.24，Debian 12 是 1.22）会被自动改写成 `listen ... ssl http2`。
- **IPv6**：机器上没有全局 IPv6 地址时，`listen [::]` 会让 nginx 直接起不
  来，所以这些行会被自动注释掉；有 IPv6 就保留。

## 在哪台机器上跑

三个脚本里**只有 `deploy.sh` 在你本地跑**,另外两个是在 VPS 上执行的 Linux
脚本,和你用 Mac 还是 Windows 无关。

**用 Mac。** 两个原因:

1. `arm-vps` 这个 SSH 别名在 `~/.ssh/config` 里,Mac 上配过。确认一下:
   ```bash
   grep -A4 'Host arm-vps' ~/.ssh/config
   ```
   如果想在别的机器上跑,要么把这段配置复制过去,要么直接传地址:
   ```bash
   SSH_HOST=ubuntu@<VPS_IP> ./deploy/deploy.sh
   ```
2. Mac 自带 `ssh` 和 `rsync`,Windows 两者都缺。

Mac 上还需要 Ruby 和 Jekyll(系统自带的 Ruby 2.6 太旧,Jekyll 要 2.7+):

```bash
brew install ruby
gem install jekyll bundler
# 或者在仓库目录里:  bundle install
```

`deploy.sh` 开头会先检查 `ssh`/`rsync`/`jekyll` 是否就位,缺了直接报出来,
不会跑到一半才失败。

### macOS 的两个坑(脚本已经处理)

- **`mktemp -d`**:BSD 版不接受不带模板的 `-d`,所以脚本用的是
  `mktemp -d "${TMPDIR:-/tmp}/patpatpatrick-build.XXXXXX"`,GNU 和 BSD 都认。
- **`rsync --link-dest`**:macOS 15 (Sequoia) 把 rsync 换成了 openrsync,没有
  这个选项。脚本会检测,没有就退化成完整拷贝——多占点磁盘,结果一样,不会报错。
  想要硬链接省空间可以 `brew install rsync` 用 3.x 版。

### 如果一定要在 Windows 上跑

- **Git Bash**:不行,没有 `rsync`。
- **WSL2**:可以,但要在 WSL 里重新配 `~/.ssh/config` 的 `arm-vps`(Windows 侧
  的配置 WSL 读不到)、装 `ruby`/`jekyll`,私钥也得放进 WSL。

不如直接用 Mac。

## 迁移步骤

**顺序很重要**：整个过程中站点一直在线，直到最后一步才关掉 GitHub Pages。

### 1. 本地准备

```bash
git clone <this repo> && cd pat-pat-patrick.github.io
bundle install          # 需要 Ruby 3.x
```

### 2. 初始化 VPS

```bash
scp -r deploy arm-vps:/tmp/deploy
ssh arm-vps 'sudo bash /tmp/deploy/bootstrap-vps.sh'
```

### 3. 推一版上去，在切 DNS 之前先验证

```bash
./deploy/deploy.sh
```

DNS 还指着 GitHub，所以用 Host 头直接打 VPS 的 IP 来验证：

```bash
curl -sS -H 'Host: patpatpatrick.com' http://<VPS_IP>/ | head -20
curl -sS -H 'Host: patpatpatrick.com' http://<VPS_IP>/2025/03/30/AI-in-Pharmaceuticals.../ | head -5
```

首页、某篇文章、`/about`、`/introduction.html` 都看一眼，确认样式和图片正常。

### 4. 切 DNS

在域名的 DNS 服务商处：

- **删掉** `patpatpatrick.com` 和 `www` 现有的 `CNAME → pat-pat-patrick.github.io`
- **加上** `A` 记录：`patpatpatrick.com → <VPS_IP>`（有 IPv6 就再加 `AAAA`）
- `www` 同样指向 `<VPS_IP>`（配置里会 301 到主域名）

把 TTL 先调到 300 秒，切换出问题好回滚。如果用 Cloudflare，**先保持
"DNS only"（灰云）**，等证书签下来再决定要不要开代理。

等解析生效：

```bash
dig +short patpatpatrick.com
```

### 5. 签证书，启用 HTTPS

```bash
ssh arm-vps 'sudo EMAIL=你的邮箱@example.com bash /tmp/deploy/enable-https.sh'
```

脚本会先核对 `patpatpatrick.com` 是不是真的解析到这台机器——没生效就直接
停下，免得白白消耗 Let's Encrypt 的签发限额。确实要跳过这个检查时加
`FORCE=1`。

验证：

```bash
curl -sSI https://patpatpatrick.com/ | head -1      # 200
curl -sSI http://patpatpatrick.com/  | head -2      # 301 -> https
curl -sSI https://www.patpatpatrick.com/ | head -2  # 301 -> apex
ssh arm-vps 'sudo certbot renew --dry-run'          # 续期演练
```

续期由 certbot 自带的 systemd timer 处理，`enable-https.sh` 已装好
reload 钩子，证书换了 nginx 会自动加载。

### 6. 关掉 GitHub Pages（确认 VPS 一切正常之后再做）

1. 仓库 **Settings → Pages → Source 选 None**
2. 删掉仓库里的 `CNAME` 文件（它只对 GitHub Pages 有意义，`deploy.sh`
   已经不会把它传到 VPS）
3. 仓库 **Settings → General → Change visibility → Private**
   （或者直接删掉；源码此时已在你本地和下面说的 VPS 仓库里）

做完这三步，域名和你的 GitHub 账号之间就没有任何可查的关联了。

## 之后怎么写新文章

加一个 `_posts/YYYY-MM-DD-标题.md`，然后：

```bash
./deploy/deploy.sh
```

本地预览：`bundle exec jekyll serve` → http://localhost:4000

想先看看会改动什么、不实际上传：

```bash
DRY_RUN=1 ./deploy/deploy.sh
```

### 可选：源码也不放 GitHub

在 VPS 上开一个裸仓库，以后 `git push vps` 就等于发布：

```bash
ssh arm-vps 'git init --bare ~/patpatpatrick.git'
git remote add vps arm-vps:patpatpatrick.git
git push vps master
```

构建仍然在本地做（VPS 上不用装 Ruby），`deploy.sh` 负责上传。这样 GitHub
可以彻底不要。

## 排障

```bash
ssh arm-vps 'sudo nginx -t'                                        # 配置语法
ssh arm-vps 'sudo tail -30 /var/log/nginx/patpatpatrick.error.log' # 错误日志
ssh arm-vps 'ls -l /var/www/patpatpatrick.com/current'             # 当前指向哪个 release
```

回滚到上一个 release：

```bash
ssh arm-vps 'cd /var/www/patpatpatrick.com && ls -1 releases | sort -r'
ssh arm-vps 'cd /var/www/patpatpatrick.com && ln -sfn $PWD/releases/<某个时间戳> current.new && mv -Tf current.new current'
```

端口不通（OCI/ARM 的镜像默认只放 22）：`bootstrap-vps.sh` 已经处理了
iptables 和 ufw，但云控制台那一层的安全组/安全列表要自己去放行 80 和 443。

## 这套配置已经验证过什么

在一台 Ubuntu 24.04 / nginx 1.24 的容器里，用自签证书把这份配置完整跑过一遍：

- 首页、`/about/`、`/introduction.html`、`/page/2/`、`/styleguide/`、
  `sitemap.xml`、`search.json`、`favicon.ico` 全部 200
- 所有文章页 200，包括 URL 里带中文（`谈信仰`、`中美-消耗战-博弈…`）、
  带变音符（`Gödel`）和带撇号（`We've`）的那几篇
- `http → https`、`www → 主域名` 都是 301，且重定向时保留了百分号编码的路径
- 不存在的路径返回 404，并且用的是主题自己的 `404.html`
- 响应头：HSTS、`nosniff`、`Referrer-Policy` 都在；HTML `max-age=600`，
  图片/CSS/JS `max-age=2592000`
- gzip 生效，首页 49.7 KB → 12.8 KB。**这一项对本站特别重要**：Zolan 主题
  用 `scssify` 把 34 KB 的 CSS 直接内联进每个页面的 `<style>` 里，站点没有
  独立的 .css 文件，全靠 gzip 压。
- `.well-known/acme-challenge/` 在 HTTP 下可取到文件，所以 certbot 的
  webroot 签发能走通
- release 原子切换、保留最近 5 个、以及「`current` 被 pin 在某个旧 release
  上时不会被误删」的回滚场景

没能在这里验证的只有真机相关的部分：真实的 Let's Encrypt 签发、你的云控制
台安全组、以及 DNS 生效——这些要在 VPS 上按上面的步骤走。
