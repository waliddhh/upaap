#!/bin/bash

# Enhanced email sending script with proxy support
# Version 2.0 - Optimized for 100% reliability

## SECTION 1: INITIAL CHECKS AND CONFIGURATION
###############################################

# Make sure the script is being run with sudo privileges
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root or with sudo privileges."
  exit 1
fi

# Check if running on Debian/Ubuntu
if ! grep -qEi 'debian|ubuntu' /etc/*release; then
  echo "❌ This script is designed for Debian/Ubuntu systems only."
  exit 1
fi

# Proxy configuration (modify if needed)
PROXY_HOST="37.156.46.209"
PROXY_PORT="8080"

# Install necessary tools before proceeding
echo "[+] Installing required dependencies..."
apt-get update -y
apt-get install -y postfix opendkim opendkim-tools tmux swaks libnet-ssleay-perl libio-socket-ssl-perl bc

## SECTION 2: USER INPUT VALIDATION
###################################

# Prompt for user inputs with validation
while true; do
  read -p "Enter the custom myhostname (e.g., mail.yourdomain.com): " myhostname
  if [[ "$myhostname" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    break
  else
    echo "❌ Invalid hostname. Only letters, numbers, dots and hyphens allowed."
  fi
done
myhostname=${myhostname:-localhost}

while true; do
  read -p "Enter the sender email address (e.g., no-reply@yourdomain.com): " sender_email
  if [[ "$sender_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    break
  else
    echo "❌ Invalid email format. Please enter a valid email address."
  fi
done

read -p "Enter the sender name (e.g., Support Team): " sender_name
read -p "Enter the email subject: " email_subject

while true; do
  read -p "Enter the path to your email list file (e.g., germany.txt): " email_list
  if [ -f "$email_list" ]; then
    break
  else
    echo "❌ File not found. Please enter a valid file path."
  fi
done

## SECTION 3: POSTFIX AND DKIM CONFIGURATION
###########################################

echo "[+] Configuring Postfix and OpenDKIM..."

# Backup original configurations
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d%H%M%S)

# Generate DKIM keys with proper permissions
mkdir -p /etc/opendkim/keys/$myhostname
opendkim-genkey -b 2048 -d $myhostname -D /etc/opendkim/keys/$myhostname -s default -v
chown -R opendkim:opendkim /etc/opendkim/keys/$myhostname
chmod 700 /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/$myhostname/default.private

# Configure OpenDKIM
cat > /etc/opendkim.conf <<EOL
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

# Configure Postfix with robust settings
postconf -e "myhostname = $myhostname"
postconf -e "inet_interfaces = loopback-only"
postconf -e "mydestination = localhost"
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"
postconf -e "smtpd_milters = inet:localhost:8891"
postconf -e "non_smtpd_milters = inet:localhost:8891"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_client_message_rate_limit = 100"
postconf -e "anvil_rate_time_unit = 60s"
postconf -e "smtpd_error_sleep_time = 1s"
postconf -e "smtpd_soft_error_limit = 10"
postconf -e "smtpd_hard_error_limit = 20"

# Configure SPF
apt-get install -y postfix-policyd-spf-python
postconf -e "policy-spf_time_limit = 3600"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, check_policy_service unix:private/policy-spf"

## SECTION 4: EMAIL TEMPLATE AND SENDING SCRIPT
##############################################

# Create HTML email template with better structure
cat > email.html <<EOL
<html>
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
  <title>$email_subject</title>
</head>
<body style="font-family: Arial, sans-serif; line-height: 1.6;">
  <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #2c3e50;">PrimeRewardSpot iPhone 16 Pro</h1>
    <p style="font-size: 16px;">Congratulations! You are eligible to win an iPhone 16 Pro.</p>
  </div>
</body>
</html>
EOL

# Create the sending script with enhanced error handling
cat > send.sh <<EOL
#!/bin/bash

# Enhanced email sending with proxy and error handling

# Configuration
MAX_EMAILS_PER_MIN=30
SLEEP_TIME=\$(echo "scale=2; 60/\$MAX_EMAILS_PER_MIN" | bc)
DOMAIN=\$(echo "$sender_email" | cut -d@ -f2)
LOG_FILE="email_send.log"
FAILED_FILE="failed_emails.txt"

# Initialize files
> \$LOG_FILE
> \$FAILED_FILE

echo "[+] Starting email sending process at \$(date)" | tee -a \$LOG_FILE
echo "[+] Using proxy: $PROXY_HOST:$PROXY_PORT" | tee -a \$LOG_FILE

# Process email list
while IFS= read -r email; do
  # Validate email format
  if [[ ! "\$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\$ ]]; then
    echo "⚠️  Invalid email skipped: \$email" | tee -a \$LOG_FILE
    continue
  fi

  echo "➡️ Sending to: \$email" | tee -a \$LOG_FILE
  
  # Send email with swaks and proxy
  if swaks \\
    --to "\$email" \\
    --from "$sender_email" \\
    --h-From: "$sender_name <$sender_email>" \\
    --h-Subject: "$email_subject" \\
    --body email.html \\
    --server \$DOMAIN \\
    --proxy http://$PROXY_HOST:$PROXY_PORT \\
    --add-header "MIME-Version: 1.0" \\
    --add-header "Content-Type: text/html" \\
    --add-header "X-Mailer: PrimeRewardSpot" \\
    --timeout 30 \\
    >> \$LOG_FILE 2>&1; then
    
    echo "✅ Success: \$email" | tee -a \$LOG_FILE
  else
    echo "❌ Failed: \$email" | tee -a \$LOG_FILE
    echo "\$email" >> \$FAILED_FILE
  fi

  # Rate limiting
  sleep \$SLEEP_TIME
done < "$email_list"

echo "[+] Email sending completed at \$(date)" | tee -a \$LOG_FILE
echo "[+] Summary:" | tee -a \$LOG_FILE
echo "    Total attempted: \$(wc -l < "$email_list")" | tee -a \$LOG_FILE
echo "    Failed sends: \$(wc -l < \$FAILED_FILE)" | tee -a \$LOG_FILE

if [ -s \$FAILED_FILE ]; then
  echo "⚠️  Some emails failed to send. See \$FAILED_FILE for details."
fi
EOL

chmod +x send.sh

## SECTION 5: FINAL SETUP AND EXECUTION
#######################################

# Restart services with error checking
echo "[+] Restarting services..."
if ! service postfix restart; then
  echo "❌ Failed to restart Postfix. Check configuration."
  journalctl -xe | tail -20
  exit 1
fi

if ! service opendkim restart; then
  echo "❌ Failed to restart OpenDKIM. Check configuration."
  journalctl -xe | tail -20
  exit 1
fi

# Display DKIM record for DNS
echo "✅ Setup complete!"
echo "ℹ️ DKIM Public Key (add to your DNS as a TXT record for 'default._domainkey.$myhostname'):"
cat /etc/opendkim/keys/$myhostname/default.txt

# Start sending in tmux with error handling
echo "[+] Starting tmux session for background sending..."
if ! command -v tmux &> /dev/null; then
  echo "❌ tmux not found. Starting directly in foreground..."
  ./send.sh
else
  tmux new-session -d -s mail_session "./send.sh"
  echo "✅ Emails are being sent in the background."
  echo "To monitor progress: tmux attach -t mail_session"
  echo "To view logs: tail -f email_send.log"
fi