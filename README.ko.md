[English](README.md) | **한국어**

# dsonode

만들고 싶은 VM과 LXC를 YAML 파일 하나에 적습니다. `dsonode up` 하면 Proxmox VE에 네트워크까지 만들어 주고, Ansible inventory를 돌려줍니다. `dsonode down` 하면 다시 깨끗하게 사라집니다.

```bash
dsonode new lab1      # API에서 본 값으로 nodes.yml을 채워 줌
dsonode up lab1       # 네트워크 + VM/LXC + inventory
ansible -i "$(dsonode inventory lab1)" all -m ping
```

속은 평범한 OpenTofu(bpg/proxmox)이고, 그 위에 작은 bash 스크립트가 있을 뿐입니다. 꼭 필요한 권한만 가진 API 토큰으로 돌아가고, [proxmox-iac-bootstrap](https://github.com/combatreadiness/proxmox-iac-bootstrap)이 만든 관리 노드에서는 따로 설정할 게 없습니다. 일반 Proxmox 호스트에서도 됩니다.

## 무엇이 만들어지나

VM 하나, LXC 하나짜리 묶음(set) `lab1`을 예로 들면 이렇습니다.

```
SDN Zone "lab"
├── VNet "labmg"   10.73.10.0/24   관리 노드 (proxmox-iac-bootstrap)
└── VNet "labn1"   10.73.40.0/24   묶음 lab1 (dsonode-lab1), 인터넷은 SNAT
    ├── VM  201  cp1    10.73.40.11   VM 템플릿을 복제, SSH 사용자 debian
    └── LXC 202  git    10.73.40.21   LXC 템플릿으로 생성, unprivileged, SSH 사용자 root

Pool lab-workloads    게스트가 들어가는 곳

~/.config/dsonode/lab1/
├── nodes.yml           무엇을 만들지 (직접 고치는 파일)
├── inventory.yml       Ansible inventory, `dsonode up`이 씀
├── terraform.tfstate   실제로 만들어진 것
└── known_hosts         이 묶음의 호스트 키만
```

`nodes.yml`의 `roles`에 적은 이름은 그대로 Ansible 그룹이 됩니다. 다음 단계와의 약속은 이게 전부입니다. [dsokube](https://github.com/combatreadiness/dsokube)는 `k3s_cluster`, `server`, `agent` 그룹을 가져가고, 직접 만든 플레이북은 자기 그룹을 가져가면 됩니다.

## nodes.yml

`dsonode new`가 모든 키를 채워서 만들어 줍니다.

```yaml
provider: proxmox

proxmox:
  node: p82-proxmox-01
  pool: lab-workloads
  storage: local-lvm           # VM 디스크와 cloud-init 드라이브
  template: 9000               # 복제할 VM 템플릿 ID (type: vm)
  lxc_template: "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

network:
  mode: sdn                    # sdn: 전용 VNet을 새로 만듦 | bridge: 기존 브리지에 붙음
  zone: lab
  vnet: labn1                  # dsonode가 만듦, 최대 8자
  cidr: 10.73.40.0/24          # 노드 IP = 이 대역의 host 번호

vmid_start: 201                # 여기서부터 비어 있는 VM ID를 차례로 받음

defaults:
  vm:  { cores: 2, memory: 2048, disk: 20 }   # MiB, GB
  lxc: { cores: 1, memory: 1024, disk: 8 }

nodes:
  cp1: { vmid: 201, type: vm,  host: 11, memory: 4096, roles: [k3s_cluster, server] }
  git: { vmid: 202, type: lxc, host: 21, roles: [git] }
```

`new`가 알아서 골라 주는 것은 이렇습니다.

- **노드, Pool, 스토리지, 템플릿**: 이 토큰이 쓸 수 있는 것 중 첫 번째
- **네트워크**: 토큰이 SDN Zone에 VNet을 만들 수 있으면 새 VNet `<zone>n1`, `<zone>n2`, ...와, `C = 40`부터 비어 있는 첫 `10.N.C.0/24` 대역을 고릅니다. 관리망과 다른 묶음의 대역은 피합니다. SDN 권한이 없으면 기존 브리지에 붙는 `mode: bridge`로 만들고, 이때는 `cidr`를 그 네트워크에 맞게 고쳐야 합니다.
- **VM ID**: `vmid_start`(부트스트랩 관리 노드면 201, 아니면 100)부터 비어 있는 번호. `plan`이나 `up`을 할 때 각 노드 줄에 적어 두니, 한 번 받은 번호는 바뀌지 않습니다.

노드마다 `cores`, `memory`, `disk`, `roles`를 정할 수 있고, LXC는 `nesting: true`(안에서 Docker를 돌릴 때)도 됩니다. 노드는 **한 줄에 하나씩** 써 주세요. dsonode가 그 줄에 `vmid:`를 끼워 넣습니다.

bridge 모드에서는 `bridge`, `vlan`, `gateway`(기본값 host 1), `dns`(기본값 `1.1.1.1`)도 읽습니다.

## 요구사항

- Proxmox VE 8.x, 단일 노드. 8.4에서 확인했습니다.
- dsonode를 돌릴 머신에 bash, curl, jq, OpenTofu 1.8 이상, `~/.ssh/id_ed25519.pub`. proxmox-iac-bootstrap 관리 노드에는 다 있습니다.
- Debian 12 cloud-init VM 템플릿(`dsoadm template`이 만들어 줌), 또는 Debian LXC 템플릿(`pveam download`)
- API 토큰. 아래 중 하나로 줍니다.
  - 환경 변수 `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` (필요하면 `PROXMOX_VE_INSECURE`)
  - 그 줄들이 담긴 파일: `DSONODE_CRED=/path/to/file`
  - proxmox-iac-bootstrap 자격 증명 파일. 하나만 있으면 알아서 찾습니다

토큰으로 될지 모르겠다면 `dsonode doctor`를 돌려보세요. API를 읽어서 이 토큰이 쓸 수 있는 Pool, 스토리지, SDN Zone, 템플릿, 브리지를 보여줍니다. 아무것도 바꾸지 않습니다.

## 설치

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsonode/main/install.sh)"
dsonode doctor
```

## 명령

| 명령 | 하는 일 |
|---|---|
| `dsonode doctor [--cred FILE]` | 도구, API, 토큰 권한, 스토리지, 템플릿, 네트워크 점검. 읽기만 함 |
| `dsonode new <set>` | API에서 본 값으로 `~/.config/dsonode/<set>/nodes.yml` 작성 |
| `dsonode list` | 모든 묶음과 생성 여부 |
| `dsonode plan <set>` | OpenTofu가 바꿀 내용. 빠진 VM ID를 채우고, 만들지는 않음 |
| `dsonode up <set> [-y]` | 만들고, inventory를 쓰고, 모든 노드가 SSH에 응답할 때까지 기다림 |
| `dsonode inventory <set>` | inventory 경로 출력 |
| `dsonode down <set> [-y] [--purge]` | 게스트와 VNet 삭제. `--purge`는 `nodes.yml`까지 지움 |

묶음마다 OpenTofu 상태가 따로 있어서, 묶음끼리 서로 건드리지 않습니다. 파일을 바꾸지 않고 `up`을 다시 하면 `No changes`가 나와야 합니다.

노드를 추가하려면 줄을 하나 더 쓰고 `dsonode up <set>`을 하면 됩니다. 새 게스트만 만들어집니다.

## 보안

- 토큰은 curl에는 헤더 파일로, OpenTofu에는 환경 변수로만 넘깁니다. 화면에 찍지 않고, `doctor`도 토큰 ID만 보여줍니다.
- `nodes.yml`, `inventory.yml`, 상태 파일은 권한 600, 폴더는 700입니다.
- SSH 호스트 키는 묶음마다 따로 `known_hosts`에 저장합니다. 게스트를 다시 만들어도 내 `~/.ssh/known_hosts`와 충돌하지 않습니다.
- 게스트에는 관리 노드의 공개 키만 넣습니다. 비밀번호는 쓰지 않습니다.

## 알려진 제약

- Proxmox VE 9에서는 아직 시험하지 않았습니다.
- 게스트가 Debian이라고 가정합니다. VM의 SSH 사용자 `debian`, LXC `ostype` `debian`, VM 디스크 `scsi0`(`dsoadm template`이 만드는 구성)
- LXC는 태그 없이 만듭니다. Pool로 권한을 좁힌 토큰이면, Proxmox가 새 컨테이너를 Pool에 넣기 전에 `/vms/<id>` 기준으로 태그 권한을 확인해서 거절하기 때문입니다.
- 이미 만들어진 노드 줄에서 `vmid:`를 지우면 새 번호를 받고, OpenTofu가 그 게스트를 새로 만듭니다.
- 토큰이 노드에 가진 권한에 따라 `doctor`가 `vmbr0`을 못 보여줄 수 있습니다. 브리지 이름을 직접 적으면 bridge 모드는 그대로 됩니다.
- 단일 노드 Proxmox만 지원합니다.

## 라이선스

Apache-2.0. [LICENSE](LICENSE)를 보세요.
