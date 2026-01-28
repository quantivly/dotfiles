# SSH Configuration Guide

Comprehensive guide for optimizing SSH client configuration with connection multiplexing, stability improvements, SSH agent integration, and security best practices.

## Table of Contents

- [Quick Start (5 Minutes)](#quick-start-5-minutes)
- [Deployment Contexts](#deployment-contexts)
- [Connection Multiplexing](#connection-multiplexing)
- [Connection Stability](#connection-stability)
- [SSH Agent Integration](#ssh-agent-integration)
- [Agent Forwarding](#agent-forwarding)
- [Host Patterns and Examples](#host-patterns-and-examples)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)

## Quick Start (5 Minutes)

**1. Copy the template:**
```bash
ssh-init  # Creates ~/.ssh/config from template
```

**2. Create socket directory (already done by `./install`):**
```bash
mkdir -p ~/.ssh/sockets && chmod 700 ~/.ssh/sockets
```

**3. Customize for your context:**

**If you're on a LAPTOP** (connecting TO remote servers):
```bash
vim ~/.ssh/config

# Uncomment and customize:
# - Bitwarden IdentityAgent (if using Bitwarden SSH agent)
# - ForwardAgent for trusted work servers
# - Host definitions (dev, staging, personal servers)
```

**If you're on a REMOTE SERVER** (receiving SSH connections):
```bash
vim ~/.ssh/config

# Keep it minimal - uncomment only:
# - GitHub host config
# - Other internal servers you need to reach
# Do NOT configure Bitwarden (use forwarded agent from laptop instead)
```

**4. Test connection multiplexing:**
```bash
# First connection (normal speed)
time ssh myserver exit

# Second connection (should be instant - reuses socket)
time ssh myserver exit
```

You should see the second connection complete in < 1 second!

## Deployment Contexts

This SSH configuration is used in **two distinct contexts**. Understanding your context determines how you configure your `~/.ssh/config`.

### Context Comparison

| Aspect | Laptop (SSH Client) | Remote Server (SSH Server + Client) |
|--------|---------------------|-------------------------------------|
| **Primary Role** | Connect TO remote servers | Receive connections + connect to others |
| **SSH Agent Source** | Bitwarden desktop app or system agent | Forwarded agent from laptop or system agent |
| **ForwardAgent** | Yes (for trusted servers) | Usually no (already remote) |
| **Host Definitions** | Many (dev, staging, VPS, etc.) | Minimal (GitHub, internal servers) |
| **IdentityAgent** | Bitwarden socket path | Not configured (uses forwarded/system) |
| **ControlMaster** | Yes (speeds up connections) | Yes (speeds up outbound connections) |
| **Typical Use Cases** | Daily dev work, deployments | Git operations, internal API calls |

### Context 1: Laptop Configuration

**Environment:**
- Your personal laptop or workstation
- Runs Bitwarden desktop app with SSH agent (or system agent)
- SSH client connecting TO remote servers
- Initiates agent forwarding to trusted servers

**What to Configure:**
```ssh
Host *
    # Universal defaults (always enable)
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m
    ServerAliveInterval 60
    ServerAliveCountMax 3

    # Bitwarden SSH agent (choose your install method)
    IdentityAgent ~/.config/Bitwarden/.bitwarden-ssh-agent.sock

# Enable agent forwarding for work servers
Host dev staging demo2 qspace
    ForwardAgent yes

# Define all servers you connect to
Host dev
    HostName ec2-xx-xx-xx-xx.compute-1.amazonaws.com
    User ubuntu
    ForwardAgent yes

Host staging
    HostName ec2-yy-yy-yy-yy.compute-1.amazonaws.com
    User ubuntu
    ForwardAgent yes

Host github.com
    AddKeysToAgent yes
```

**Typical Workflow:**
```bash
# From laptop
ssh dev                    # Connect to dev server (forwards agent)
# Now on dev server
git commit -S              # Uses forwarded keys for signing
ssh github.com             # Works with forwarded keys
```

### Context 2: Remote Server Configuration

**Environment:**
- AWS EC2 development machine or similar remote server
- Receives SSH connections FROM laptops (SSH server role)
- Also makes outbound SSH connections (SSH client role)
- Receives forwarded agent from laptop (uses laptop's keys)
- Runs system SSH agent for local file-based keys (via zshrc.local)

**What to Configure:**
```ssh
Host *
    # Universal defaults (always enable)
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m
    ServerAliveInterval 60
    ServerAliveCountMax 3

    # DO NOT configure IdentityAgent here
    # Use forwarded agent from laptop or system agent instead

# Minimal host definitions
Host github.com
    AddKeysToAgent yes

# Other internal servers (if needed)
Host staging
    HostName ec2-zz-zz-zz-zz.compute-1.amazonaws.com
    User ubuntu
```

**Key Points:**
- **NO Bitwarden configuration** - Remote servers don't run Bitwarden desktop app
- **Receive forwarded agent** - Laptop forwards its agent when connecting
- **System agent for local keys** - Auto-started by `~/.zshrc.local` for file-based keys
- **Minimal host list** - You're already ON dev, not connecting TO it

**Typical Workflow:**
```bash
# From laptop (with ForwardAgent yes)
ssh dev                    # Connect to dev server, forwards agent

# Now on dev server (receives forwarded agent)
echo $SSH_AUTH_SOCK        # Shows forwarded agent socket
ssh-add -l                 # Lists keys from laptop
git commit -S              # Uses forwarded keys for signing
ssh github.com             # Works with forwarded keys
```

### Choosing Your Configuration

**How to decide:**

1. **Am I sitting at this machine physically/primarily?**
   - Yes → Laptop configuration (define all servers you connect to)
   - No → Remote server configuration (minimal, GitHub + internal)

2. **Where is Bitwarden running?**
   - Desktop app here → Laptop configuration (configure IdentityAgent)
   - Desktop app elsewhere → Remote server (use forwarded agent, no IdentityAgent)

3. **What hosts do I need to define?**
   - Laptop: All servers (dev, staging, prod, personal, etc.)
   - Remote: Only servers you connect to FROM here (usually just GitHub)

4. **Do I enable ForwardAgent?**
   - Laptop: Yes, for trusted work servers you connect TO
   - Remote: Usually no (you're already remote, no forwarding needed)

## Connection Multiplexing

**What:** Reuse SSH connections instead of establishing new ones.

**Benefits:**
- **Speed:** Subsequent connections are instant (< 1 second vs 2-5 seconds)
- **Efficiency:** Reduces authentication overhead
- **Better experience:** Makes git operations, scp, and terminal multitasking seamless

**Applies to:** Both laptop and remote server contexts

### How It Works

```
First Connection:
  laptop → [authentication] → server
           ↓
        (creates socket file in ~/.ssh/sockets/)

Subsequent Connections:
  laptop → [reuses socket] → server (instant!)
```

### Configuration

```ssh
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m
```

**Explanation:**
- `ControlMaster auto` - Automatically create/reuse connection sockets
- `ControlPath ~/.ssh/sockets/%C` - Socket location (%C = hash of connection params)
- `ControlPersist 10m` - Keep socket alive 10 minutes after last connection closes

### Testing Multiplexing

```bash
# First connection (normal)
time ssh myserver exit
# Example output: real 0m2.451s

# Second connection (reuses socket - instant!)
time ssh myserver exit
# Example output: real 0m0.234s

# Check active sockets
ls -l ~/.ssh/sockets/
```

### Socket Management

```bash
# Clear all sockets
ssh-clear  # Alias: rm -f ~/.ssh/sockets/*

# Close specific connection
ssh -O exit myserver

# Check connection status
ssh -O check myserver

# Force new connection (bypass multiplexing)
ssh -o ControlMaster=no myserver
```

## Connection Stability

**What:** Prevent SSH connections from timing out or dropping.

**Benefits:**
- No more "Connection closed by remote host" errors
- Maintain connections through idle periods
- Work reliably on flaky networks or through NAT/firewalls

**Applies to:** Both laptop and remote server contexts (especially important for remote servers)

### Configuration

```ssh
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

**Explanation:**
- `ServerAliveInterval 60` - Send keepalive packet every 60 seconds
- `ServerAliveCountMax 3` - Allow 3 missed responses before disconnecting (3 minutes total)
- `TCPKeepAlive yes` - Enable TCP-level keepalives (detects broken connections)

### How It Works

```
Timeline:
0:00 - Connection established
1:00 - Client sends ServerAlive packet → Server responds
2:00 - Client sends ServerAlive packet → Server responds
3:00 - Client sends ServerAlive packet → Server responds
...

If server stops responding:
1:00 - Missed response (count: 1)
2:00 - Missed response (count: 2)
3:00 - Missed response (count: 3) → Connection closed
```

### Tuning for Different Networks

**Stable network (office, home):**
```ssh
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

**Flaky network (mobile, coffee shop):**
```ssh
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 5
```

**Through aggressive NAT/firewall:**
```ssh
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 10
```

## SSH Agent Integration

**What:** Manage SSH keys in memory for passwordless authentication.

**Options:** Four approaches, choose based on your context and security needs.

### Option 1: Bitwarden SSH Agent (Laptop Only)

**Use case:** Laptop with Bitwarden desktop app running

**Benefits:**
- Keys stored encrypted in Bitwarden vault
- Unlock once, use everywhere
- No key files on disk
- Synced across devices

**Setup:**

1. **Enable in Bitwarden:**
   - Open Bitwarden → Settings → Preferences
   - Enable "SSH Agent" option

2. **Find your socket path:**
   ```bash
   # Snap install
   ls ~/.var/app/com.bitwarden.desktop/config/Bitwarden/.bitwarden-ssh-agent.sock

   # Deb/AppImage install
   ls ~/.config/Bitwarden/.bitwarden-ssh-agent.sock
   ```

3. **Configure SSH:**
   ```ssh
   Host *
       # Choose based on your Bitwarden install method
       IdentityAgent ~/.config/Bitwarden/.bitwarden-ssh-agent.sock
   ```

4. **Test:**
   ```bash
   ssh-add -l  # Should list keys from Bitwarden
   ssh github.com  # Should authenticate
   ```

**Important:** This is for LAPTOPS only. Remote servers should receive forwarded agents from laptops instead.

### Option 2: System SSH Agent (Both Contexts)

**Use case:** File-based keys, works on both laptop and remote server

**Benefits:**
- Simple, works everywhere
- Auto-starts on shell login
- Good for file-based keys
- No external dependencies

**Setup:**

Handled automatically by `~/.zshrc.local` (see `examples/zshrc.local.template`):

```bash
# Start SSH agent if not running
if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)" > /dev/null
fi

# Auto-add keys on first use
ssh-add -l &>/dev/null || ssh-add 2>/dev/null
```

**No SSH config needed** - agent socket set via `SSH_AUTH_SOCK` environment variable.

**Test:**
```bash
ssh-add -l  # List loaded keys
ssh-add ~/.ssh/id_ed25519  # Add specific key
ssh github.com  # Should authenticate
```

### Option 3: Forwarded Agent (Remote Server Context)

**Use case:** Remote server receiving forwarded agent from laptop

**Benefits:**
- Use laptop keys on remote server
- No keys stored on server
- Works for git signing on remote
- Automatic when laptop connects with ForwardAgent

**How it works:**

```
Laptop (Bitwarden agent):
  ├─ ssh-add -l → Lists Bitwarden keys
  └─ ssh -A dev → Connects with ForwardAgent

Remote Server (receives forwarded agent):
  ├─ echo $SSH_AUTH_SOCK → Shows forwarded socket
  ├─ ssh-add -l → Lists keys from laptop
  ├─ git commit -S → Uses laptop keys for signing
  └─ ssh github.com → Authenticates with laptop keys
```

**Setup:**

1. **Laptop SSH config:**
   ```ssh
   Host dev staging
       ForwardAgent yes
   ```

2. **Connect from laptop:**
   ```bash
   ssh dev
   ```

3. **Verify on remote server:**
   ```bash
   echo $SSH_AUTH_SOCK
   # Shows: /tmp/ssh-XXXXXX/agent.YYYY (forwarded socket)

   ssh-add -l
   # Lists keys from laptop
   ```

**No SSH config needed on remote server** - forwarded socket set automatically by sshd.

**Security note:** Only enable ForwardAgent for servers YOU control. See [Agent Forwarding Security](#agent-forwarding-security) below.

### Option 4: File-Based Keys (Both Contexts)

**Use case:** Traditional SSH keys on disk, fallback method

**Benefits:**
- Simple, no agent needed
- Works offline
- Full control

**Setup:**

1. **Generate key:**
   ```bash
   ssh-keygen -t ed25519 -C "your.email@example.com"
   ```

2. **Configure SSH (optional - SSH tries default paths automatically):**
   ```ssh
   Host *
       IdentityFile ~/.ssh/id_ed25519
       IdentityFile ~/.ssh/id_rsa
       IdentityFile ~/.ssh/company_key
   ```

3. **Add public key to remote servers:**
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server
   ```

**Default key paths** (tried automatically):
- `~/.ssh/id_ed25519`
- `~/.ssh/id_ecdsa`
- `~/.ssh/id_rsa`

### Comparison Table

| Method | Best For | Laptop | Remote | Keys on Disk | Auto-starts |
|--------|----------|--------|--------|--------------|-------------|
| Bitwarden | Laptop with Bitwarden | ✅ | ❌ | No | Yes |
| System Agent | File-based keys | ✅ | ✅ | Yes | Yes (zshrc) |
| Forwarded Agent | Remote server | ❌ | ✅ | No | Auto (laptop) |
| File Keys | Simple/fallback | ✅ | ✅ | Yes | No |

## Agent Forwarding

**What:** Allow remote servers to use your local SSH keys.

**Use case:** Laptop connects to remote server, which then uses laptop's keys for further authentication (git signing, connecting to other servers).

**⚠️ SECURITY WARNING:** Only enable for servers YOU control and trust completely!

### When to Use

**Good use cases:**
- ✅ Git commit signing on remote development servers
- ✅ Accessing internal servers from a bastion host
- ✅ Deploy scripts that need git authentication

**Bad use cases:**
- ❌ Shared servers (others could hijack your agent)
- ❌ Untrusted servers (malicious code could use your keys)
- ❌ Production servers (use deploy keys instead)

### Laptop Configuration (Enable Forwarding)

**Pattern 1: Trusted work servers**
```ssh
Host dev staging demo2
    ForwardAgent yes
```

**Pattern 2: Wildcard patterns**
```ssh
Host *.mycompany.com
    ForwardAgent yes

Host *.internal.corp
    ForwardAgent yes
```

**Pattern 3: Specific with full config**
```ssh
Host dev
    HostName ec2-xx-xx-xx-xx.compute-1.amazonaws.com
    User ubuntu
    ForwardAgent yes
    IdentityFile ~/.ssh/work_key
```

**Pattern 4: Conditional forwarding**
```ssh
# Only forward from specific laptop
Match host dev,staging exec "test $(hostname) = 'my-laptop'"
    ForwardAgent yes
```

### Remote Server Configuration (Receive Forwarding)

**No SSH client config needed!** The forwarded agent is set up automatically by sshd when you connect from laptop with ForwardAgent.

**Verify it's working:**
```bash
# On remote server after connecting from laptop
echo $SSH_AUTH_SOCK
# Shows: /tmp/ssh-XXXXXX/agent.YYYY (forwarded socket)

ssh-add -l
# Lists keys from laptop (not keys on server)

git commit -S -m "Test commit"
# Uses forwarded keys for signing
```

### Security Considerations

**1. Agent Hijacking Risk:**

If someone gains root on the server while you're connected, they can:
```bash
# Attacker (as root) can find your forwarded agent
ls -l /tmp/ssh-*/agent.*

# And use your keys
SSH_AUTH_SOCK=/tmp/ssh-XXXXXX/agent.YYYY ssh attacker-server
```

**2. Mitigation Strategies:**

**Use ProxyJump instead of ForwardAgent:**
```ssh
# Instead of:
# Host bastion
#     ForwardAgent yes
# Then ssh bastion → ssh internal

# Use ProxyJump:
Host internal
    HostName 10.0.1.50
    ProxyJump bastion
```

**Confirm before signing (requires OpenSSH 8.2+):**
```ssh
Host dev
    ForwardAgent yes
    AddKeysToAgent confirm
```

**Use dedicated keys for forwarding:**
```ssh
# Create server-specific key with limited scope
ssh-keygen -t ed25519 -f ~/.ssh/dev_forward_key

Host dev
    ForwardAgent yes
    IdentityFile ~/.ssh/dev_forward_key
```

**3. Server-Side Configuration:**

Remote servers can restrict agent forwarding in `/etc/ssh/sshd_config`:
```bash
# Allow forwarding (default)
AllowAgentForwarding yes

# Disable forwarding (more secure, but breaks git signing workflow)
AllowAgentForwarding no
```

### Chaining Connections

**Laptop → Server1 → Server2 with agent:**

```ssh
# Laptop config
Host server1
    ForwardAgent yes

Host server2
    ProxyJump server1
    ForwardAgent yes
```

**Test:**
```bash
# From laptop
ssh server1
ssh-add -l  # Shows laptop keys

# Then from server1
ssh server2
ssh-add -l  # Still shows laptop keys (forwarded through chain)
```

### Troubleshooting Agent Forwarding

**Agent not forwarded:**
```bash
# Check SSH_AUTH_SOCK on remote
echo $SSH_AUTH_SOCK
# Should show /tmp/ssh-*/agent.* (forwarded)
# If empty or shows local path, forwarding failed

# Test with verbose output
ssh -v dev 2>&1 | grep -i "agent"
# Look for "Requesting authentication agent forwarding"

# Check server sshd config
grep AllowAgentForwarding /etc/ssh/sshd_config
```

**Keys not accessible:**
```bash
# Verify keys on laptop
ssh-add -l  # Should list keys

# Connect with forwarding
ssh -A dev  # -A forces agent forwarding

# Verify on remote
ssh-add -l  # Should list same keys
```

## Host Patterns and Examples

### Laptop Examples (Hosts You Connect TO)

**Work infrastructure:**
```ssh
# Development server
Host dev
    HostName ec2-18-191-141-173.us-east-2.compute.amazonaws.com
    User ubuntu
    ForwardAgent yes
    IdentityFile ~/.ssh/work_key

# Staging environment
Host staging
    HostName ec2-3-16-84-205.us-east-2.compute.amazonaws.com
    User ubuntu
    ForwardAgent yes

# Production bastion (NO agent forwarding)
Host bastion
    HostName bastion.mycompany.com
    User myusername
    IdentityFile ~/.ssh/bastion_key
```

**Personal infrastructure:**
```ssh
# Personal VPS
Host vps
    HostName vps.example.com
    User root
    Port 2222  # Non-standard port
    IdentityFile ~/.ssh/personal_vps

# Home server (dynamic IP, via DynDNS)
Host homeserver
    HostName home.example.ddns.net
    User pi
    IdentityFile ~/.ssh/home_pi
```

**ProxyJump (bastion pattern):**
```ssh
# Define bastion
Host bastion
    HostName bastion.mycompany.com
    User myusername

# Internal servers via bastion (no ForwardAgent needed!)
Host internal-*
    ProxyJump bastion
    User admin

# Specific internal server
Host internal-db
    HostName 10.0.1.50
    ProxyJump bastion
    User postgres
```

**Wildcard patterns:**
```ssh
# All AWS EC2 instances
Host *.amazonaws.com
    User ubuntu
    IdentityFile ~/.ssh/aws_key

# All company servers
Host *.mycompany.com
    User myusername
    ForwardAgent yes
```

### Remote Server Examples (Hosts You Connect TO From Server)

**Minimal configuration (typical for remote servers):**
```ssh
# GitHub (most common)
Host github.com
    AddKeysToAgent yes
    StrictHostKeyChecking yes

# Another internal server
Host staging
    HostName ec2-3-16-84-205.us-east-2.compute.amazonaws.com
    User ubuntu

# Database server (internal IP)
Host db-primary
    HostName 10.0.1.100
    User postgres
```

**Key point:** Remote server configs are minimal because:
- You're already ON the dev server (no need to define "dev" host)
- You use forwarded agent from laptop (no need for Bitwarden)
- Usually only need GitHub and maybe other internal servers

### GitHub-Specific Optimizations

**Both laptop and remote server:**
```ssh
Host github.com
    # Auto-add key to agent on first use
    AddKeysToAgent yes

    # Strict host key checking (security)
    StrictHostKeyChecking yes

    # Use specific key (optional)
    IdentityFile ~/.ssh/github_ed25519

    # Connection multiplexing (faster git operations)
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m
```

**Test:**
```bash
# First operation (normal speed)
time git fetch

# Second operation (instant - reuses socket)
time git fetch
```

## Troubleshooting

### Connection Multiplexing Issues

**Symptom:** "ControlSocket already exists" or stale connections

**Solution:**
```bash
# Clear all sockets
ssh-clear

# Or manually
rm -f ~/.ssh/sockets/*

# Clear specific host
ssh -O exit hostname
```

**Symptom:** Connections hang or timeout

**Solution:**
```bash
# Bypass multiplexing
ssh -o ControlMaster=no hostname

# Check socket status
ssh -O check hostname

# Force kill socket
rm ~/.ssh/sockets/$(ssh -G hostname | grep controlpath | cut -d' ' -f2)
```

### Authentication Issues

**Symptom:** "Permission denied (publickey)"

**Debug steps:**
```bash
# Verbose output
ssh -vvv hostname 2>&1 | grep -E "Offering|Authenticating|debug1"

# Check which keys are tried
ssh -v hostname 2>&1 | grep "Offering public key"

# Test specific key
ssh -i ~/.ssh/specific_key hostname

# Check agent
ssh-add -l  # List loaded keys
ssh-add ~/.ssh/key  # Add key if missing
```

### Agent Forwarding Issues

**Symptom:** Agent not forwarded to remote server

**Debug steps:**
```bash
# From laptop
ssh -v hostname 2>&1 | grep -i "agent"
# Look for: "Requesting authentication agent forwarding"

# On remote server
echo $SSH_AUTH_SOCK
# Should show /tmp/ssh-*/agent.* (not empty)

# Check server allows forwarding
grep AllowAgentForwarding /etc/ssh/sshd_config

# Force forwarding
ssh -A hostname
```

**Symptom:** Keys not accessible on remote server

```bash
# On remote server
ssh-add -l
# Should list keys from laptop

# If empty, check laptop agent
# On laptop
ssh-add -l

# Reconnect with verbose
ssh -A -v hostname 2>&1 | grep -i "agent"
```

### Bitwarden SSH Agent Issues

**Symptom:** "Could not open a connection to your authentication agent"

**Debug steps:**
```bash
# Check socket exists
ls -l ~/.config/Bitwarden/.bitwarden-ssh-agent.sock
# Or for snap: ~/.var/app/com.bitwarden.desktop/config/Bitwarden/

# Check Bitwarden running
ps aux | grep -i bitwarden

# Check SSH agent enabled in Bitwarden
# Open Bitwarden → Settings → Preferences → SSH Agent (should be checked)

# Test socket directly
SSH_AUTH_SOCK=~/.config/Bitwarden/.bitwarden-ssh-agent.sock ssh-add -l
```

**Symptom:** Wrong socket path

```bash
# Find your Bitwarden socket
find ~ -name ".bitwarden-ssh-agent.sock" 2>/dev/null

# Common paths:
ls ~/.config/Bitwarden/.bitwarden-ssh-agent.sock  # Deb/AppImage
ls ~/.var/app/com.bitwarden.desktop/config/Bitwarden/.bitwarden-ssh-agent.sock  # Snap/Flatpak
```

### Connection Stability Issues

**Symptom:** "Connection closed by remote host" after idle

**Solution:**
```ssh
# More aggressive keepalive
Host problematic-host
    ServerAliveInterval 30
    ServerAliveCountMax 5
```

**Symptom:** Connection hangs on network change (laptop sleep/wake)

**Solution:**
```bash
# Clear stale sockets
ssh-clear

# Reconnect
ssh hostname
```

### Configuration Testing

**Check effective config for host:**
```bash
ssh -G hostname
# Shows all settings that will be used
```

**Test config syntax:**
```bash
# SSH config has no syntax check, but you can test connection
ssh -v hostname 2>&1 | grep "Reading configuration"
```

**Check which config files are loaded:**
```bash
ssh -v hostname 2>&1 | grep "configuration"
```

## Advanced Topics

### Modular Configuration (Include Directive)

Split config into multiple files for better organization:

**Main config (`~/.ssh/config`):**
```ssh
# Universal defaults
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m

# Include other configs
Include ~/.ssh/config.d/*.conf
```

**Work servers (`~/.ssh/config.d/work.conf`):**
```ssh
Host dev staging prod
    ForwardAgent yes
    User ubuntu
    IdentityFile ~/.ssh/work_key

Host dev
    HostName ec2-xx-xx-xx-xx.amazonaws.com
```

**Personal servers (`~/.ssh/config.d/personal.conf`):**
```ssh
Host vps homeserver
    User root
    IdentityFile ~/.ssh/personal_key

Host vps
    HostName vps.example.com
```

**GitHub (`~/.ssh/config.d/github.conf`):**
```ssh
Host github.com
    AddKeysToAgent yes
    IdentityFile ~/.ssh/github_ed25519
```

**Setup:**
```bash
mkdir -p ~/.ssh/config.d
chmod 700 ~/.ssh/config.d
```

### Match Directives (Conditional Config)

Apply configuration based on conditions:

**Forward agent only from specific laptop:**
```ssh
Match host dev,staging exec "test $(hostname) = 'my-laptop'"
    ForwardAgent yes
```

**Use different keys based on user:**
```ssh
Match user work-account
    IdentityFile ~/.ssh/work_key

Match user personal
    IdentityFile ~/.ssh/personal_key
```

**Different config based on network:**
```ssh
Match host * exec "ping -c1 -W1 internal.corp > /dev/null 2>&1"
    ProxyJump none

Match host * exec "! ping -c1 -W1 internal.corp > /dev/null 2>&1"
    ProxyJump bastion
```

### Per-Host Overrides

**Disable multiplexing for problematic host:**
```ssh
Host legacy-server
    HostName legacy.example.com
    ControlMaster no
    ControlPath none
```

**More aggressive keepalive for flaky connection:**
```ssh
Host flaky-vpn
    HostName vpn.example.com
    ServerAliveInterval 15
    ServerAliveCountMax 10
```

**Different agent for specific host:**
```ssh
Host client-server
    HostName client.example.com
    IdentityAgent ~/.ssh/client_agent.sock
```

### Port Forwarding

**Local port forward (remote service → local port):**
```ssh
# Access remote database locally
Host db-tunnel
    HostName db-server.internal
    LocalForward 5432 localhost:5432
```

```bash
ssh -N db-tunnel  # -N: no remote command
psql -h localhost -p 5432  # Connects to remote DB
```

**Remote port forward (local service → remote port):**
```ssh
Host dev-tunnel
    HostName dev-server.com
    RemoteForward 8080 localhost:3000
```

```bash
# Run local app on :3000
npm start

# SSH to server (keeps tunnel open)
ssh dev-tunnel

# On server, access via localhost:8080
curl http://localhost:8080
```

**Dynamic SOCKS proxy:**
```ssh
Host socks-proxy
    HostName proxy-server.com
    DynamicForward 1080
```

```bash
ssh -N socks-proxy

# Configure browser to use SOCKS5 proxy localhost:1080
```

### Performance Tuning

**Compression (helps over slow connections):**
```ssh
Host slow-connection
    Compression yes
    CompressionLevel 6  # 1-9, higher = more compression
```

**Disable compression (faster on fast networks):**
```ssh
Host fast-connection
    Compression no
```

**Multiplexing connection sharing:**
```ssh
# Share all connections
Host *
    ControlMaster auto

# Never create master (always share)
Host frequent-host
    ControlMaster no
```

**Cipher selection (security vs speed trade-off):**
```ssh
# Faster ciphers (less secure)
Host fast-internal
    Ciphers aes128-gcm@openssh.com

# Most secure ciphers (slower)
Host sensitive-host
    Ciphers chacha20-poly1305@openssh.com
```

### Security Hardening

**Strict host key checking:**
```ssh
Host *
    StrictHostKeyChecking ask  # Prompt on first connection (default)

Host production-*
    StrictHostKeyChecking yes  # Reject unknown hosts

Host lab-*
    StrictHostKeyChecking no  # Accept any (insecure, lab only!)
```

**Disable potentially risky features:**
```ssh
Host untrusted
    ForwardAgent no
    ForwardX11 no
    PermitLocalCommand no
```

**Use specific key algorithms:**
```ssh
Host secure-host
    HostKeyAlgorithms ssh-ed25519
    PubkeyAcceptedKeyTypes ssh-ed25519
```

**Connection timeout:**
```ssh
Host *
    ConnectTimeout 30  # 30 seconds max for connection
```

## Summary

**Essential settings (enable for everyone):**
```ssh
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%C
    ControlPersist 10m
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

**Laptop additions:**
```ssh
Host *
    IdentityAgent ~/.config/Bitwarden/.bitwarden-ssh-agent.sock

Host dev staging trusted-servers
    ForwardAgent yes
```

**Remote server - keep minimal:**
```ssh
Host github.com
    AddKeysToAgent yes
```

**Commands to remember:**
```bash
ssh-init        # Copy template
ssh-clear       # Clear sockets
ssh -vvv host   # Debug connection
ssh -G host     # Show effective config
```

**Further reading:**
- `man ssh_config` - Complete SSH client configuration reference
- [SSH Signing Setup](SSH_SIGNING_SETUP.md) - Git commit signing with SSH keys
- [examples/zshrc.local.template](../examples/zshrc.local.template) - SSH agent auto-start
