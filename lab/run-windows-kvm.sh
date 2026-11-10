#!/usr/bin/env bash
set -euo pipefail
task_lab="$RUNNER_TEMP/researchhv-windows"
mkdir -p "$task_lab"
cd "$task_lab"
echo 'Read-only host capability preflight'
lscpu | grep -E 'Architecture:|Vendor ID:|Model name:|Virtualization:|Hypervisor vendor:' || true
ls -l /dev/kvm || true
task_cpu=''
if grep -qw vmx /proc/cpuinfo; then
  task_cpu='host,vmx=on'
  task_nested='/sys/module/kvm_intel/parameters/nested'
elif grep -qw svm /proc/cpuinfo; then
  task_cpu='host,svm=on'
  task_nested='/sys/module/kvm_amd/parameters/nested'
else
  echo 'This runner exposes neither VMX nor SVM; stopping before download.'
  exit 1
fi
if [ ! -e /dev/kvm ] || [ ! -r "$task_nested" ] || ! grep -Eqi '^(Y|1)$' "$task_nested"; then
  echo 'KVM or its nested capability is unavailable; stopping before download.'
  exit 1
fi
cat "$task_nested"
df -h .
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils libguestfs-tools gcc-mingw-w64-x86-64-posix
# Official Microsoft Evaluation Center -> English Windows Server 2022 VHD.
# No project sources, driver, account credentials, or VM disk leave this job.
task_vhd_url='https://go.microsoft.com/fwlink/p/?clcid=0x409&country=us&culture=en-us&linkid=2195166'
task_expected_bytes=10208214528
task_free_bytes=$(df -B1 --output=avail . | tail -1 | tr -d ' ')
if (( task_free_bytes < task_expected_bytes + 2500000000 )); then
  echo "Insufficient disk for VHD and overlay: $task_free_bytes bytes free"
  exit 1
fi
curl --fail --location --retry 3 --max-time 600 --output base.vhd "$task_vhd_url"
test "$(stat -c %s base.vhd)" = "$task_expected_bytes"
sha256sum base.vhd
qemu-img info -f vpc base.vhd
qemu-img create -f qcow2 -F vpc -b "$task_lab/base.vhd" guest.qcow2
cat > cpuid.c <<'EOF'
#include <cpuid.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    unsigned a,b,c,d; char vendor[13]={0};
    if (!__get_cpuid(0,&a,&b,&c,&d)) return 1;
    memcpy(vendor,&b,4); memcpy(vendor+4,&d,4); memcpy(vendor+8,&c,4);
    printf("CPU vendor: %s\n",vendor);
    if (__get_cpuid(1,&a,&b,&c,&d)) {
        printf("VMX exposed: %u\nOuter hypervisor: %u\n",(c>>5)&1,(c>>31)&1);
    }
    if (__get_cpuid(0x80000001,&a,&b,&c,&d)) printf("SVM exposed: %u\n",(c>>2)&1);
    puts("CPUID only; no VMXON, VMLAUNCH, or ResearchHV driver executed.");
    return 0;
}
EOF
x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -static cpuid.c -o cpuid.exe
cp "$GITHUB_WORKSPACE/lab/guest-probe.ps1" guest-probe.ps1
cat > unattend.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>HV-KVM-LAB</ComputerName>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
          <Order>1</Order>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\guest-probe.ps1</Path>
          <Description>Read-only virtualization capability probe</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
EOF
export LIBGUESTFS_BACKEND=direct
# Only the ephemeral job-owned Windows overlay is modified.
sudo --preserve-env=LIBGUESTFS_BACKEND guestfish --rw -a guest.qcow2 -i <<'EOF'
mkdir-p /Lab
mkdir-p /Windows/Panther
upload unattend.xml /Windows/Panther/unattend.xml
upload guest-probe.ps1 /Lab/guest-probe.ps1
upload cpuid.exe /Lab/cpuid.exe
EOF
echo 'Booting Windows with CPU passthrough; network and external access disabled.'
task_qemu_pid=''
task_cleanup() {
  if [ -n "$task_qemu_pid" ] && kill -0 "$task_qemu_pid" 2>/dev/null; then
    kill -TERM "$task_qemu_pid" 2>/dev/null || true
    wait "$task_qemu_pid" 2>/dev/null || true
  fi
}
trap task_cleanup EXIT
sudo timeout --signal=TERM --kill-after=20s 1200s qemu-system-x86_64 \
  -accel kvm -machine pc -cpu "$task_cpu" -smp 2 -m 4096 \
  -drive file=guest.qcow2,format=qcow2,if=ide,cache=writeback \
  -boot c -nic none -display none -monitor none \
  -serial "file:$task_lab/serial.log" -no-reboot >qemu.log 2>&1 &
task_qemu_pid=$!
task_seen=0
for ((task_i=0; task_i<240; task_i++)); do
  if [ -f serial.log ] && grep -q RESEARCHHV_WINDOWS_PROBE_FINISHED serial.log; then
    task_seen=1
    break
  fi
  if ! kill -0 "$task_qemu_pid" 2>/dev/null; then break; fi
  if (( task_i % 12 == 0 )); then echo "Windows boot in progress: $((task_i * 5)) seconds"; fi
  sleep 5
done
cat serial.log 2>/dev/null || true
cat qemu.log
if (( task_seen == 0 )); then
  echo 'Windows did not return a completed probe; this run is not a successful guest test.'
  exit 1
fi
wait "$task_qemu_pid"
task_qemu_pid=''
python3 - <<'PY'
import json
from pathlib import Path
lines = Path('serial.log').read_text(errors='replace').splitlines()
result = next(json.loads(s.split('RESEARCHHV_RESULT ', 1)[1]) for s in lines if 'RESEARCHHV_RESULT ' in s)
print(json.dumps(result, indent=2))
if not result.get('success'):
    raise SystemExit('Windows probe reported an error')
if not any(s in result.get('cpuid', []) for s in ('VMX exposed: 1', 'SVM exposed: 1')):
    raise SystemExit('Neither VMX nor SVM is exposed inside Windows')
PY
