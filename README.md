# gcp-freevm脚本
这个 Bash 脚本可以帮助你在google shell中快速部署 debian 12 系统的 us free vm。

### 通过一键脚本自定义安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hide3110/gcp-freevm/main/gcp.sh)
```

## 详细说明
- 默认安装 debian 12 系统，自定义所开的免费区域机器，需要自行修改配置文件
- Oregon区域：us-west1-a, us-west1-b, us-west1-c
- Iowa区域：us-central1-a, us-central1-b, us-central1-c, us-central1-f
- South Carolina区域:us-east1-b, us-east1-c, us-east1-d
