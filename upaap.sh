#!/bin/bash

# Ensure the script is being run with sudo privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# Prompt for user inputs
read -p "Enter the custom myhostname (e.g., mail.yourdomain.com): " myhostname
myhostname=${myhostname:-localhost}

read -p "Enter the sender email address (e.g., no-reply@yourdomain.com): " sender_email
read -p "Enter the sender name (e.g., Support Team): " sender_name
read -p "Enter the email subject: " email_subject
read -p "Enter the path to your email list file (e.g., germany.txt): " email_list

# Ensure email list file exists
if [ ! -f "$email_list" ]; then
  echo "ERROR: Email list file '$email_list' not found!"
  exit 1
fi

# Update package list and install required tools
echo "[+] Updating packages and installing Postfix, OpenDKIM, and dependencies..."
sudo apt-get update -y
sudo apt-get install -y postfix opendkim opendkim-tools tmux mailutils

# Configure Postfix with DKIM, SPF, and TLS
echo "[+] Configuring Postfix for better email authentication..."

# Backup the original Postfix config file
sudo cp /etc/postfix/main.cf /etc/postfix/main.cf.backup

# Generate DKIM keys (2048-bit for security)
echo "[+] Generating DKIM keys..."
sudo mkdir -p /etc/opendkim/keys/$myhostname
sudo opendkim-genkey -b 2048 -d $myhostname -D /etc/opendkim/keys/$myhostname -s default -v
sudo chown -R opendkim:opendkim /etc/opendkim/keys/$myhostname

# Configure OpenDKIM
echo "[+] Configuring OpenDKIM..."
sudo tee /etc/opendkim.conf > /dev/null <<EOL
# OpenDKIM configuration
Domain                  $myhostname
KeyFile                 /etc/opendkim/keys/$myhostname/default.private
Selector                default
Socket                  inet:8891@localhost
UserID                  opendkim
UMask                   022
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1M
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
EOL

# Configure Postfix to use DKIM
echo "[+] Updating Postfix to use DKIM..."
sudo tee /etc/postfix/main.cf > /dev/null <<EOL
# Postfix main configuration
myhostname = $myhostname
inet_interfaces = loopback-only
relayhost = 
mydestination = localhost

# DKIM integration
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891

# Enable TLS for secure email
smtp_tls_security_level = may
smtpd_tls_security_level = may
smtp_tls_loglevel = 1
smtpd_tls_loglevel = 1
smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem
smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key

# Rate limiting to prevent abuse
smtpd_client_message_rate_limit = 100
anvil_rate_time_unit = 60s
smtpd_error_sleep_time = 1s
smtpd_soft_error_limit = 10
smtpd_hard_error_limit = 20

# Basic Postfix settings
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
mailbox_size_limit = 0
recipient_delimiter = +
EOL

# Configure SPF (Sender Policy Framework)
echo "[+] Setting up SPF policy..."
sudo apt-get install -y postfix-policyd-spf-python
sudo tee -a /etc/postfix/master.cf > /dev/null <<EOL
# SPF integration
policy-spf  unix  -       n       n       -       -       spawn
    user=nobody argv=/usr/bin/policyd-spf
EOL

# Update Postfix to check SPF
sudo postconf -e "policy-spf_time_limit = 3600"
sudo postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, check_policy_service unix:private/policy-spf"

# Configure DMARC (for reporting)
echo "[+] Setting up DMARC (add TXT record in DNS: _dmarc.$myhostname)..."
echo "Example DNS TXT record for DMARC:"
echo "v=DMARC1; p=none; rua=mailto:dmarc-reports@$myhostname; ruf=mailto:dmarc-forensics@$myhostname; fo=1"

# Restart services
echo "[+] Restarting Postfix and OpenDKIM..."
sudo service postfix restart
sudo service opendkim restart

# Create HTML email template
echo "[+] Creating email.html..."
cat > email.html <<EOL
<html>
<body>
  <h1>PrimeRewardSpot iPhone 16 Pro</h1>
  <p>Congratulations! You are eligible to win an iPhone 16 Pro.</p>
</body>
</html>
EOL

# Create the sending script with rate limiting
echo "[+] Creating send.sh with rate limiting..."
cat > send.sh <<EOL
#!/bin/bash

# Configuration
MAX_EMAILS_PER_MIN=900000
BATCH_SIZE=100
MIN_SLEEP=0.0001
EMAIL_LIST="$email_list"

# Calculate sleep time
calculate_sleep_time() {
  local emails_per_min=\$1
  local sleep_time
  sleep_time=\$(awk -v rate="\$emails_per_min" 'BEGIN { 
    st = 60/rate; 
    st = (st < $MIN_SLEEP) ? $MIN_SLEEP : st;
    printf "%.7f", st
  }')
  echo "\$sleep_time"
}

SLEEP_TIME=\$(calculate_sleep_time \$MAX_EMAILS_PER_MIN)

# Main sending loop
while IFS= read -r email; do
  [[ -z "\$email" ]] && continue
  email="\${email%\$'\r'}"
  if [[ "\$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    cat <<EOF | /usr/sbin/sendmail -t -oi
To: \$email
From: $sender_name <$sender_email>
Subject: $email_subject
MIME-Version: 1.0
Content-Type: text/html

\$(cat email.html)
EOF
    sleep "\$SLEEP_TIME"
  else
    echo "WARNING: Skipping invalid email address: \$email"
  fi
done < "\$EMAIL_LIST"
EOL

chmod +x send.sh

# Start sending in tmux
echo "[+] Starting tmux session for background sending..."
tmux new-session -d -s mail_session "./send.sh"

echo "✅ Done! Emails are being sent in the background."
echo "To check progress: tmux attach -t mail_session"
echo "To check logs: tail -f /var/log/mail.log"
echo "IMPORTANT: Configure DNS records for DKIM, SPF, and DMARC!"
echo "DKIM Public Key:"
sudo cat /etc/opendkim/keys/$myhostname/default.txt