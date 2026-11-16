# Android Payload Patcher

> 肘击联想并被共享库缺失惹毛之后的产物。如果你有构建环境，出门右转自己搭工具链。

Android A/B OTA payload 工具包，将基准 payload 进行增量包补丁后输出补丁版 payload, 然后用 testkey 签名生成新的 payload OTA ZIP 包。

## 用法

一键：给两个 OTA ZIP，剩下交给脚本。

```
./ota_zip_merge.sh --base_zip BASE_OTA.zip --delta_zip DELTA_OTA.zip [--out_zip OUT.zip] [--dry_run]

./ota_zip_merge.sh \
    --base_zip TB710FU_ZUXOS_2.5.02.089_ee19c9.zip \
    --delta_zip 20261113113632239-6680_TB710FU_CN_OPEN_USER_Q00019.0_A17_DF_18.5.02.089_DEV_261030_to_TB710FU_CN_OPEN_USER_Q00019.0_A17_ZUI_18.5.10.102_ST_261112.zip
```

- `--base_zip`：基准（完整）OTA ZIP
- `--delta_zip`：增量 OTA ZIP
- `--out_zip`：输出包，默认 `delta_out/<增量包的 post-build-incremental>.zip`（取不到时退到 `post-build`，再不行就用 `merged_ota.zip`）
- `--dry_run`：只做参数检查和解压，打印将要执行的主脚本命令，不真正合并

包装脚本会先把基准 ZIP 解到 `base/`、增量 ZIP 解到 `delta/`（同名文件覆盖写，可以反复跑），检查 `payload.bin` 和 delta 需要的 4 个元数据文件都在，然后按 `ota_delta_to_full.sh BASE_PAYLOAD DELTA_PAYLOAD DELTA_DIR OUT_ZIP` 拉起主脚本。Windows 路径可以直接写（`F:\dir\file.zip` 自动映射成 `/mnt/f/dir/file.zip`），路径带空格也没问题。

也可以跳过包装脚本，直接调用主脚本：

```
./ota_delta_to_full.sh BASE_PAYLOAD DELTA_PAYLOAD DELTA_DIR OUT_ZIP

./ota_delta_to_full.sh base/payload.bin delta/payload.bin delta out/TB710FU_ZUXOS_2.5.02.089.zip
```

- BASE_PAYLOAD：旧版本的**完整** OTA payload
- DELTA_PAYLOAD：增量 payload
- DELTA_DIR：delta OTA 解包目录，需要含 `META-INF/com/android/metadata`、`META-INF/com/android/metadata.pb`、`apex_info.pb`、`care_map.pb`
- OUT_ZIP：输出包；中间产物写在 `$(dirname OUT_ZIP)/work/`（base 解包镜像、合并后镜像、payload.bin、properties、签名），跑完可删

主脚本本身不校验参数、不打印进度、不处理错误，任一步失败直接退出（`ota_zip_merge.sh` 负责参数检查、解压和错误提示）。

## 运行环境要求

- x86_64 Linux（本包在 WSL2 Ubuntu 22.04 验证），二进制为动态链接，所需 .so 全部已内置
- `sh` + coreutils（`head`、`stat`、`cut`、`sed`、`nproc`）、`unzip`（6.0+，包装脚本解压 OTA ZIP 用）
- `python3`（3.8+ 即可，protobuf 已内置纯 python 实现）
- `openssl` 3.x（用到 `pkcs8` 与 `cms -sign`）
- 磁盘：约 4 倍 payload 大小的空闲空间（base 镜像 + 合并镜像 + payload + zip）；用包装脚本时再加一份解压出来的 base payload，即约 5 倍
- 内存：测试平台为 20 GiB RAM + 8 GiB swap, 低于此配置的机器不保证能成功合成。

## 产物校验

```
python3 -c 'import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).testzip())' delta_out/xxx.zip
```

输出 `None` 表示 CRC 全部正确。生成的 zip 与官方包结构一致：7 个条目、payload.bin 为 STORED、
whole-file 签名放在 zip comment 里。

## 注意

- `bin/delta_generator` 是从我设备上的 twrp 源码树顺的，因此缺 `external/divsufsort`，构建时补了一个 stub：
  完整包（本流程只用这一种）不受影响，但**不能**用它生成 bsdiff 增量包（会 abort）。
- testkey 仅供自签名；官方 OTA / 官方 recovery 正常情况无法安装这些 OTA 包，需要绕过签名校验或使用第三方 Recovery。

## 目录

```
ota_zip_merge.sh       包装脚本：两个 OTA ZIP -> 解压到 base/、delta/ -> 调 ota_delta_to_full.sh
ota_delta_to_full.sh   合并流程：基准 payload + delta -> 新 payload + 完整 OTA zip
bin/ota_extractor      AOSP update_engine 的 host 版 ota_extractor（解包 / 增量合并 / 重算 verity+FEC）
bin/delta_generator    AOSP host 版 delta_generator（生成 full payload）
lib64/                 上面两个二进制依赖的 AOSP host 共享库（32 个，RUNPATH=$ORIGIN/../lib64）
keys/testkey.pk8       payload / zip 签名用私钥（AOSP testkey，自签名用途）
keys/testkey.x509.pem  对应证书（同时作为 zip 里的 META-INF/com/android/otacert）
pylib/                 内嵌 python protobuf 3.20.3（纯 python 实现）+ update_metadata_pb2 / ota_metadata_pb2
proto/                 原始 .proto，仅作参考或重新生成 pb2
base/                  包装脚本解出的基准 OTA 内容（payload.bin、META-INF/...）
delta/                 包装脚本解出的增量 OTA 内容（payload.bin、META-INF/...、apex_info.pb、care_map.pb）
delta_out/             默认输出目录（输出 zip + work/ 中间产物）
```