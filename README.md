# SSH server setup

`enable-root-ssh.sh` enables root login and password authentication for OpenSSH on common Ubuntu and Debian servers.

> [!WARNING]
> Enabling root password login increases the risk of brute-force attacks and account compromise. Restrict SSH access with a firewall or trusted source IPs, use a strong password, and disable root/password login when it is no longer required.

## What the script does

- Requires root privileges, or automatically re-runs itself with `sudo`.
- Creates and verifies a timestamped backup under `/etc/ssh/` before changing anything.
- Sets the effective global SSH values to:

  ```text
  PermitRootLogin yes
  PasswordAuthentication yes
  ```

- Neutralizes active `PermitRootLogin` and `PasswordAuthentication` directives in `/etc/ssh/sshd_config.d/*.conf` so they cannot override the requested values.
- Runs `sshd -t` and checks the effective configuration with `sshd -T`.
- Restores every modified file and does **not** restart SSH if validation fails.
- Restarts the `ssh` or `sshd` service only after validation succeeds.
- Does not set or store any password and never reboots the server.

For safety, the script refuses to modify symlinked SSH configuration files.

## Run directly on a new server

```bash
curl -fsSL "https://raw.githubusercontent.com/ss97979997-droid/ssh-server-setup/main/enable-root-ssh.sh" -o /tmp/enable-root-ssh.sh && sudo bash /tmp/enable-root-ssh.sh
```

## Download, inspect, and run

```bash
curl -fsSL "https://raw.githubusercontent.com/ss97979997-droid/ssh-server-setup/main/enable-root-ssh.sh" -o /tmp/enable-root-ssh.sh
less /tmp/enable-root-ssh.sh
sudo bash /tmp/enable-root-ssh.sh
```

After the script succeeds, set the root password yourself:

```bash
sudo passwd root
```

The script prints the verified backup directory. Keep that path if you may need to restore the previous SSH configuration later.

## Compatibility

Designed for common OpenSSH installations on Ubuntu, Debian, and similar Linux distributions using either `systemctl` or the `service` command.
