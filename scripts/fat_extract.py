#!/usr/bin/env python3
"""从原厂 modem 分区 FAT 镜像中抽取基带固件（MBA/MPSS）。

来源镜像：openstick 社区 dump 的各机型原厂系统 modem 分区（FAT16/FAT32），
其中的 IMAGE/ 目录含 MBA.MBN、MODEM.MDT/MODEM.bXX（基带）以及 WCNSS.*（WiFi/BT）。

本工具只做提取：把 mba.mbn + modem.* 按小写文件名写到输出目录（内核
request_firmware 用的就是这些小写名字），不修改任何内容。

用法:
  python3 fat_extract.py <image.bin> <outdir>       # 抽取基带到 outdir/
  python3 fat_extract.py <image.bin> --ls [path]    # 列出镜像内容
"""
import os
import re
import struct
import sys

# 基带 = MBA（引导） + MPSS（modem.mdt + 分段 bXX）；WCNSS.* 不在此列
PATTERN = re.compile(r"^(mba\.mbn|modem\.[a-z0-9]+)$")


class FatImage:
    """最小 FAT16/FAT32 只读实现，仅支持 8.3 短名（原厂 modem 分区足够）。"""

    def __init__(self, path):
        self.f = open(path, "rb")
        b = self._read(0, 512)
        self.bps = struct.unpack_from("<H", b, 11)[0]
        self.spc = b[13]
        self.reserved = struct.unpack_from("<H", b, 14)[0]
        self.nfats = b[16]
        self.root_entries = struct.unpack_from("<H", b, 17)[0]
        total16 = struct.unpack_from("<H", b, 19)[0]
        fat16 = struct.unpack_from("<H", b, 22)[0]
        self.fat_size = fat16 or struct.unpack_from("<I", b, 36)[0]
        self.fat_type = "fat16" if fat16 else "fat32"
        self.root_cluster = struct.unpack_from("<I", b, 44)[0] if fat16 == 0 else None
        self.fat_off = self.reserved * self.bps
        self.data_off = (self.reserved + self.nfats * self.fat_size) * self.bps
        if self.fat_type == "fat16":
            self.data_off += self.root_entries * 32

    def _read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def _fat_entry(self, cl):
        if self.fat_type == "fat16":
            v = struct.unpack_from("<H", self._read(self.fat_off + cl * 2, 2), 0)[0]
            return v, v >= 0xFFF8
        v = struct.unpack_from("<I", self._read(self.fat_off + cl * 4, 4), 0)[0] & 0x0FFFFFFF
        return v, v >= 0x0FFFFFF8

    def _chain(self, first):
        cl, out = first, []
        while 2 <= cl < 0x0FFFFFF0:
            out.append(cl)
            cl, eoc = self._fat_entry(cl)
            if eoc:
                break
        return out

    def _cluster(self, cl):
        return self._read(self.data_off + (cl - 2) * self.spc * self.bps, self.spc * self.bps)

    def read_file(self, first, size):
        return b"".join(self._cluster(c) for c in self._chain(first))[:size]

    def _dir(self, first_cluster=None):
        """返回 [(短名, 属性, 起始簇, 大小)]；first_cluster 为空时读根目录。"""
        if self.fat_type == "fat16" and first_cluster is None:
            raw = self._read(self.data_off - self.root_entries * 32,
                             self.root_entries * 32)
        elif first_cluster is None:
            first_cluster = self.root_cluster
        if first_cluster is not None:
            raw = b"".join(self._cluster(c) for c in self._chain(first_cluster))
        entries = []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0x00:  # 目录结束
                break
            if e[0] == 0xE5 or e[11] == 0x0F:  # 已删除 / LFN，跳过
                continue
            name = e[0:8].decode("ascii", "replace").rstrip()
            ext = e[8:11].decode("ascii", "replace").rstrip()
            short = name + ("." + ext if ext else "")
            first = (struct.unpack_from("<H", e, 20)[0] << 16) | \
                    struct.unpack_from("<H", e, 26)[0]
            entries.append((short, e[11], first, struct.unpack_from("<I", e, 28)[0]))
        return entries

    def walk(self, path="/"):
        """遍历 path，产出 (完整路径, 起始簇, 大小)。"""
        entries = self._dir()
        for p in [x for x in path.strip("/").split("/") if x]:
            match = [e for e in entries if e[0].upper() == p.upper()]
            if not match:
                raise FileNotFoundError(f"{p} not found")
            entries = self._dir(match[0][2])
        stack = [("/", e) for e in entries]
        while stack:
            base, (name, attr, first, size) = stack.pop()
            full = base + name
            if attr & 0x10:  # 目录
                if name in (".", ".."):
                    continue
                stack.extend((full + "/", e) for e in self._dir(first))
            elif not attr & 0x08:  # 普通文件（跳过卷标）
                yield full, first, size


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    img = FatImage(sys.argv[1])
    arg = sys.argv[2]
    if arg == "--ls":
        for full, _first, size in sorted(img.walk(sys.argv[3] if len(sys.argv) > 3 else "/")):
            print(f"{size:>12}  {full}")
        return
    outdir = arg
    os.makedirs(outdir, exist_ok=True)
    for full, first, size in img.walk("/"):
        name = os.path.basename(full).lower()
        if PATTERN.fullmatch(name):
            with open(os.path.join(outdir, name), "wb") as o:
                o.write(img.read_file(first, size))
            print(f"{size:>12}  {full} -> {outdir}/{name}")


if __name__ == "__main__":
    main()
