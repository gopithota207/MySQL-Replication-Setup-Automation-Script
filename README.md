Here’s a clean GitHub-style README you can use for your repository.

# MySQL 8 GTID Replication Automation

A simple shell script to automate MySQL 8 source-to-replica replication setup using GTID replication.

This script was created after repeatedly performing manual replication setups in multiple environments.
The goal is to reduce manual effort, avoid common mistakes, and speed up MySQL replication deployments.

---

# Features

* MySQL 8 GTID-based replication
* Automated replication user creation
* Full database backup using `mysqldump`
* Automatic backup transfer to replica
* Replica import automation
* Replication configuration using `CHANGE REPLICATION SOURCE TO`
* Replication health verification
* Sync test validation
* Logging support
* Email notification support
* Designed for RHEL / Oracle Linux environments

---

# Environment Tested

* MySQL 8.0
* RHEL 8
* Oracle Linux 8

---

# Prerequisites

Before running the script, ensure the following:

## 1. GTID must be enabled

### Source Server

Add the following in `/etc/my.cnf`

```ini id="ut26vq"
[mysqld]

server-id=1

log_bin=mysql-bin
binlog_format=ROW

gtid_mode=ON
enforce_gtid_consistency=ON

log_slave_updates=ON
```

### Replica Server

```ini id="8k7z4j"
[mysqld]

server-id=2

relay_log=relay-bin

read_only=ON
super_read_only=ON

gtid_mode=ON
enforce_gtid_consistency=ON

log_slave_updates=ON
```

Restart MySQL after configuration changes.

---

# 2. Configure MySQL Login Path

## Source

```bash id="al0qz4"
mysql_config_editor set \
--login-path=source \
--host=192.168.1.22 \
--user=root \
--password
```

## Replica

```bash id="1jlwm0"
mysql_config_editor set \
--login-path=replica \
--host=192.168.1.23 \
--user=root \
--password
```

---

# 3. Configure Passwordless SSH

From source server:

```bash id="4wv4j9"
ssh-keygen
ssh-copy-id root@REPLICA_IP
```

Test SSH:

```bash id="m61jlwm"
ssh root@REPLICA_IP hostname
```

---

# Installation

Clone the repository:

```bash id="pd2r6u"
git clone https://github.com/yourusername/mysql-replication-automation.git
```

Go to project directory:

```bash id="t90z6q"
cd mysql-replication-automation
```

Make script executable:

```bash id="6yx63m"
chmod +x mysql_replication_setup.sh
```

---

# Configuration

Edit the script and update the following variables:

```bash id="jlwm0k"
SOURCE_HOST=""
REPLICA_HOST=""

SOURCE_LOGIN_PATH="source"
REPLICA_LOGIN_PATH="replica"

REPL_USER=""
REPL_PASS=""

MAIL_TO=""
```

---

# Usage

Run the script:

```bash id="m6e1gx"
./mysql_replication_setup.sh
```

---

# What the Script Does

The script performs the following steps automatically:

1. Checks MySQL connectivity
2. Validates GTID configuration
3. Validates `server_id`
4. Creates replication user
5. Takes full backup from source
6. Copies backup to replica
7. Imports backup on replica
8. Configures replication
9. Starts replication
10. Verifies replication health
11. Runs sync validation test
12. Sends email notification

---

# Replication Verification

The script validates:

* Replica IO thread status
* Replica SQL thread status
* Replication lag
* Last replication error
* Sync test database creation

---

# Logs

Log file location:

```bash id="g8jx8v"
/var/log/mysql_replication_setup.log
```

---

# Notes

* This script is intended mainly for:

  * Development
  * UAT
  * Small/Medium production environments
  * Lab setups

* For very large databases, consider:

  * Percona XtraBackup
  * MySQL Enterprise Backup
  * Storage snapshots
  * MySQL Clone Plugin

---

# Warning

The script executes:

```sql id="vjlwm0"
RESET REPLICA ALL;
```

This removes existing replication configuration on the replica server.

Use carefully in production environments.

---

# Future Improvements

* Parallel backup support
* Incremental backup support
* Multi-source replication
* Automatic failover integration
* Slack/Teams alert integration
* Percona XtraBackup support

---

# License

This project is licensed under the MIT License.
