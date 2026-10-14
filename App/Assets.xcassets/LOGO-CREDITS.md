# OS Logo Credits

`os-*.imageset` 资源用于在 UI 中标识远程主机的操作系统（nominative use）。
图形商标归各发行版/公司所有；此处仅记录每个文件的获取来源与许可证。

## Simple Icons（CC0-1.0）

以下 logo 来自 [Simple Icons](https://simpleicons.org)，矢量路径为官方 logo
的真实轮廓，填充色为官方品牌色。许可证：[CC0 1.0 Universal](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md)。
获取形式：`https://cdn.simpleicons.org/<slug>`。

| Asset | Slug | 商标方 |
|---|---|---|
| os-ubuntu | ubuntu | Canonical |
| os-fedora | fedora | Fedora Project / Red Hat |
| os-arch | archlinux | Arch Linux |
| os-alpine | alpinelinux（path 数据做了空白规整，图形未改） | Alpine Linux |
| os-kali | kalilinux（龙形线条细，垫了白色圆角衬底） | Kali Linux / OffSec |
| os-centos | centos | CentOS Project / Red Hat |
| os-rocky | rockylinux | Rocky Enterprise Software Foundation |
| os-rhel | redhat | Red Hat |
| os-suse | opensuse | openSUSE / SUSE |
| os-mint | linuxmint | Linux Mint |
| os-manjaro | manjaro | Manjaro |
| os-gentoo | gentoo | Gentoo Foundation |
| os-nixos | nixos | NixOS Foundation |
| os-void | voidlinux | Void Linux |
| os-freebsd | freebsd | FreeBSD Foundation |
| os-alma | almalinux（本体为黑色，垫了白色圆角衬底） | AlmaLinux OS Foundation |

## Wikimedia Commons

| Asset | 文件 | 许可 |
|---|---|---|
| os-debian | [File:Openlogo-debianV2.svg](https://commons.wikimedia.org/wiki/File:Openlogo-debianV2.svg) | Public domain（Debian Project） |
| os-linux | [File:Tux-flat.svg](https://commons.wikimedia.org/wiki/File:Tux-flat.svg) | CC BY-SA 4.0，作者 Josef Norlin（基于 Larry Ewing 的 Tux）；垫了白色圆角衬底 |
| os-windows | [File:Windows_logo_-_2021.svg](https://commons.wikimedia.org/wiki/File:Windows_logo_-_2021.svg) | 公有领域（简单几何图形，PD-textlogo）；Windows 为 Microsoft 注册商标 |

## 说明

- `os-alma`（黑色 logo）与 `os-linux`（Tux 黑色身体）在深色 chrome 上不可读，
  因此在 SVG 底层垫了白色圆角衬底（logo 本体未改动）。
- `os-oracle`（Oracle Linux）有意未收录：Oracle 官方 logo 是 231×30 的纯文字
  wordmark，缩放到图标尺寸不可读；UI 回退为品牌色首字母。
- Amazon Linux 无独立官方图标（Simple Icons 不含 amazon），同样回退首字母。
- macOS 不使用图片资源：直接用 SF Symbols 的 `apple.logo`（即官方 Apple 图形）。
- `os-alpine` 的 Simple Icons 路径数据会让 actool 在编译期打印一行 CoreSVG
  警告（渲染结果不受影响，已实测各尺寸渲染正确）；官方横版 logo 是
  665×162 wordmark，不适配方形图标位，故仍用 Simple Icons 版本。
