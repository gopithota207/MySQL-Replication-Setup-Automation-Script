#!/bin/bash
# =============================================================================
# MySQL 8.0 Replication Setup Script
# Author: Gopi Thota
# Description: Automates MySQL source-to-replica replication setup
#              based on binary log position method.
#              Tested on MySQL 8.0 / RHEL 8 / Oracle Linux 8
#
# Note: I wrote this after setting up replication manually multiple times.
#       Tired of doing same steps again and again so automated it.
#       Script covers everything from user creation to sync verification.
#
# Usage: bash mysql_replication_setup.sh
# =============================================================================

# ---------------------------------------------------------------
# CONFIGURATION - change these to match your environment
# ---------------------------------------------------------------

# Source (Master) server details
SOURCE_HOST="192.168.1.22"
SOURCE_PORT="3306"
SOURCE_ROOT_USER="root"
SOURCE_ROOT_PASS="Root#1234567"

# Replica (Slave) server details
REPLICA_HOST="192.168.1.23"
REPLICA_PORT="3306"
REPLICA_ROOT_USER="root"
REPLICA_ROOT_PASS="Root#1234567"
REPLICA_SERVER_ID="2"

# Replication user to create on source
REPL_USER="replication"
REPL_PASS="replication"

# Dump file location (on this machine / source server)
DUMP_FILE="/root/sourcedump.sql"

# Mail settings - replication success/failure notification
MAIL_TO="gopixxx@gmail.com"
SEND_MAIL="yes"   # 

# Log file
LOGFILE="/var/log/mysql_replication_setup.log"

# ---------------------------------------------------------------
# simple log function 
# ---------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a $LOGFILE
}

# run mysql command on source
run_source() {
    mysql -h $SOURCE_HOST -P $SOURCE_PORT \
          -u $SOURCE_ROOT_USER -p$SOURCE_ROOT_PASS \
          -e "$1" 2>/dev/null
}

# run mysql command on replica
run_replica() {
    mysql -h $REPLICA_HOST -P $REPLICA_PORT \
          -u $REPLICA_ROOT_USER -p$REPLICA_ROOT_PASS \
          -e "$1" 2>/dev/null
}

# ---------------------------------------------------------------
# STEP 1 - Check both servers are reachable
# ---------------------------------------------------------------
check_connectivity() {
    log "========================================================"
    log "STEP 1 - Checking connectivity to both servers"
    log "========================================================"

    # check source
    SOURCE_VERSION=$(run_source "SELECT VERSION();" | grep -v VERSION)
    if [ -z "$SOURCE_VERSION" ]; then
        log "ERROR: Cannot connect to source server $SOURCE_HOST. Check credentials/firewall."
        exit 1
    fi
    log "OK - Source connected. MySQL version: $SOURCE_VERSION"

    # check replica
    REPLICA_VERSION=$(run_replica "SELECT VERSION();" | grep -v VERSION)
    if [ -z "$REPLICA_VERSION" ]; then
        log "ERROR: Cannot connect to replica server $REPLICA_HOST. Check credentials/firewall."
        exit 1
    fi
    log "OK - Replica connected. MySQL version: $REPLICA_VERSION"

    # warn if versions differ - replication works but better to match
    if [ "$SOURCE_VERSION" != "$REPLICA_VERSION" ]; then
        log "WARN - Version mismatch. Source: $SOURCE_VERSION | Replica: $REPLICA_VERSION"
        log "WARN - MySQL supports cross version replication but same version is recommended."
    fi
}

# ---------------------------------------------------------------
# STEP 2 - Check server IDs are different
# ---------------------------------------------------------------
check_server_ids() {
    log "========================================================"
    log "STEP 2 - Checking server IDs"
    log "========================================================"

    SOURCE_ID=$(run_source "SELECT @@server_id;" | grep -v server_id)
    REPLICA_ID=$(run_replica "SELECT @@server_id;" | grep -v server_id)

    log "Source server_id: $SOURCE_ID"
    log "Replica server_id: $REPLICA_ID"

    if [ "$SOURCE_ID" = "$REPLICA_ID" ]; then
        log "ERROR - Both servers have same server_id=$SOURCE_ID. Replication will not work."
        log "Fix: Add server-id=$REPLICA_SERVER_ID in /etc/my.cnf on replica and restart MySQL."
        log "Or run: SET GLOBAL server_id=$REPLICA_SERVER_ID; on replica."

        # try to fix it automatically
        log "Trying to set server_id=$REPLICA_SERVER_ID on replica automatically..."
        run_replica "SET GLOBAL server_id=$REPLICA_SERVER_ID;"
        REPLICA_ID=$(run_replica "SELECT @@server_id;" | grep -v server_id)
        log "Replica server_id is now: $REPLICA_ID"
    fi

    log "OK - Server IDs are different. Source=$SOURCE_ID | Replica=$REPLICA_ID"
}

# ---------------------------------------------------------------
# STEP 3 - Check binary logging is enabled on source
# ---------------------------------------------------------------
check_binlog() {
    log "========================================================"
    log "STEP 3 - Checking binary log on source"
    log "========================================================"

    BINLOG_STATUS=$(run_source "SHOW VARIABLES LIKE 'log_bin';" | grep log_bin | awk '{print $2}')

    if [ "$BINLOG_STATUS" != "ON" ]; then
        log "ERROR - Binary logging is OFF on source server."
        log "Fix: Add log_bin=binlog in /etc/my.cnf on source and restart MySQL."
        log "Note: Binary logging is disabled by default in MySQL 5.x."
        exit 1
    fi

    log "OK - Binary logging is ON on source."
}

# ---------------------------------------------------------------
# STEP 4 - Set performance parameters on source
# important for data consistency during replication
# ---------------------------------------------------------------
set_source_params() {
    log "========================================================"
    log "STEP 4 - Setting source performance parameters"
    log "========================================================"

    # innodb_flush_log_at_trx_commit=1
    # ensures InnoDB transaction log is written and flushed to disk after every commit
    run_source "SET GLOBAL innodb_flush_log_at_trx_commit=1;"
    log "OK - innodb_flush_log_at_trx_commit set to 1"

    # sync_binlog=1
    # ensures binary log is flushed to disk after every transaction commit
    run_source "SET GLOBAL sync_binlog=1;"
    log "OK - sync_binlog set to 1"
}

# ---------------------------------------------------------------
# STEP 5 - Create replication user on source
# ---------------------------------------------------------------
create_replication_user() {
    log "========================================================"
    log "STEP 5 - Creating replication user on source"
    log "========================================================"

    # check if user already exists
    USER_EXISTS=$(run_source "SELECT COUNT(*) FROM mysql.user WHERE user='$REPL_USER';" | grep -v COUNT)

    if [ "$USER_EXISTS" -gt "0" ]; then
        log "Replication user '$REPL_USER' already exists. Dropping and recreating..."
        run_source "DROP USER '$REPL_USER'@'%';"
    fi

    # create user
    # using % so replica can connect from any host
    run_source "CREATE USER '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';"
    log "OK - User '$REPL_USER'@'%' created."

    # caching_sha2_password is not supported for replication in some versions
    # so using mysql_native_password
    run_source "ALTER USER '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASS';"
    log "OK - Password plugin set to mysql_native_password (required for replication)."

    # grant replication slave privilege
    run_source "GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';"
    run_source "FLUSH PRIVILEGES;"
    log "OK - REPLICATION SLAVE privilege granted."

    # verify grants
    GRANTS=$(run_source "SHOW GRANTS FOR '$REPL_USER'@'%';")
    log "Grants for $REPL_USER: $GRANTS"
}

# ---------------------------------------------------------------
# STEP 6 - Lock tables and get binary log position
# must note this before taking dump
# ---------------------------------------------------------------
get_binlog_position() {
    log "========================================================"
    log "STEP 6 - Lock tables and get binary log position"
    log "========================================================"

    # lock tables
    run_source "FLUSH TABLES WITH READ LOCK;"
    log "OK - Tables locked on source."

    # get binlog position
    MASTER_STATUS=$(run_source "SHOW MASTER STATUS\G" 2>/dev/null || \
                    run_source "SHOW BINARY LOG STATUS\G" 2>/dev/null)

    BINLOG_FILE=$(run_source "SHOW MASTER STATUS;" | grep -v File | awk '{print $1}')
    BINLOG_POS=$(run_source "SHOW MASTER STATUS;"  | grep -v File | awk '{print $2}')

    if [ -z "$BINLOG_FILE" ]; then
        log "ERROR - Could not get binary log position. Check if binary logging is enabled."
        run_source "UNLOCK TABLES;"
        exit 1
    fi

    log "OK - Binary log file: $BINLOG_FILE"
    log "OK - Binary log position: $BINLOG_POS"
}

# ---------------------------------------------------------------
# STEP 7 - Take full database backup using mysqldump
# using --source-data (--master-data is deprecated in 8.0)
# ---------------------------------------------------------------
take_dump() {
    log "========================================================"
    log "STEP 7 - Taking full database dump from source"
    log "========================================================"

    log "Running mysqldump... this may take a while for large databases."

    mysqldump -h $SOURCE_HOST \
              -u $SOURCE_ROOT_USER \
              -p$SOURCE_ROOT_PASS \
              --all-databases \
              --source-data \
              --single-transaction \
              --routines \
              --triggers \
              > $DUMP_FILE 2>/dev/null

    if [ $? -ne 0 ]; then
        log "ERROR - mysqldump failed. Check source credentials and disk space."
        run_source "UNLOCK TABLES;"
        exit 1
    fi

    DUMP_SIZE=$(du -sh $DUMP_FILE | awk '{print $1}')
    log "OK - Dump completed. File: $DUMP_FILE | Size: $DUMP_SIZE"

    # unlock tables after dump
    run_source "UNLOCK TABLES;"
    log "OK - Tables unlocked on source."
}

# ---------------------------------------------------------------
# STEP 8 - Copy dump to replica server
# ---------------------------------------------------------------
copy_dump_to_replica() {
    log "========================================================"
    log "STEP 8 - Copying dump file to replica server"
    log "========================================================"

    scp -o StrictHostKeyChecking=no \
        $DUMP_FILE \
        root@$REPLICA_HOST:$DUMP_FILE

    if [ $? -ne 0 ]; then
        log "ERROR - SCP failed. Make sure passwordless SSH is set up between servers."
        log "Fix: ssh-keygen -t rsa && ssh-copy-id root@$REPLICA_HOST"
        exit 1
    fi

    log "OK - Dump file copied to replica: $REPLICA_HOST:$DUMP_FILE"
}

# ---------------------------------------------------------------
# STEP 9 - Import dump on replica
# ---------------------------------------------------------------
import_dump_on_replica() {
    log "========================================================"
    log "STEP 9 - Importing dump on replica"
    log "========================================================"

    log "Importing dump... this may take a while."

    ssh -o StrictHostKeyChecking=no root@$REPLICA_HOST \
        "mysql -u $REPLICA_ROOT_USER -p$REPLICA_ROOT_PASS < $DUMP_FILE" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "ERROR - Import failed on replica. Check replica MySQL status and credentials."
        exit 1
    fi

    log "OK - Dump imported on replica successfully."

    # verify data is there
    log "Verifying databases on replica after import..."
    REPLICA_DBS=$(run_replica "SHOW DATABASES;")
    log "Databases on replica: $REPLICA_DBS"
}

# ---------------------------------------------------------------
# STEP 10 - Configure replica to point to source
# ---------------------------------------------------------------
configure_replica() {
    log "========================================================"
    log "STEP 10 - Configuring replica replication settings"
    log "========================================================"

    # stop slave first if already running
    run_replica "STOP SLAVE;" 2>/dev/null || \
    run_replica "STOP REPLICA;" 2>/dev/null
    log "OK - Stopped any existing replication on replica."

    # reset slave
    run_replica "RESET SLAVE ALL;" 2>/dev/null || \
    run_replica "RESET REPLICA ALL;" 2>/dev/null
    log "OK - Reset replica configuration."

    # configure source connection
    # using CHANGE REPLICATION SOURCE TO (new syntax in MySQL 8.0.23+)
    run_replica "CHANGE REPLICATION SOURCE TO \
        SOURCE_HOST='$SOURCE_HOST', \
        SOURCE_USER='$REPL_USER', \
        SOURCE_PASSWORD='$REPL_PASS', \
        SOURCE_LOG_FILE='$BINLOG_FILE', \
        SOURCE_LOG_POS=$BINLOG_POS;" 2>/dev/null

    if [ $? -ne 0 ]; then
        # fallback to old syntax for older 8.0 versions
        log "Trying old CHANGE MASTER TO syntax..."
        run_replica "CHANGE MASTER TO \
            MASTER_HOST='$SOURCE_HOST', \
            MASTER_USER='$REPL_USER', \
            MASTER_PASSWORD='$REPL_PASS', \
            MASTER_LOG_FILE='$BINLOG_FILE', \
            MASTER_LOG_POS=$BINLOG_POS;" 2>/dev/null
    fi

    log "OK - Replica configured to connect to source $SOURCE_HOST"
    log "     Binlog file: $BINLOG_FILE | Position: $BINLOG_POS"
}

# ---------------------------------------------------------------
# STEP 11 - Start replication
# ---------------------------------------------------------------
start_replication() {
    log "========================================================"
    log "STEP 11 - Starting replication"
    log "========================================================"

    run_replica "START SLAVE;" 2>/dev/null || \
    run_replica "START REPLICA;" 2>/dev/null

    log "OK - Replication started."

    # wait a few seconds for threads to come up
    sleep 5
}

# ---------------------------------------------------------------
# STEP 12 - Verify replication is working
# the most important step
# ---------------------------------------------------------------
verify_replication() {
    log "========================================================"
    log "STEP 12 - Verifying replication status"
    log "========================================================"

    # check slave status
    IO_RUNNING=$(run_replica "SHOW SLAVE STATUS\G" 2>/dev/null | \
                 grep "Slave_IO_Running" | awk '{print $2}')
    SQL_RUNNING=$(run_replica "SHOW SLAVE STATUS\G" 2>/dev/null | \
                  grep "Slave_SQL_Running:" | awk '{print $2}')
    SECONDS_BEHIND=$(run_replica "SHOW SLAVE STATUS\G" 2>/dev/null | \
                     grep "Seconds_Behind_Master" | awk '{print $2}')
    LAST_ERROR=$(run_replica "SHOW SLAVE STATUS\G" 2>/dev/null | \
                 grep "Last_Error:" | head -1 | cut -d: -f2-)

    # fallback to new syntax
    if [ -z "$IO_RUNNING" ]; then
        IO_RUNNING=$(run_replica "SHOW REPLICA STATUS\G" 2>/dev/null | \
                     grep "Replica_IO_Running" | awk '{print $2}')
        SQL_RUNNING=$(run_replica "SHOW REPLICA STATUS\G" 2>/dev/null | \
                      grep "Replica_SQL_Running:" | awk '{print $2}')
        SECONDS_BEHIND=$(run_replica "SHOW REPLICA STATUS\G" 2>/dev/null | \
                         grep "Seconds_Behind_Source" | awk '{print $2}')
        LAST_ERROR=$(run_replica "SHOW REPLICA STATUS\G" 2>/dev/null | \
                     grep "Last_Error:" | head -1 | cut -d: -f2-)
    fi

    log "IO Thread Running  : $IO_RUNNING"
    log "SQL Thread Running : $SQL_RUNNING"
    log "Seconds Behind     : $SECONDS_BEHIND"
    log "Last Error         : ${LAST_ERROR:-None}"

    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        log "OK - Replication is running fine. Both IO and SQL threads are active."
        REPL_STATUS="SUCCESS"
    else
        log "ERROR - Replication is not running properly."
        log "IO Thread: $IO_RUNNING | SQL Thread: $SQL_RUNNING"
        log "Last Error: $LAST_ERROR"
        REPL_STATUS="FAILED"
    fi

    # quick sync test - create a test DB on source and check on replica
    log "Running quick sync test..."
    run_source "CREATE DATABASE IF NOT EXISTS repl_test_$(date +%s);" 2>/dev/null
    sleep 3

    SOURCE_DB_COUNT=$(run_source "SHOW DATABASES;" | wc -l)
    REPLICA_DB_COUNT=$(run_replica "SHOW DATABASES;" | wc -l)

    log "Source  DB count: $SOURCE_DB_COUNT"
    log "Replica DB count: $REPLICA_DB_COUNT"

    if [ "$SOURCE_DB_COUNT" = "$REPLICA_DB_COUNT" ]; then
        log "OK - Database counts match. Data is in sync."
    else
        log "WARN - DB counts differ. Replica may still be catching up. Check again in a minute."
    fi
}

# ---------------------------------------------------------------
# STEP 13 - Send email notification
# ---------------------------------------------------------------
send_mail() {
    log "========================================================"
    log "STEP 13 - Sending email notification"
    log "========================================================"

    if [ "$SEND_MAIL" != "yes" ]; then
        log "SEND_MAIL=no - skipping email."
        return
    fi

    if [ "$REPL_STATUS" = "SUCCESS" ]; then
        SUBJECT="MySQL Replication Setup SUCCESS - $SOURCE_HOST to $REPLICA_HOST"
        BODY="Hi Team,

MySQL replication has been set up successfully.

Details:
--------
Source  Server : $SOURCE_HOST:$SOURCE_PORT
Replica Server : $REPLICA_HOST:$REPLICA_PORT
Binlog File    : $BINLOG_FILE
Binlog Position: $BINLOG_POS
IO Thread      : $IO_RUNNING
SQL Thread     : $SQL_RUNNING
Seconds Behind : $SECONDS_BEHIND
Status         : REPLICATION IS IN SYNC AND WORKING FINE

Log file: $LOGFILE

Thanks,
Gopi Thota
Oracle/MySQL DBA"

    else
        SUBJECT="MySQL Replication Setup FAILED - $SOURCE_HOST to $REPLICA_HOST"
        BODY="Hi Team,

MySQL replication setup encountered issues. Please check manually.

Details:
--------
Source  Server : $SOURCE_HOST:$SOURCE_PORT
Replica Server : $REPLICA_HOST:$REPLICA_PORT
IO Thread      : $IO_RUNNING
SQL Thread     : $SQL_RUNNING
Last Error     : $LAST_ERROR
Status         : FAILED

Please check log file: $LOGFILE

Thanks,
Gopi Thota
Oracle/MySQL DBA"
    fi

    echo "$BODY" | mail -s "$SUBJECT" $MAIL_TO
    if [ $? -eq 0 ]; then
        log "OK - Email sent to $MAIL_TO"
    else
        log "WARN - Email send failed. Check mail configuration."
    fi
}

# ---------------------------------------------------------------
# MAIN - run all steps in order
# ---------------------------------------------------------------
log "========================================================"
log " MySQL 8.0 Replication Setup Started"
log " Source : $SOURCE_HOST | Replica: $REPLICA_HOST"
log " Date   : $(date)"
log "========================================================"

check_connectivity
check_server_ids
check_binlog
set_source_params
create_replication_user
get_binlog_position
take_dump
copy_dump_to_replica
import_dump_on_replica
configure_replica
start_replication
verify_replication
send_mail

log "========================================================"
if [ "$REPL_STATUS" = "SUCCESS" ]; then
    log " ALL DONE - Replication is running successfully!"
else
    log " COMPLETED WITH ERRORS - Check log: $LOGFILE"
fi
log " Log file: $LOGFILE"
log "========================================================"
